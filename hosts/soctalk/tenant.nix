# Tenant values for the in-repo `soctalk` reference host.
#
# Imported by the top-level flake.nix and passed to
# soctalk-nixos.lib.mkHost as the `tenant` argument. The attrset shape
# mirrors `soctalk.tenant.*` declared in modules/tenant.nix.
#
# To add another in-repo host:
#   mkdir hosts/<new-name>
#   cp hosts/soctalk/tenant.nix hosts/<new-name>/tenant.nix
#   $EDITOR hosts/<new-name>/tenant.nix          # change IP/domain/tz/etc.
#   $EDITOR flake.nix                            # add nixosConfigurations.<new-name>
{
  timeZone = "America/New_York";
  locale = "en_US.UTF-8";

  network = {
    interface = "ens18";
    address = "10.0.1.29";
    prefixLength = 8;
    gateway = "10.0.0.1";
    nameservers = [ "10.0.1.77" ];
    domain = "lab.atricore.io";
    enableIPv6 = false;
  };
}
