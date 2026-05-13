# soctalk-system: the apex application that the rest of the bundle
# (K3s + Cilium + cert-manager + OAuth2-Proxy) exists to support.
#
# Opt-in (soctalk.tenant.system.enable = false by default). When
# enabled, installs the soctalk-system Helm chart from its OCI registry
# (ghcr.io/gbrigandi/charts), wires the consumer's identity / hostname
# / TLS / OIDC settings, and optionally renders a cert-manager
# Certificate for the rendered Ingress.
#
# Cross-module dependencies:
#   - cert-manager.clusterIssuer.* — when tls.enable=true and
#     tls.issuerRef is unset, this module defaults tls.issuerRef to
#     clusterIssuer.name (same auto-derive pattern as oidc.tls).
#   - oidc.* — soctalk-system reads X-Auth-Request-* headers from
#     upstream. When `system.enable = true` and `oidc.enable = false`,
#     a NixOS warning is emitted (not a hard failure — a consumer
#     might be injecting auth headers from somewhere else).
#
# Wildcard certificates: tls.includeWildcard is false by default. The
# Let's Encrypt http01 solver path that the rest of the bundle wires
# CANNOT issue wildcards — only DNS-01 can. For
# `*.customers.<domain>` style hostnames the consumer must either
# (a) leave includeWildcard=false and provide a separately-managed
# wildcard cert, or (b) set includeWildcard=true AND wire a
# DNS-01-capable issuer themselves.
{ config, lib, pkgs, ... }:
let
  cfg = config.soctalk.tenant.system;
  ci = config.soctalk.tenant.certManager.clusterIssuer;

  # Sparse rendering: omit image.tag entirely when null so the chart's
  # built-in default wins. Other fields are emitted unconditionally
  # because the consumer is meant to control them.
  helmValues = {
    install = {
      msspId = cfg.install.msspId;
      msspName = cfg.install.msspName;
      installId = cfg.install.installId;
      installLabel = cfg.install.installLabel;
    };

    image = {
      registry = cfg.image.registry;
    } // lib.optionalAttrs (cfg.image.tag != null) {
      tag = cfg.image.tag;
    };

    ingress = {
      enabled = cfg.ingress.enable;
      className = cfg.ingress.className;
      tls = {
        issuerRef = cfg.tls.issuerRef;
        secretName = cfg.tls.secretName;
      };
      hostnames = {
        mssp = cfg.ingress.hostnames.mssp;
        customer = cfg.ingress.hostnames.customer;
      };
    };

    oidc = {
      trustedHeaderUser = cfg.oidc.trustedHeaderUser;
      trustedHeaderEmail = cfg.oidc.trustedHeaderEmail;
      trustedProxyCIDRs = cfg.oidc.trustedProxyCIDRs;
    };

    postgres = {
      enabled = cfg.postgres.enable;
      storage = { size = cfg.postgres.storage.size; };
    };
  };

  certDnsNames =
    [ cfg.ingress.hostnames.mssp ]
    ++ lib.optional cfg.tls.includeWildcard cfg.ingress.hostnames.customer;
