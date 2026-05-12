# soctalk-nixos tenant options.
#
# Declares the override surface for downstream consumers under the
# `soctalk.tenant.*` namespace and translates those options into raw
# NixOS settings (time.timeZone, i18n.*, networking.*, users.*,
# disko.*).
#
# A consumer flake sets:
#
#   soctalk.tenant = {
#     timeZone = "Europe/Madrid";
#     locale   = "es_ES.UTF-8";
#     network  = { address = "192.168.1.10"; gateway = "192.168.1.1"; ... };
#   };
#
# and gets a fully configured host without touching the underlying
# NixOS option keys. For per-LC overrides or one-off networking tweaks
# the consumer can still set `i18n.extraLocaleSettings` or
# `networking.*` directly — module merging takes care of it.
{ config, lib, ... }:
let
  cfg = config.soctalk.tenant;

  # Defaults for admin users and authorized keys are sourced from the
  # in-repo data files so the upstream's reference host keeps working
  # without any explicit tenant overrides.
  defaultAdminUsers = (import ../config/users.nix).admin;
  defaultSshKeys = (import ../config/ssh-keys.nix).admin;
in
{
  options.soctalk.tenant = {
    timeZone = lib.mkOption {
      type = lib.types.str;
      default = "UTC";
      example = "America/New_York";
      description = "System timezone (IANA name). Sets time.timeZone.";
    };

    locale = lib.mkOption {
      type = lib.types.str;
      default = "en_US.UTF-8";
      example = "es_ES.UTF-8";
      description = ''
        Single locale that fans out to i18n.defaultLocale and every
        LC_* entry in i18n.extraLocaleSettings. For per-LC overrides,
        set i18n.extraLocaleSettings directly — module merging picks
        up your overrides over the values produced here.
      '';
    };

    diskDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/sda";
      example = "/dev/nvme0n1";
      description = ''
        Disk device for the bundled single-disk-bios disko layout.
        Wins over the disko module's own mkDefault so consumers can set
        this option without reaching into disko.devices.*.
      '';
    };

    adminUsers = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Login name.";
          };
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "GECOS / full name. Falls back to `name` if empty.";
          };
        };
      });
      default = defaultAdminUsers;
      description = ''
        Admin users to create on the host. Each user gets
        isNormalUser = true, the wheel group, and the tenant's
        sshAuthorizedKeys.
      '';
    };

    sshAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = defaultSshKeys;
      description = ''
        SSH authorized keys applied to root and to every user in
        adminUsers.
      '';
    };

    network = {
      useDHCP = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          If true, the primary interface uses DHCP and address/gateway
          are ignored. If false (the default), address and gateway are
          required.
        '';
      };

      interface = lib.mkOption {
        type = lib.types.str;
        default = "ens18";
        example = "eth0";
        description = ''
          Primary network interface name. Default matches Proxmox
          virtio-net (ens18); change to "eth0" for many cloud
          providers.
        '';
      };

      address = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "192.168.1.10";
        description = "Static IPv4 address. Required when useDHCP = false.";
      };

      prefixLength = lib.mkOption {
        type = lib.types.ints.between 0 32;
        default = 24;
        description = "IPv4 prefix length (CIDR). Ignored when useDHCP = true.";
      };

      gateway = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "192.168.1.1";
        description = "Default IPv4 gateway. Required when useDHCP = false.";
      };

      nameservers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "1.1.1.1" "9.9.9.9" ];
        description = "DNS resolvers.";
      };

      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "example.com";
        description = "DNS search domain.";
      };

      enableIPv6 = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to enable IPv6 system-wide.";
      };
    };
  };

  config = {
    # Catch the most common misconfiguration at evaluation time rather
    # than at activation time on the target machine.
    assertions = [
      {
        assertion = cfg.network.useDHCP || cfg.network.address != null;
        message = "soctalk.tenant.network.address must be set when soctalk.tenant.network.useDHCP is false.";
      }
      {
        assertion = cfg.network.useDHCP || cfg.network.gateway != null;
        message = "soctalk.tenant.network.gateway must be set when soctalk.tenant.network.useDHCP is false.";
      }
    ];

    time.timeZone = cfg.timeZone;

    i18n.defaultLocale = cfg.locale;
    i18n.extraLocaleSettings = {
      LC_ADDRESS = cfg.locale;
      LC_IDENTIFICATION = cfg.locale;
      LC_MEASUREMENT = cfg.locale;
      LC_MONETARY = cfg.locale;
      LC_NAME = cfg.locale;
      LC_NUMERIC = cfg.locale;
      LC_PAPER = cfg.locale;
      LC_TELEPHONE = cfg.locale;
      LC_TIME = cfg.locale;
    };

    networking = {
      enableIPv6 = cfg.network.enableIPv6;
      nameservers = cfg.network.nameservers;
      domain = cfg.network.domain;
      # When useDHCP is true, cfg.network.gateway is null, which the
      # NixOS option accepts as "no static default gateway".
      defaultGateway = cfg.network.gateway;
      interfaces.${cfg.network.interface} =
        if cfg.network.useDHCP then {
          useDHCP = true;
        } else {
          useDHCP = false;
          ipv4.addresses = [{
            address = cfg.network.address;
            prefixLength = cfg.network.prefixLength;
          }];
        };
    };

    # Override disko/single-disk-bios.nix's mkDefault. A consumer who
    # wants a different layout can still pass `disko.devices = ...`
    # via extraModules with mkForce.
    disko.devices.disk.main.device = cfg.diskDevice;
  };
}
