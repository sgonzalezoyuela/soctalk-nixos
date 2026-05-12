# cert-manager + optional ClusterIssuer + optional CA Secret loader.
#
# Always installs cert-manager (see AGENTS.md §4 — the bundle is coarse;
# cert-manager is part of the appliance). Two opt-in extensions:
#
#   1. soctalk.tenant.certManager.clusterIssuer.* — declaratively create
#      a ClusterIssuer (selfSigned / ca / letsencryptStaging /
#      letsencryptProd).
#
#   2. soctalk.tenant.certManager.caSecret.* — at boot, read a CA
#      tls.crt + tls.key from files on the target machine and
#      kubectl-apply them as a kubernetes.io/tls Secret in the
#      cert-manager namespace. The files arrive on the target via
#      nixos-anywhere --extra-files, scp, agenix, or sops-nix — NOT
#      via Nix. Secret bytes never enter the /nix/store.
#
# Install pattern matches modules/k3s.nix: NixOS writes a K3s
# HelmChart manifest to /var/lib/rancher/k3s/server/manifests/. Unlike
# Cilium, this HelmChart is NOT bootstrap=true; cert-manager runs as a
# regular workload after the CNI is up.
#
# Ingress controller note: when type ∈ {letsencryptStaging,
# letsencryptProd} and solver.type = http01, cert-manager creates
# Ingress objects to solve ACME challenges. We do NOT bundle an
# ingress controller; the consumer is responsible for installing one
# (Traefik v3, ingress-nginx, etc.) and aligning
# letsencrypt.solver.http01.ingressClass with the installed class.
# See README.md for install snippets.
{ config, lib, pkgs, ... }:
let
  cfg = config.soctalk.tenant.certManager;

  acmeServer = type:
    if type == "letsencryptStaging"
    then "https://acme-staging-v02.api.letsencrypt.org/directory"
    else "https://acme-v02.api.letsencrypt.org/directory";

  clusterIssuerSpec =
    if cfg.clusterIssuer.type == "selfSigned" then {
      selfSigned = { };
    } else if cfg.clusterIssuer.type == "ca" then {
      ca = { secretName = cfg.clusterIssuer.ca.secretName; };
    } else {
      # letsencryptStaging or letsencryptProd
      acme = {
        server = acmeServer cfg.clusterIssuer.type;
        email = cfg.clusterIssuer.letsencrypt.email;
        privateKeySecretRef = {
          name = "${cfg.clusterIssuer.name}-private-key";
        };
        solvers = [
          {
            http01 = {
              ingress = {
                class = cfg.clusterIssuer.letsencrypt.solver.http01.ingressClass;
              };
            };
          }
        ];
      };
    };
