# Full-stack consumer: cert-manager + ClusterIssuer + OAuth2-Proxy (OIDC)
# + Ingress + TLS via cert-manager.
#
# Demonstrates the canonical "auth-at-the-edge" pattern:
#   - cert-manager mints a TLS cert for the OAuth2-Proxy host.
#   - OAuth2-Proxy fronts an OIDC IdP at https://<host>/oauth2/*.
#   - Apps protect themselves with ingress auth-url annotations
#     pointing back at this OAuth2-Proxy host.
#
# Prerequisites (consumer-side):
#   1. CA materials staged at /var/lib/cert-manager/ca.{crt,key}
#      (this example uses a CA ClusterIssuer; for letsencrypt, drop
#      caSecret and switch clusterIssuer.type to letsencrypt* + add
#      letsencrypt.email).
#   2. OIDC credentials staged at /var/lib/oauth2-proxy/{client-id,
#      client-secret,cookie-secret}.
#   3. An ingress controller installed in the cluster matching
#      `ingress.className` (defaults to "traefik"; see README.md).
#
# Build:
#   nix build .#nixosConfigurations.edge-01.config.system.build.toplevel
#
# Deploy:
#   mkdir -p extra-files/var/lib/cert-manager extra-files/var/lib/oauth2-proxy
#   cp secrets/ca.crt           extra-files/var/lib/cert-manager/ca.crt
#   cp secrets/ca.key           extra-files/var/lib/cert-manager/ca.key
#   cp secrets/client-id        extra-files/var/lib/oauth2-proxy/client-id
#   cp secrets/client-secret    extra-files/var/lib/oauth2-proxy/client-secret
#   cp secrets/cookie-secret    extra-files/var/lib/oauth2-proxy/cookie-secret
#   chmod 0400 extra-files/var/lib/cert-manager/ca.key \
#              extra-files/var/lib/oauth2-proxy/*
#   nix run github:nix-community/nixos-anywhere -- \
#     --extra-files ./extra-files --flake .#edge-01 root@<ip>
{
  description = "soctalk-nixos consumer with cert-manager + OAuth2-Proxy (OIDC).";

  inputs = {
    soctalk-nixos.url = "path:../..";
    nixpkgs.follows = "soctalk-nixos/nixpkgs";
  };

  outputs = { self, nixpkgs, soctalk-nixos, ... }: {
    nixosConfigurations.edge-01 = soctalk-nixos.lib.mkHost {
      hostName = "edge-01";
      tenant = {
        timeZone = "Europe/Madrid";
        locale = "en_US.UTF-8";

        adminUsers = [
          { name = "ops"; description = "Operations admin"; }
        ];
        sshAuthorizedKeys = [
          # Placeholder — replace before deploying.
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDoNotUseInProduction ops@laptop"
        ];

        network = {
          interface = "ens18";
          address = "192.168.10.50";
          prefixLength = 24;
          gateway = "192.168.10.1";
          nameservers = [ "1.1.1.1" "9.9.9.9" ];
          domain = "example.org";        # OIDC host derives to "edge-01.example.org"
          enableIPv6 = false;
        };

        # cert-manager + CA ClusterIssuer (issuer for the OAuth2-Proxy TLS Cert).
        certManager.clusterIssuer = {
          enable = true;
          name = "internal-ca";
          type = "ca";
          ca.secretName = "ca-key-pair";
        };
        certManager.caSecret.enable = true;   # defaults to /var/lib/cert-manager/ca.{crt,key}

        # OIDC frontend.
        oidc = {
          enable = true;
          issuerUrl = "https://idp.example.org/";   # replace with your IdP
          # host derives to "edge-01.example.org" automatically.
          # Uncomment for localhost testing:
          # redirectUrl = "http://localhost:4180/oauth2/callback";
          ingress = {
            className = "traefik";                  # match your installed controller
          };
          tls = {
            enable = true;
            # issuerRef defaults to "internal-ca" because clusterIssuer.enable=true.
          };
        };
      };
    };
  };
}
