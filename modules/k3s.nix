# K3s server + Cilium (declarative HelmChart manifest) + firewall.
#
# K3s package comes from nixpkgs-unstable via the overlay (see flake.nix)
# so we can stay current on K3s without bumping the whole base system.
#
# Cilium is installed by K3s' built-in helm-controller: NixOS writes a
# HelmChart resource to /var/lib/rancher/k3s/server/manifests/cilium.yaml
# at activation; helm-controller picks it up and runs `helm install`.
#
# The HelmChart MUST set `spec.bootstrap = true` because Cilium is the
# cluster's CNI. Without bootstrap:
#   1. K3s starts with --flannel-backend=none → no CNI → node NotReady.
#   2. K8s applies the node.kubernetes.io/not-ready:NoSchedule taint.
#   3. The helm-install-cilium Job pod ships with only the default
#      not-ready:NoExecute (300s) and unreachable:NoExecute (300s)
#      tolerations — neither covers the NoSchedule taint.
#   4. → helm-install-cilium stays Pending forever, Cilium never
#      installs, node never becomes Ready, every other pod
#      (CoreDNS / metrics-server / local-path-provisioner) is
#      Pending too.
#
# Setting spec.bootstrap = true makes K3s' helm-controller create the
# Job with hostNetwork=true AND a blanket `Operator: Exists`
# toleration, so it can run on the NotReady node and install the CNI.
# Reference: github.com/k3s-io/helm-controller — chart.go,
# `if chart.Spec.Bootstrap` branch.
#
# Cilium values live in cilium/values.yaml — edit there and re-deploy.
{ pkgs, ... }: {
  boot = {
    # Required for K3s' iptables-based service routing, masquerade, and
    # CNI bridge networking.
    kernelModules = [
      "br_netfilter"
      "overlay"
      "ip_tables"
      "iptable_nat"
      "iptable_filter"
      "nf_nat"
      "nf_conntrack"
    ];
    kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
    };
  };

  services.k3s = {
    enable = true;
    package = pkgs.unstable.k3s;
    role = "server";
    extraFlags = [
      "--flannel-backend=none"
      "--disable-network-policy"
      "--disable-kube-proxy"
      "--disable=traefik"
      "--write-kubeconfig-mode=0644"
    ];

    # Declarative Cilium install. See cilium/values.yaml for the
    # validated single-node configuration. `bootstrap = true` is
    # required (see header comment) so the helm-install Job can
    # schedule on a CNI-less node.
    manifests.cilium.content = {
      apiVersion = "helm.cattle.io/v1";
      kind = "HelmChart";
      metadata = {
        name = "cilium";
        namespace = "kube-system";
      };
      spec = {
        bootstrap = true;
        chart = "cilium";
        repo = "https://helm.cilium.io/";
        version = "1.18.4";
        targetNamespace = "kube-system";
        valuesContent = builtins.readFile ../cilium/values.yaml;
      };
    };
  };

  networking.firewall = {
    allowedTCPPorts = [
      22     # SSH
      6443   # Kubernetes API
      10250  # kubelet (kubectl logs/exec, metrics-server)
    ];
    # Loose RPF: Cilium's L3 datapath routes pod traffic via interfaces
    # that strict RPF can reject (pods enter via lxc* veths but the
    # route to the pod CIDR is via cilium_host). Loose still validates
    # that the source IP has *some* valid route on the host.
    checkReversePath = "loose";
    # Trust Cilium-managed interfaces so internal traffic (health
    # checks, vxlan, etc.) isn't filtered by the host firewall.
    trustedInterfaces = [
      "cilium_host"
      "cilium_net"
      "cilium_vxlan"
    ];
  };
}
