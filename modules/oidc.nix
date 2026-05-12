# OIDC / OAuth2-Proxy.
#
# Opt-in (soctalk.tenant.oidc.enable = false by default). When enabled,
# installs OAuth2-Proxy via a K3s HelmChart, loads the IdP client
# credentials + cookie secret from on-target files (NEVER from
# /nix/store — same invariant as cert-manager's caSecret), optionally
# renders an Ingress for the /oauth2/* paths, and optionally renders a
# cert-manager Certificate that mints the Ingress's TLS Secret.
#
# Apps protect themselves with auth-url annotations pointing at the
# OAuth2-Proxy host. See examples/oidc/ and README.md for the
# canonical ingress-nginx / Traefik annotation patterns.
#
# Ingress controller dependency: the bundle does NOT ship one. The
# consumer installs Traefik v3 / ingress-nginx and aligns
# `oidc.ingress.className` with the installed class.
{ config, lib, pkgs, ... }:
let
  cfg = config.soctalk.tenant.oidc;
  ci = config.soctalk.tenant.certManager.clusterIssuer;

  derivedHost =
    let
      hn = config.networking.hostName;
      dn = config.networking.domain;
    in
    if dn != null && dn != ""
    then "${hn}.${dn}"
    else hn;

  effectiveRedirectUrl =
    if cfg.redirectUrl != null
    then cfg.redirectUrl
    else "https://${cfg.host}/oauth2/callback";

  # OAuth2-Proxy Helm values. extraArgs is a string→(string|bool|int)
  # map; we render bools/ints as JSON, which the chart accepts. The
  # consumer's `extraArgs` are merged in last so they win over our
  # defaults.
  helmValues = {
    config.existingSecret = cfg.secretsPath.secretName;
    ingress.enabled = false;     # we render our own Ingress when needed
    extraArgs = {
      provider = cfg.provider;
      "oidc-issuer-url" = cfg.issuerUrl;
      upstream = cfg.upstream;
      "set-xauthrequest" = true;
      "pass-authorization-header" = true;
      "reverse-proxy" = true;
      "redirect-url" = effectiveRedirectUrl;
      "cookie-domain" = cfg.cookieDomain;
    } // cfg.extraArgs;
  };
