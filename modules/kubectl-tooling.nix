# Cluster-management CLIs + KUBECONFIG wiring + the `k` shell alias and
# kubectl completion (installed system-wide so it works for any user).
{ pkgs, ... }: {
  environment = {
    systemPackages = with pkgs; [
      kubectl              # stable: track cluster API minor
      kubernetes-helm      # stable
      unstable.kubecolor   # unstable: track newest features
      unstable.k9s
      unstable.cilium-cli
      unstable.hubble
      unstable.cmctl       # cert-manager CLI: `cmctl check api`, etc.
    ];

    # World-readable kubeconfig is set up by K3s with
    # --write-kubeconfig-mode=0644 (see modules/k3s.nix). Pointing
    # KUBECONFIG at it makes kubectl Just Work for every shell.
    variables = {
      KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    };

    shellAliases = {
      k = "kubecolor";
    };
  };

  # Bind kubectl's completion to both `kubecolor` and the `k` alias.
  # kubectl's bash completion script defines __start_kubectl; reusing it
  # is upstream Cilium/kubecolor's recommended pattern.
  programs.bash.interactiveShellInit = ''
    if command -v kubectl >/dev/null 2>&1; then
      source <(kubectl completion bash)
      complete -o default -F __start_kubectl kubecolor
      complete -o default -F __start_kubectl k
    fi
  '';
}
