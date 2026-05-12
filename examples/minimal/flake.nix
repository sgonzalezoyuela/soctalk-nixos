# Minimal soctalk-nixos consumer flake.
#
# Sets only the required network knobs; every other tenant option is
# left at its default (UTC, en_US.UTF-8, /dev/sda, ens18, in-repo
# admin users + SSH keys).
#
# Build the system closure:
#   nix build .#nixosConfigurations.demo.config.system.build.toplevel
#
# Deploy to a fresh VM:
#   nix run github:nix-community/nixos-anywhere -- --flake .#demo root@<ip>
{
  description = "Minimal soctalk-nixos consumer.";

  inputs = {
    # In a real consumer flake, replace with:
    #   soctalk-nixos.url = "github:atricore/soctalk-nixos";
    soctalk-nixos.url = "path:../..";

    # Share the upstream's pinned nixpkgs so the lockfile stays small.
    nixpkgs.follows = "soctalk-nixos/nixpkgs";
  };

  outputs = { self, nixpkgs, soctalk-nixos, ... }: {
    nixosConfigurations.demo = soctalk-nixos.lib.mkHost {
      hostName = "demo";
      tenant = {
        network = {
          address = "10.0.0.50";
          gateway = "10.0.0.1";
          nameservers = [ "1.1.1.1" ];
        };
      };
    };
  };
}
