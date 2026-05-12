# Full-featured soctalk-nixos consumer.
#
# Overrides every tenant option: timezone, locale, disk device,
# admin user, SSH key, and full static-IP networking with DNS and
# search domain.
#
# Build:
#   nix build .#nixosConfigurations.edge-01.config.system.build.toplevel
#
# Deploy:
#   nix run github:nix-community/nixos-anywhere -- --flake .#edge-01 root@<ip>
{
  description = "Fully customized soctalk-nixos consumer (static IP).";

  inputs = {
    soctalk-nixos.url = "path:../..";
    nixpkgs.follows = "soctalk-nixos/nixpkgs";
  };

  outputs = { self, nixpkgs, soctalk-nixos, ... }: {
    nixosConfigurations.edge-01 = soctalk-nixos.lib.mkHost {
      hostName = "edge-01";
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
      };
    };
  };
}
