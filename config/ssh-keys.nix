# Authorized SSH keys for all admin users in this project.
#
# Edit this file to add/remove admin keys. The keys here are deployed to:
#   - root@<host>
#   - every user listed in config/users.nix
#
# Re-deploy after editing:
#   ./scripts/deploy.sh <host> <ip>           # destructive, full re-install
# or, if the host is already up:
#   nixos-rebuild switch --flake .#<host> --target-host root@<host-ip>
#
# These keys were lifted from /wa/nix/mynix/hosts/common/ssh-keys.nix.

{
  admin = [
  ];
}
