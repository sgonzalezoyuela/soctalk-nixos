# Creates admin users + roots' authorized_keys from the
# soctalk.tenant.adminUsers / soctalk.tenant.sshAuthorizedKeys options.
#
# Defaults are sourced from config/{users,ssh-keys}.nix so that
# in-repo behavior is preserved when no tenant override is provided.
# Downstream consumers override via:
#
#   soctalk.tenant.adminUsers = [ { name = "ops"; description = "Ops"; } ];
#   soctalk.tenant.sshAuthorizedKeys = [ "ssh-ed25519 AAAA... ops@laptop" ];
{ config, ... }:
let
  cfg = config.soctalk.tenant;

  mkAdminUser = u: {
    name = u.name;
    value = {
      isNormalUser = true;
      description = if u.description == "" then u.name else u.description;
      extraGroups = [ "users" "wheel" ];
      openssh.authorizedKeys.keys = cfg.sshAuthorizedKeys;
    };
  };

  userEntries = builtins.listToAttrs (map mkAdminUser cfg.adminUsers);
in
{
  users.users = userEntries // {
    root.openssh.authorizedKeys.keys = cfg.sshAuthorizedKeys;
  };

  # wheel group is passwordless. Trade-off: convenient for remote
  # rebuilds; relies on SSH access being the primary trust boundary.
  security.sudo.wheelNeedsPassword = false;
}