in
{
  options.soctalk.tenant.system = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install the soctalk-system Helm chart. Disabled by default —
        the chart requires tenant-specific identity (`install.msspId`,
        `install.msspName`, `install.installId`) that has no sane
        default. Enable explicitly once those are configured.
      '';
    };

    chartRef = lib.mkOption {
      type = lib.types.str;
      default = "oci://ghcr.io/gbrigandi/charts/soctalk-system";
      description = ''
        Helm chart reference. Defaults to the official OCI registry.
        K3s' helm-controller (klipper-helm) recognises `oci://` URLs
        natively — no `repo` field is needed.
      '';
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "0.1.0";
      description = ''
        soctalk-system chart version. This is a 0.x release — expect
        breaking changes between minors. Pin explicitly in production
        consumer flakes.
      '';
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "soctalk-system";
      description = "Namespace to install soctalk-system into.";
    };

    install = {
      msspId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "11111111-1111-1111-1111-111111111111";
        description = ''
          Per-MSSP UUID. Generate with `uuidgen | tr A-Z a-z`.
          Required when `enable = true`. Must be stable across
          re-deploys of the same MSSP.
        '';
      };

      msspName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "Acme Security";
        description = "Human-readable MSSP name. Required when `enable = true`.";
      };

      installId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "22222222-2222-2222-2222-222222222222";
        description = ''
          Per-installation UUID (a single MSSP may have multiple
          installations — e.g. staging + prod). Generate with
          `uuidgen | tr A-Z a-z`. Required when `enable = true`.
        '';
      };

      installLabel = lib.mkOption {
        type = lib.types.str;
        default = "production";
        example = "pilot-prod";
        description = "Human-readable label for this installation.";
      };
    };

    image = {
      registry = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/gbrigandi";
        description = "Container image registry prefix. Override for air-gapped / mirror deployments.";
      };

      tag = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "0.1.0";
        description = ''
          Image tag override. When null (default), the option is
          omitted from the rendered Helm values and the chart's own
          default tag (typically tracking the chart version) wins.
          Override explicitly to pin to a different image tag than
          the chart's default.
        '';
      };
    };

    ingress = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Render the chart's Ingress.";
      };

      className = lib.mkOption {
        type = lib.types.str;
        default = "traefik";
        example = "nginx";
        description = ''
          Ingress class. Must match an installed ingress controller.
          The bundle does not ship one; see README for install
          snippets. Defaults to `traefik` for consistency with
          `oidc.ingress.className`.
        '';
      };

      hostnames = {
        mssp = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "mssp.example.org";
          description = ''
            Public hostname for the MSSP admin console. Required
            when `ingress.enable = true`.
          '';
        };

        customer = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "*.customers.example.org";
          description = ''
            Public hostname pattern for customer UIs. May be a
            wildcard. Required when `ingress.enable = true`.

            Wildcards (`*.foo`) require a DNS-01-capable
            ClusterIssuer to mint a TLS cert — Let's Encrypt http01
            cannot issue wildcard certificates. See
            `tls.includeWildcard`.
          '';
        };
      };
    };

    tls = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Render a cert-manager Certificate that mints the Ingress's
          TLS Secret. Opt-in so first-time consumers can bring up
          soctalk-system without a working ClusterIssuer.
        '';
      };

      secretName = lib.mkOption {
        type = lib.types.str;
        default = "soctalk-tls";
        description = ''
          Name of the TLS Secret in the soctalk-system namespace.
          Referenced by both the rendered Certificate and the
          chart's `ingress.tls.secretName` value.
        '';
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
          ClusterIssuer name the rendered Certificate references.
          Defaults to the tenant's clusterIssuer.name when
          certManager.clusterIssuer.enable is true; otherwise null
          (which makes tls.enable an assertion failure).
        '';
      };

      includeWildcard = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When true, the rendered Certificate's `dnsNames` includes
          `ingress.hostnames.customer` in addition to
          `ingress.hostnames.mssp`. Only sensible when the configured
          ClusterIssuer can do DNS-01 — Let's Encrypt http01 cannot
          issue wildcards. Leave at false (default) and let the
          consumer provide the wildcard cert separately for the
          common case.
        '';
      };
    };

    oidc = {
      trustedHeaderUser = lib.mkOption {
        type = lib.types.str;
        default = "X-Auth-Request-User";
        description = ''
          Trusted HTTP header carrying the authenticated user
          identifier. Matches OAuth2-Proxy's `--set-xauthrequest`
          output. Override only if a non-OAuth2-Proxy upstream
          injects a different header name.
        '';
      };

      trustedHeaderEmail = lib.mkOption {
        type = lib.types.str;
        default = "X-Auth-Request-Email";
        description = "Trusted HTTP header carrying the authenticated user email.";
      };

      trustedProxyCIDRs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "10.42.0.0/16" ];
        example = [ "10.42.0.0/16" "10.43.0.0/16" ];
        description = ''
          CIDRs that soctalk-system trusts as setting the
          `trustedHeader*` request headers. Default `10.42.0.0/16`
          matches the K3s pod CIDR — any in-cluster ingress
          controller and OAuth2-Proxy fall inside this range. Tighten
          if you've narrowed the cluster CIDR.
        '';
      };
    };

    postgres = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Bundle Postgres via the chart's subchart. Set to false if
          you point soctalk-system at an external Postgres (via
          `extraModules` overriding the chart's database connection
          values — outside the current option surface).
        '';
      };

      storage.size = lib.mkOption {
        type = lib.types.str;
        default = "20Gi";
        example = "100Gi";
        description = ''
          PVC size for the bundled Postgres. K3s' built-in
          local-path-provisioner satisfies this; the node's root
          filesystem must have at least this much free space.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.install.msspId != null;
        message = "soctalk.tenant.system.install.msspId must be set when system.enable is true. Generate one with `uuidgen | tr A-Z a-z`.";
      }
      {
        assertion = cfg.install.msspName != null;
        message = "soctalk.tenant.system.install.msspName must be set when system.enable is true.";
      }
      {
        assertion = cfg.install.installId != null;
        message = "soctalk.tenant.system.install.installId must be set when system.enable is true. Generate one with `uuidgen | tr A-Z a-z`.";
      }
      {
        assertion = !cfg.ingress.enable || cfg.ingress.hostnames.mssp != null;
        message = "soctalk.tenant.system.ingress.hostnames.mssp must be set when ingress.enable is true.";
      }
      {
        assertion = !cfg.ingress.enable || cfg.ingress.hostnames.customer != null;
        message = "soctalk.tenant.system.ingress.hostnames.customer must be set when ingress.enable is true. May be a wildcard pattern like `*.customers.example.org`.";
      }
      {
        assertion = !cfg.tls.enable || cfg.tls.issuerRef != null;
        message = ''
          soctalk.tenant.system.tls.issuerRef must be set when tls.enable is true.
          Either enable certManager.clusterIssuer (which the default derives from)
          or set system.tls.issuerRef explicitly to a pre-existing ClusterIssuer.
        '';
      }
    ];

    warnings = lib.optional (!config.soctalk.tenant.oidc.enable) ''
      soctalk.tenant.system.enable = true without oidc.enable = true.
      SocTalk reads trusted identity headers (X-Auth-Request-User /
      X-Auth-Request-Email) from upstream — without OAuth2-Proxy (or
      an equivalent auth proxy injecting those headers), no
      authenticated identity will reach SocTalk and the application
      will reject requests at the API layer.
    '';

    # K3s manifests: Namespace + HelmChart always; Certificate when
    # tls.enable. mkMerge keeps them under one services.k3s.manifests
    # definition.
    services.k3s.manifests = lib.mkMerge [
      {
        # Pre-create the namespace so it's in place when the chart's
        # pre-install Job runs. Same race-tightening rationale as the
        # other modules' explicit namespace manifests.
        soctalk-system-namespace.content = {
          apiVersion = "v1";
          kind = "Namespace";
          metadata = { name = cfg.namespace; };
        };

        soctalk-system.content = {
          apiVersion = "helm.cattle.io/v1";
          kind = "HelmChart";
          metadata = {
            name = "soctalk-system";
            namespace = "kube-system";
          };
          spec = {
            chart = cfg.chartRef;
            version = cfg.version;
            targetNamespace = cfg.namespace;
            createNamespace = true;
            valuesContent = builtins.toJSON helmValues;
          };
        };
      }

      (lib.mkIf cfg.tls.enable {
        soctalk-system-cert.content = {
          apiVersion = "cert-manager.io/v1";
          kind = "Certificate";
          metadata = {
            name = "soctalk-tls";
            namespace = cfg.namespace;
          };
          spec = {
            secretName = cfg.tls.secretName;
            dnsNames = certDnsNames;
            issuerRef = {
              kind = "ClusterIssuer";
              name = cfg.tls.issuerRef;
            };
          };
        };
      })
    ];
  };
}
