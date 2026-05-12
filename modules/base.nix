# Shared baseline: nix settings, openssh, base CLI tools, etc.
# Tenant-specific overrides (timezone, locale, networking, users, disk)
# live behind `soctalk.tenant.*` (see modules/tenant.nix).
{ pkgs, ... }: {
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    max-jobs = "auto";
  };

  nixpkgs.config.allowUnfree = true;

  boot.tmp.cleanOnBoot = true;

  zramSwap.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      # Required for nixos-anywhere and subsequent remote rebuilds.
      # Tighten to "prohibit-password" once you've validated key-based access.
      PermitRootLogin = "yes";
      PasswordAuthentication = false;
    };
  };

  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  programs.vim = {
    enable = true;
    defaultEditor = true;
  };

  environment.systemPackages = with pkgs; [
    bat
    curl
    git
    htop
    jq
    rsync
    tmux
    vim
    wget
  ];

  # Pin state version. Update when intentionally migrating to a newer
  # NixOS release (read the release notes first).
  system.stateVersion = "25.11";
}