in
{
  options.soctalk.tenant.certManager = {
    version = lib.mkOption {
      type = lib.types.str;
      default = "v1.20.1";
      example = "v1.20.1";
      description = ''
        cert-manager Helm chart version (matches the cert-manager
        release version, with the leading `v`).
      '';
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "cert-manager";
      description = "Namespace to install cert-manager into.";
    };

    installCRDs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the cert-manager Helm chart installs its CRDs. Maps
        to the modern `crds.enabled` value (cert-manager 1.15+).
      '';
    };

    clusterIssuer = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          If true, declaratively create a ClusterIssuer alongside
          cert-manager. The ClusterIssuer is written as a separate K3s
          manifest; K3s' addon-applier retries on transient failures,
          so a "CRDs not yet established" first-pass error is normal
          and self-heals within ~30s.
        '';
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "ClusterIssuer metadata.name.";
      };

      type = lib.mkOption {
        type = lib.types.enum [ "selfSigned" "ca" "letsencryptStaging" "letsencryptProd" ];
        default = "selfSigned";
        description = ''
          ClusterIssuer kind:
          - selfSigned: Self-signed issuer (no external dependencies).
          - ca: Issues certs signed by a CA stored in a tls Secret in
            the cert-manager namespace. Pair with caSecret.* to load
            the Secret from on-disk files.
          - letsencryptStaging / letsencryptProd: ACME issuer.
            Requires an ingress controller for http01 challenges; see
            module header comment.
        '';
      };

      ca = {
        secretName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "ca-key-pair";
          description = ''
            Name of the kubernetes.io/tls Secret in the cert-manager
            namespace that holds the CA's tls.crt and tls.key.
            Required when type = "ca".
          '';
        };
      };

      letsencrypt = {
        email = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "ops@example.org";
          description = ''
            ACME account email. Required when type is
            letsencryptStaging or letsencryptProd.
          '';
        };

        solver = {
          type = lib.mkOption {
            type = lib.types.enum [ "http01" ];
            default = "http01";
            description = ''
              ACME solver type. Only http01 is supported in this
              iteration; dns01 is deferred (it requires
              provider-specific credential plumbing).
            '';
          };

          http01 = {
            ingressClass = lib.mkOption {
              type = lib.types.str;
              default = "traefik";
              example = "nginx";
              description = ''
                Ingress class to use for the http01 solver. Must
                match an ingress controller installed in the cluster.
                The bundle does NOT ship an ingress controller; see
                README.md for install snippets.
              '';
            };
          };
        };
      };
    };

    caSecret = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          If true, declare a systemd one-shot that reads a CA
          certificate and private key from `certPath` / `keyPath`
          on the target machine and applies them as a
          kubernetes.io/tls Secret in the cert-manager namespace.

          The files must be put in place out-of-band (typically via
          nixos-anywhere --extra-files at install time, or scp before
          a nixos-rebuild). The bytes never enter the Nix store —
          this option only references paths, never their contents.

          The unit re-runs on every boot and `kubectl apply` is
          idempotent, so file rotations propagate on next reboot (or
          via `systemctl restart cert-manager-ca-secret.service`).
        '';
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "ca-key-pair";
        description = ''
          Kubernetes Secret name. Use this same value as
          clusterIssuer.ca.secretName for a CA-issuer ClusterIssuer.
        '';
      };

      certPath = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/cert-manager/ca.crt";
        description = ''
          Path on the target machine where the CA certificate (PEM)
          lives. Mode is enforced to 0444 root:root via tmpfiles.
        '';
      };

      keyPath = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/cert-manager/ca.key";
        description = ''
          Path on the target machine where the CA private key (PEM)
          lives. Mode is enforced to 0400 root:root via tmpfiles.
        '';
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = !cfg.clusterIssuer.enable
                 || cfg.clusterIssuer.type != "ca"
                 || cfg.clusterIssuer.ca.secretName != null;
        message = ''
          soctalk.tenant.certManager.clusterIssuer.ca.secretName must
          be set when clusterIssuer.enable is true and type = "ca".
        '';
      }
      {
        assertion = !cfg.clusterIssuer.enable
                 || !(builtins.elem cfg.clusterIssuer.type [ "letsencryptStaging" "letsencryptProd" ])
                 || cfg.clusterIssuer.letsencrypt.email != null;
        message = ''
          soctalk.tenant.certManager.clusterIssuer.letsencrypt.email
          must be set when clusterIssuer.enable is true and type is
          letsencryptStaging or letsencryptProd.
        '';
      }
    ];

    # K3s manifests: always cert-manager; conditionally ClusterIssuer.
    # mkMerge keeps both definitions of services.k3s.manifests inside a
    # single config block.
    services.k3s.manifests = lib.mkMerge [
      {
        # 1. cert-manager itself. Standard (non-bootstrap) HelmChart.
        cert-manager.content = {
          apiVersion = "helm.cattle.io/v1";
          kind = "HelmChart";
          metadata = {
            name = "cert-manager";
            namespace = "kube-system";
          };
          spec = {
            chart = "cert-manager";
            repo = "https://charts.jetstack.io";
            version = cfg.version;
            targetNamespace = cfg.namespace;
            createNamespace = true;
            valuesContent = ''
              crds:
                enabled: ${lib.boolToString cfg.installCRDs}
            '';
          };
        };
      }

      # 2. Optional ClusterIssuer. K3s' addon-applier retries failed
      # manifests, so the first pass may fail before cert-manager's
      # CRDs are installed; subsequent passes succeed.
      (lib.mkIf cfg.clusterIssuer.enable {
        cluster-issuer.content = {
          apiVersion = "cert-manager.io/v1";
          kind = "ClusterIssuer";
          metadata = { name = cfg.clusterIssuer.name; };
          spec = clusterIssuerSpec;
        };
      })
    ];

    # 3. Optional CA Secret loader.
    #
    # Reads files on the target (never from /nix/store) and renders a
    # kubernetes.io/tls Secret via `kubectl create … --dry-run=client
    # -o yaml | kubectl apply -f -`. The pipe keeps the Secret bytes
    # in-memory; nothing is written to disk outside the on-target CA
    # paths themselves.
    systemd.services.cert-manager-ca-secret = lib.mkIf cfg.caSecret.enable {
      description = "Load CA tls Secret into the cert-manager namespace from on-disk files.";
      wants = [ "k3s.service" "network-online.target" ];
      after = [ "k3s.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.kubectl pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 10;
      };
      script = ''
        set -euo pipefail
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

        # Verify on-disk files exist before proceeding. If the
        # consumer forgot to stage them, fail fast with a clear
        # message rather than producing an empty Secret.
        for f in ${cfg.caSecret.certPath} ${cfg.caSecret.keyPath}; do
          if [ ! -s "$f" ]; then
            echo "cert-manager-ca-secret: required file missing or empty: $f" >&2
            echo "Stage CA materials via nixos-anywhere --extra-files," >&2
            echo "scp, or an at-rest-encrypted secrets backend (agenix/sops-nix)." >&2
            exit 1
          fi
        done

        # Wait for the API server to be reachable.
        until kubectl get --raw=/readyz >/dev/null 2>&1; do
          sleep 2
        done

        # Wait for the cert-manager namespace (created by the
        # HelmChart resource with createNamespace=true).
        until kubectl get namespace ${cfg.namespace} >/dev/null 2>&1; do
          sleep 2
        done

        # Idempotent apply.
        kubectl create secret tls ${cfg.caSecret.name} \
          --namespace=${cfg.namespace} \
          --cert=${cfg.caSecret.certPath} \
          --key=${cfg.caSecret.keyPath} \
          --dry-run=client -o yaml \
          | kubectl apply -f -
      '';
    };

    # Enforce strict perms on the CA on-disk files if they exist.
    # 'z' acts on existing files only; missing files don't cause an
    # error, which lets evaluation succeed for hosts that haven't yet
    # been provisioned with the CA materials.
    systemd.tmpfiles.rules = lib.mkIf cfg.caSecret.enable [
      "z ${cfg.caSecret.certPath} 0444 root root -"
      "z ${cfg.caSecret.keyPath}  0400 root root -"
    ];
  };
}