in
{
  options.soctalk.tenant.oidc = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install OAuth2-Proxy as the OIDC frontend for the cluster.
        Disabled by default — OAuth2-Proxy refuses to start without
        credentials, so this is unsafe to enable without also
        configuring `issuerUrl` and staging client-id / client-secret
        / cookie-secret onto the target.
      '';
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "10.4.3";
      example = "10.4.3";
      description = ''
        oauth2-proxy Helm **chart** version (NOT the OAuth2-Proxy
        image / app version — those are decoupled). The default
        `10.4.3` chart bundles OAuth2-Proxy app `7.15.2`.

        Chart versions live at
        https://oauth2-proxy.github.io/manifests/index.yaml — pick
        one whose `appVersion` matches the OAuth2-Proxy release you
        want.
      '';
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "ingress-system";
      description = ''
        Namespace to install OAuth2-Proxy into. Defaults to
        `ingress-system` (a common convention shared with the
        cluster's ingress controller).
      '';
    };

    releaseName = lib.mkOption {
      type = lib.types.str;
      default = "oauth2-proxy";
      description = "Helm release name (also used as the in-cluster Service name).";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = derivedHost;
      defaultText = lib.literalExpression ''
        "''${networking.hostName}.''${networking.domain}" when domain is set,
        otherwise just networking.hostName
      '';
      example = "auth.example.org";
      description = ''
        Public hostname OAuth2-Proxy expects to be reached at. Used
        for the rendered Ingress's `host` rule, the cookie-domain,
        and the derived redirect-url. Override directly if the
        tenant's networking.hostName+domain do not match the
        externally-facing URL.
      '';
    };

    redirectUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://localhost:4180/oauth2/callback";
      description = ''
        Override for OAuth2-Proxy's `--redirect-url` flag. When null
        (the default), the value is derived as
        `https://''${oidc.host}/oauth2/callback`. Override when:
        - testing locally against a non-routable host,
        - the IdP-visible URL differs from the in-cluster Ingress host
          (split-horizon DNS, reverse-proxy chains that rewrite the
          host header), or
        - the IdP requires a specific scheme / path that the default
          doesn't produce.
      '';
    };

    issuerUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://idp.example.org/";
      description = ''
        OIDC issuer URL (the IdP's discovery root). Required when
        oidc.enable is true. Maps to OAuth2-Proxy's
        `--oidc-issuer-url`.
      '';
    };

    provider = lib.mkOption {
      type = lib.types.str;
      default = "oidc";
      description = ''
        OAuth2-Proxy provider key. Defaults to `oidc` for generic
        OIDC IdPs (Keycloak, Authentik, Auth0, Dex, etc.). Other
        values: `google`, `github`, `gitlab`, `keycloak-oidc`, …
      '';
    };

    upstream = lib.mkOption {
      type = lib.types.str;
      default = "static://202";
      example = "http://my-app.default.svc:8080";
      description = ''
        OAuth2-Proxy upstream. Default `static://202` returns a 202
        for `/oauth2/auth`, which is the right behaviour when
        OAuth2-Proxy is consulted only via ingress auth-url
        annotations. Set to a real URL to front a single application
        directly.
      '';
    };

    cookieDomain = lib.mkOption {
      type = lib.types.str;
      default = cfg.host;
      defaultText = lib.literalExpression "oidc.host";
      example = ".example.org";
      description = ''
        Cookie domain. Defaults to the OIDC host (single-host
        sessions). Set to a parent domain (with a leading dot) to
        share sessions across multiple subdomains.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.bool lib.types.int ]);
      default = { };
      example = lib.literalExpression ''
        {
          "email-domain" = "example.org";
          "skip-provider-button" = true;
        }
      '';
      description = ''
        Additional OAuth2-Proxy CLI flags rendered into the chart's
        `extraArgs`. Merged after our defaults — consumer keys
        override built-in defaults.
      '';
    };

    secretsPath = {
      clientId = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/oauth2-proxy/client-id";
        description = "Path on target containing the OIDC client ID (PEM/text).";
      };

      clientSecret = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/oauth2-proxy/client-secret";
        description = "Path on target containing the OIDC client secret.";
      };

      cookieSecret = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/oauth2-proxy/cookie-secret";
        description = ''
          Path on target containing the 32-byte base64 cookie
          secret. If `cookieSecret.autoGenerate = true` (default)
          and this file doesn't exist at boot, the loader mints
          one with `openssl rand -base64 32 | tr -d '\n'`.
        '';
      };

      secretName = lib.mkOption {
        type = lib.types.str;
        default = "oauth2-proxy-secrets";
        description = ''
          Name of the Kubernetes Secret the loader applies. Must
          match the chart's `config.existingSecret` (which we wire
          automatically).
        '';
      };
    };

    cookieSecret = {
      autoGenerate = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          If true (default), the systemd loader mints a fresh
          cookie-secret at `secretsPath.cookieSecret` if no file
          exists there. The cookie-secret is 32 bytes of local
          randomness used to sign session cookies — it never leaves
          the cluster, so on-target generation is safe.

          The generated file persists across reboots; sessions
          remain valid until the file is deleted or replaced.

          Set to false to require the consumer to stage the
          cookie-secret explicitly (matches client-id /
          client-secret behaviour). Useful when the cookie-secret is
          managed externally — e.g., decrypted from agenix /
          sops-nix into a tmpfs path that must be predictable across
          reboots.
        '';
      };
    };

    ingress = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Render an Ingress for the OAuth2-Proxy /oauth2/* paths.";
      };

      className = lib.mkOption {
        type = lib.types.str;
        default = "traefik";
        example = "nginx";
        description = ''
          Ingress class name. Must match an installed ingress
          controller — the bundle does NOT install one. See
          README.md for Traefik v3 / ingress-nginx install snippets.
        '';
      };

      path = lib.mkOption {
        type = lib.types.str;
        default = "/oauth2";
        description = "Path prefix for the OAuth2-Proxy Ingress rule.";
      };
    };

    tls = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Wire TLS on the OAuth2-Proxy Ingress. When true, a
          cert-manager Certificate is rendered that mints a cert
          into `tls.secretName`, and the Ingress references that
          Secret via its `spec.tls` block.

          Opt-in (default false) so first-time consumers can enable
          OIDC without a working ClusterIssuer. Production
          deployments almost always need TLS — most OIDC providers
          reject http:// redirect URLs.
        '';
      };

      secretName = lib.mkOption {
        type = lib.types.str;
        default = "oauth2-proxy-tls";
        description = "Name of the TLS Secret (also referenced by the rendered Certificate).";
      };

      issuerRef = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = if ci.enable then ci.name else null;
        defaultText = lib.literalExpression ''
          if soctalk.tenant.certManager.clusterIssuer.enable
          then soctalk.tenant.certManager.clusterIssuer.name
          else null
        '';
        description = ''
          ClusterIssuer name to reference in the Certificate. When
          unset, defaults to the tenant's clusterIssuer.name if
          certManager.clusterIssuer.enable is true; otherwise null
          (which makes tls.enable an assertion failure).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.issuerUrl != null;
        message = "soctalk.tenant.oidc.issuerUrl must be set when oidc.enable is true.";
      }
      {
        assertion = cfg.host != "";
        message = "soctalk.tenant.oidc.host must be non-empty (set networking.hostName + network.domain, or override oidc.host directly).";
      }
      {
        assertion = !cfg.tls.enable || cfg.tls.issuerRef != null;
        message = ''
          soctalk.tenant.oidc.tls.issuerRef must be set when tls.enable is true.
          Either enable certManager.clusterIssuer (which the default derives from)
          or set oidc.tls.issuerRef explicitly to a pre-existing ClusterIssuer.
        '';
      }
    ];

    # K3s manifests: always the Namespace + HelmChart; conditionally
    # the Ingress and Certificate. mkMerge keeps all four under a
    # single services.k3s.manifests definition.
    services.k3s.manifests = lib.mkMerge [
      {
        # 0. Namespace. Rendered explicitly (alphabetically before
        # `oauth2-proxy`) so it exists as soon as K3s starts applying
        # static manifests. This lets `oauth2-proxy-secrets.service`
        # apply the Secret BEFORE helm-controller spins up the
        # OAuth2-Proxy deployment — eliminating the race where the
        # Pod would otherwise CrashLoopBackOff with
        # `secret "oauth2-proxy-secrets" not found` until the Secret
        # eventually appears.
        #
        # `createNamespace: true` on the HelmChart below stays, as
        # belt-and-suspenders: if someone disables this manifest,
        # the chart still creates its own namespace.
        oauth2-proxy-namespace.content = {
          apiVersion = "v1";
          kind = "Namespace";
          metadata = { name = cfg.namespace; };
        };

        # 1. OAuth2-Proxy HelmChart.
        oauth2-proxy.content = {
          apiVersion = "helm.cattle.io/v1";
          kind = "HelmChart";
          metadata = {
            name = cfg.releaseName;
            namespace = "kube-system";
          };
          spec = {
            chart = "oauth2-proxy";
            repo = "https://oauth2-proxy.github.io/manifests";
            version = cfg.version;
            targetNamespace = cfg.namespace;
            createNamespace = true;
            valuesContent = builtins.toJSON helmValues;
          };
        };
      }

      # 2. Optional Ingress for /oauth2/*.
      (lib.mkIf cfg.ingress.enable {
        oauth2-proxy-ingress.content = {
          apiVersion = "networking.k8s.io/v1";
          kind = "Ingress";
          metadata = {
            name = "oauth2-proxy";
            namespace = cfg.namespace;
          };
          spec = {
            ingressClassName = cfg.ingress.className;
            rules = [
              {
                host = cfg.host;
                http = {
                  paths = [
                    {
                      path = cfg.ingress.path;
                      pathType = "Prefix";
                      backend = {
                        service = {
                          name = cfg.releaseName;
                          port = { number = 80; };
                        };
                      };
                    }
                  ];
                };
              }
            ];
          } // lib.optionalAttrs cfg.tls.enable {
            tls = [
              {
                hosts = [ cfg.host ];
                secretName = cfg.tls.secretName;
              }
            ];
          };
        };
      })

      # 3. Optional cert-manager Certificate.
      (lib.mkIf cfg.tls.enable {
        oauth2-proxy-cert.content = {
          apiVersion = "cert-manager.io/v1";
          kind = "Certificate";
          metadata = {
            name = "oauth2-proxy-tls";
            namespace = cfg.namespace;
          };
          spec = {
            secretName = cfg.tls.secretName;
            dnsNames = [ cfg.host ];
            issuerRef = {
              kind = "ClusterIssuer";
              name = cfg.tls.issuerRef;
            };
          };
        };
      })
    ];

    # 4. Secrets loader. Same pattern as cert-manager-ca-secret.service —
    # bytes never enter /nix/store.
    #
    # Failure model:
    #   - client-id / client-secret: must be staged by the consumer.
    #     These come from the OIDC IdP and the loader can't invent them.
    #     Missing → unit fails loudly with a clear message.
    #   - cookie-secret: 32 bytes of local randomness. If the file is
    #     missing, the loader mints it on first run (configurable via
    #     `cookieSecret.autoGenerate`). Once written it persists across
    #     reboots; rotating it invalidates existing sessions.
    systemd.services.oauth2-proxy-secrets = {
      description = "Load OAuth2-Proxy credentials Secret into the OIDC namespace.";
      wants = [ "k3s.service" "network-online.target" ];
      after = [ "k3s.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.kubectl pkgs.coreutils pkgs.openssl ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 10;
      };
      script = ''
        set -euo pipefail
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

        # IdP-provided files: consumer must stage these.
        for f in ${cfg.secretsPath.clientId} ${cfg.secretsPath.clientSecret}; do
          if [ ! -s "$f" ]; then
            echo "oauth2-proxy-secrets: required IdP credential missing or empty: $f" >&2
            echo "Stage client-id and client-secret on the target via" >&2
            echo "nixos-anywhere --extra-files / scp / agenix / sops-nix." >&2
            exit 1
          fi
        done

        # cookie-secret: local random. Mint one on first run if missing
        # and autoGenerate is enabled (default).
        if [ ! -s ${cfg.secretsPath.cookieSecret} ]; then
          ${if cfg.cookieSecret.autoGenerate then ''
            install -d -m 0700 "$(dirname ${cfg.secretsPath.cookieSecret})"
            umask 0277
            openssl rand -base64 32 | tr -d '\n' > ${cfg.secretsPath.cookieSecret}
            chmod 0400 ${cfg.secretsPath.cookieSecret}
            echo "oauth2-proxy-secrets: generated new cookie-secret at ${cfg.secretsPath.cookieSecret}" >&2
          '' else ''
            echo "oauth2-proxy-secrets: cookie-secret missing or empty: ${cfg.secretsPath.cookieSecret}" >&2
            echo "Generate with: openssl rand -base64 32 | tr -d '\\n' > ${cfg.secretsPath.cookieSecret}" >&2
            echo "Or set soctalk.tenant.oidc.cookieSecret.autoGenerate = true." >&2
            exit 1
          ''}
        fi

        until kubectl get --raw=/readyz >/dev/null 2>&1; do
          sleep 2
        done

        until kubectl get namespace ${cfg.namespace} >/dev/null 2>&1; do
          sleep 2
        done

        kubectl create secret generic ${cfg.secretsPath.secretName} \
          --namespace=${cfg.namespace} \
          --from-file=client-id=${cfg.secretsPath.clientId} \
          --from-file=client-secret=${cfg.secretsPath.clientSecret} \
          --from-file=cookie-secret=${cfg.secretsPath.cookieSecret} \
          --dry-run=client -o yaml \
          | kubectl apply -f -
      '';
    };

    # Enforce strict perms on the OIDC credentials if they exist.
    systemd.tmpfiles.rules = [
      "z ${cfg.secretsPath.clientId}     0400 root root -"
      "z ${cfg.secretsPath.clientSecret} 0400 root root -"
      "z ${cfg.secretsPath.cookieSecret} 0400 root root -"
    ];
  };
}
