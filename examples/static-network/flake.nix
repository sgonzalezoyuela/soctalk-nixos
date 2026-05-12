# Full-featured soctalk-nixos consumer.
#
# Overrides every tenant option, including a cert-manager ClusterIssuer
# of type `ca` backed by an internal CA whose materials are staged on
# the target machine (NOT in the Nix store).
#
# Build:
#   nix build .#nixosConfigurations.edge-01.config.system.build.toplevel
#
# Deploy (fresh install):
#   # 1. Generate / place CA materials under ./secrets/ (see secrets/README.md).
#   # 2. Stage them for nixos-anywhere --extra-files:
#   mkdir -p extra-files/var/lib/cert-manager
#   cp secrets/ca.crt extra-files/var/lib/cert-manager/ca.crt
#   cp secrets/ca.key extra-files/var/lib/cert-manager/ca.key
#   chmod 0400 extra-files/var/lib/cert-manager/ca.key
#   # 3. Deploy:
#   nix run github:nix-community/nixos-anywhere -- \
#     --extra-files ./extra-files \
#     --flake .#edge-01 root@<ip>
#
# After boot, the cert-manager-ca-secret.service runs once, reads
# /var/lib/cert-manager/ca.{crt,key} on the target, and kubectl-applies
# a kubernetes.io/tls Secret in the cert-manager namespace. The
# internal-ca ClusterIssuer references that Secret.
{
  description = "Fully customized soctalk-nixos consumer (static IP + cert-manager + CA ClusterIssuer).";

  inputs = {
    soctalk-nixos.url = "path:../..";
    nixpkgs.follows = "soctalk-nixos/nixpkgs";
  };

  outputs = { self, nixpkgs, soctalk-nixos, ... }: {
    nixosConfigurations.edge-01 = soctalk-nixos.lib.mkHost {
      hostName = "soctalk";
      tenant = {
        timeZone = "Europe/Madrid";
        locale = "es_ES.UTF-8";
        diskDevice = "/dev/nvme0n1";

        adminUsers = [
          { name = "ops"; description = "Operations admin"; }
        ];

        # These are placeholder keys. Replace with the real public key
        # before deploying — the example fingerprint will not let you
        # SSH in.
        sshAuthorizedKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDoNotUseInProduction ops@laptop"
        ];

        network = {
          interface = "ens18";
          address = "192.168.10.50";
          prefixLength = 24;
          gateway = "192.168.10.1";
          nameservers = [ "1.1.1.1" "9.9.9.9" ];
          domain = "example.org";
          enableIPv6 = false;
        };

        # cert-manager ClusterIssuer of type=ca, backed by the
        # ca-key-pair Secret that the caSecret loader populates.
        certManager.clusterIssuer = {
          enable = true;
          name = "internal-ca";
          type = "ca";
          ca.secretName = "ca-key-pair";   # matches caSecret.name below
        };

        # On-target CA loader. Reads /var/lib/cert-manager/ca.{crt,key}
        # at boot and applies them as a kubernetes.io/tls Secret in
        # the cert-manager namespace. The files arrive on the target
        # via nixos-anywhere --extra-files (or scp / agenix / sops-nix
        # for updates). The bytes never enter the Nix store.
        certManager.caSecret = {
          enable = true;
          # name, certPath, keyPath all defaulted.
        };
      };
    };
  };
}
