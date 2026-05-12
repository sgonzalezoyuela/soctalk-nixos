# soctalk-nixos consumer using DHCP for networking.
#
# With `network.useDHCP = true`, the tenant-level assertions allow
# address/gateway to remain unset and the primary interface is
# configured for DHCP.
#
# Useful for hosts in environments where the upstream router hands out
# leases (home labs, dev VMs, ephemeral cloud instances).
#
# Build:
#   nix build .#nixosConfigurations.dhcp-demo.config.system.build.toplevel
{
  description = "soctalk-nixos consumer with DHCP networking.";

  inputs = {
    soctalk-nixos.url = "path:../..";
    nixpkgs.follows = "soctalk-nixos/nixpkgs";
  };

  outputs = { self, nixpkgs, soctalk-nixos, ... }: {
    nixosConfigurations.dhcp-demo = soctalk-nixos.lib.mkHost {
      hostName = "dhcp-demo";
      tenant = {
        timeZone = "America/New_York";
        network = {
          useDHCP = true;
          interface = "ens18";
          # nameservers is optional under DHCP — DHCP typically supplies
          # them. Keep an explicit value if you want to override what
          # the DHCP server pushes:
          # nameservers = [ "1.1.1.1" ];
        };
      };
    };
  };
}
