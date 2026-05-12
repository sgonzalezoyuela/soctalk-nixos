{
  description = "soctalk-nixos: single-node K3s + Cilium NixOS host library flake, deployable via nixos-anywhere";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
  };

  outputs =
    { self
    , nixpkgs
    , nixpkgs-unstable
    , disko
    , nixos-anywhere
    , ...
    }:
    let
      system = "x86_64-linux";

      # Overlay that exposes nixos-unstable as `pkgs.unstable.*`. Used so
      # we can bump K3s / Cilium tooling independently of the base system.
      overlay-unstable = final: prev: {
        unstable = import nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
      };

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ overlay-unstable ];
        config.allowUnfree = true;
      };

      # The coarse module bundle. Imports everything a soctalk-nixos
      # host needs: base, tenant options, users, K3s + Cilium, kubectl
      # tooling, the proxmox platform profile, and the single-disk-bios
      # disko layout. Also wires the unstable overlay so callers don't
      # have to.
      soctalkModule = { ... }: {
        imports = [
          disko.nixosModules.disko
          ./modules/base.nix
          ./modules/tenant.nix
          ./modules/users.nix
          ./modules/k3s.nix
          ./modules/cert-manager.nix
          ./modules/oidc.nix
          ./modules/kubectl-tooling.nix
          ./modules/platforms/proxmox.nix
          ./disko/single-disk-bios.nix
        ];
        nixpkgs.overlays = [ overlay-unstable ];
      };

      # Library helper: build a nixosSystem with the soctalk-nixos
      # default bundle plus a tenant attrset.
      #
      # Usage (from a consumer flake):
      #
      #   nixosConfigurations.myhost = soctalk-nixos.lib.mkHost {
      #     hostName = "myhost";
      #     tenant = {
      #       timeZone = "Europe/Madrid";
      #       network  = { address = "10.0.0.10"; gateway = "10.0.0.1"; };
      #     };
      #     extraModules = [ ./secrets.nix ];   # optional
      #   };
      mkHost =
        { hostName
        , system ? "x86_64-linux"
        , tenant ? { }
        , extraModules ? [ ]
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit self; };
          modules = [
            self.nixosModules.default
            ({ ... }: {
              networking.hostName = hostName;
              soctalk.tenant = tenant;
            })
          ] ++ extraModules;
        };
    in
    {
      # The full coarse bundle. Either:
      #   1. Use soctalk-nixos.lib.mkHost (recommended; see examples/).
      #   2. Hand-roll with nixpkgs.lib.nixosSystem and import this
      #      module yourself.
      nixosModules.default = soctalkModule;

      # Library functions re-exported for consumer flakes.
      lib = { inherit mkHost; };

      # In-repo reference host. Demonstrates `mkHost` with the values
      # in hosts/soctalk/tenant.nix. Consumer flakes don't need to
      # touch this — they declare their own nixosConfigurations.
      nixosConfigurations.soctalk = mkHost {
        hostName = "soctalk";
        tenant = import ./hosts/soctalk/tenant.nix;
      };

      # `nix run .#deploy -- <host> <ip> [extra nixos-anywhere args...]`
      #
      # Convenience wrapper around the flake-pinned nixos-anywhere. Must
      # be invoked from the project root (the .#deploy app uses
      # `.#<host>` internally so nixos-anywhere can locate the flake).
      apps.${system}.deploy = {
        type = "app";
        meta.description = "Deploy a host via nixos-anywhere (usage: nix run .#deploy -- <host> <ip>)";
        program = "${pkgs.writeShellScript "deploy-soctalk-nixos" ''
          set -euo pipefail
          if [ "$#" -lt 2 ]; then
            echo "Usage: nix run .#deploy -- <host> <ip> [extra nixos-anywhere args...]" >&2
            exit 1
          fi
          host="$1"
          ip="$2"
          shift 2
          exec ${nixos-anywhere.packages.${system}.default}/bin/nixos-anywhere \
            --flake ".#$host" \
            "root@$ip" "$@"
        ''}";
      };

      # Convenience devshell so contributors can `nix develop` to get
      # nixos-anywhere on PATH without rooting through the apps entry.
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          nixos-anywhere.packages.${system}.default
          pkgs.jq
        ];
      };
    };
}
