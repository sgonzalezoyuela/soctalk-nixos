# Admin users created on every host in this project.
#
# Each user gets:
#   - isNormalUser = true
#   - extraGroups = [ "users" "wheel" ]
#   - openssh.authorizedKeys.keys = (config/ssh-keys.nix).admin
#
# Add more users by appending an entry. The user's SSH keys come from
# config/ssh-keys.nix; per-user key partitioning isn't supported here yet
# (intentionally — keep it simple, all admins share the same key list).

{
  admin = [
    {
      name = "atricore";
      description = "atricore";
    }
  ];
}
