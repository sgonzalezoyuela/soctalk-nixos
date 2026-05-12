# soctalk-nixos

Single-node K3s + Cilium NixOS host, deployable to a fresh VM via
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere).

This flake is consumable two ways:

1. **As a library flake** from a downstream consumer flake that
   declares its own hosts via `soctalk-nixos.lib.mkHost { ... }` and
   overrides only the bits it needs (timezone, locale, IP, DNS, disk,
   admin users / SSH keys). See [`examples/`](./examples).
2. **As a self-contained reference deployment** for the `soctalk` host
   defined in this repo. Fork, edit `hosts/soctalk/tenant.nix`, deploy.

Lifted from the soctalk host in `/wa/nix/mynix` after that cluster's
configuration was validated end-to-end.

## What you get after a successful deploy

- NixOS 25.11 base
- K3s server (from nixos-unstable for freshness), with kube-proxy /
  flannel / network-policy / traefik all disabled
- Cilium 1.18.4 installed by K3s' helm-controller, configured for
  single-node operation: native routing, iptables masquerade,
  endpointRoutes, kube-proxy replacement
- **cert-manager v1.20.1** installed declaratively, ready for
  `ClusterIssuer` / `Certificate` resources. Optional tenant-driven
  ClusterIssuer (selfSigned / ca / letsencryptStaging / letsencryptProd)
  and an on-target CA Secret loader (`certManager.caSecret.*`) — see
  the option table below.
- kubectl + kubernetes-helm + kubecolor + k9s + cilium-cli + hubble + cmctl
  on the host
- System-wide `k = kubecolor` alias with kubectl completion bound to
  both `kubecolor` and `k`
- Firewall: SSH (22), Kubernetes API (6443), kubelet (10250), loose RPF,
  Cilium interfaces trusted
- `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` (world-readable) — admin users
  get kubectl out of the box
- Cluster is **Ready** with CoreDNS / metrics-server / local-path-provisioner
  running on first boot — no manual `helm install` step

## Consuming as a library flake

In your own flake:

```nix
{
  inputs = {
    soctalk-nixos.url = "github:sgonzalezoyuela/soctalk-nixos";
    nixpkgs.follows   = "soctalk-nixos/nixpkgs";
  };

  outputs = { self, nixpkgs, soctalk-nixos, ... }: {
    nixosConfigurations.edge-01 = soctalk-nixos.lib.mkHost {
      hostName = "edge-01";
      tenant = {
        timeZone = "Europe/Madrid";
        locale   = "es_ES.UTF-8";

        adminUsers        = [ { name = "soctalk"; description = "Soctalk Ops admin"; } ];
        sshAuthorizedKeys = [ "ssh-ed25519 AAAA... soctalk@desk001" ];

        network = {
          interface     = "ens18";
          address       = "192.168.10.50";
          prefixLength  = 24;
          gateway       = "192.168.10.1";
          nameservers   = [ "1.1.1.1" "9.9.9.9" ];
          domain        = "example.org";
        };
      };
      # extraModules = [ ./secrets.nix ];   # optional
    };
  };
}
```

Then deploy with the upstream `nixos-anywhere`:

```bash
nix run github:nix-community/nixos-anywhere -- --flake .#edge-01 root@<vm-ip>
```

See [`examples/`](./examples) for three runnable demonstrations:
`minimal/`, `static-network/`, and `dhcp/`.

### Tenant option reference

All knobs live under `soctalk.tenant.*`. Full schema in
[`modules/tenant.nix`](./modules/tenant.nix). Summary:

| Option | Type | Default | Purpose |
|---|---|---|---|
| `timeZone` | str | `UTC` | `time.timeZone` |
| `locale` | str | `en_US.UTF-8` | `i18n.defaultLocale` + all `LC_*` |
| `diskDevice` | str | `/dev/sda` | `disko.devices.disk.main.device` |
| `adminUsers` | listOf `{name, description}` | from `config/users.nix` | wheel-group users |
| `sshAuthorizedKeys` | listOf str | from `config/ssh-keys.nix` | applied to root + every admin |
| `network.useDHCP` | bool | `false` | DHCP vs static |
| `network.interface` | str | `ens18` | primary NIC name |
| `network.address` | nullOr str | `null` | required when `useDHCP = false` |
| `network.prefixLength` | int | `24` | CIDR |
| `network.gateway` | nullOr str | `null` | required when `useDHCP = false` |
| `network.nameservers` | listOf str | `[]` | DNS resolvers |
| `network.domain` | nullOr str | `null` | DNS search domain |
| `network.enableIPv6` | bool | `false` | IPv6 toggle |
| `certManager.version` | str | `v1.20.1` | cert-manager Helm chart version |
| `certManager.namespace` | str | `cert-manager` | install namespace |
| `certManager.installCRDs` | bool | `true` | render `crds.enabled` into chart values |
| `certManager.clusterIssuer.enable` | bool | `false` | opt in to declarative ClusterIssuer |
| `certManager.clusterIssuer.name` | str | `default` | `metadata.name` |
| `certManager.clusterIssuer.type` | enum | `selfSigned` | `selfSigned` \| `ca` \| `letsencryptStaging` \| `letsencryptProd` |
| `certManager.clusterIssuer.ca.secretName` | nullOr str | `null` | required when `type = "ca"` |
| `certManager.clusterIssuer.letsencrypt.email` | nullOr str | `null` | required when `type = "letsencrypt*"` |
| `certManager.clusterIssuer.letsencrypt.solver.type` | enum | `http01` | http01 only (dns01 deferred) |
| `certManager.clusterIssuer.letsencrypt.solver.http01.ingressClass` | str | `traefik` | ingress class for the http01 solver |
| `certManager.caSecret.enable` | bool | `false` | opt in to the on-target CA Secret loader |
| `certManager.caSecret.name` | str | `ca-key-pair` | Kubernetes Secret name |
| `certManager.caSecret.certPath` | str | `/var/lib/cert-manager/ca.crt` | path on target |
| `certManager.caSecret.keyPath` | str | `/var/lib/cert-manager/ca.key` | path on target |

Per-LC overrides and one-off `networking.*` tweaks still work — set
them directly via `extraModules`, module merging picks them up over
the values produced by `tenant.nix`.

### Ingress controller (required only for ACME http01)

The bundle does **not** ship an ingress controller. Two ClusterIssuer
types work without one (`selfSigned`, `ca`); the two ACME types
(`letsencryptStaging`, `letsencryptProd`) need an ingress controller
matching `letsencrypt.solver.http01.ingressClass`. Install one of:

```bash
# Option A: Traefik v3 (matches the default
# letsencrypt.solver.http01.ingressClass = "traefik")
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik -n ingress-system --create-namespace

# Option B: ingress-nginx (set
# letsencrypt.solver.http01.ingressClass = "nginx" to match)
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-system --create-namespace
```

### CA materials for `type = "ca"`

The CA's `tls.crt` and `tls.key` are **never** read by Nix — they
arrive on the target machine out-of-band and are kubectl-applied by
`cert-manager-ca-secret.service` at boot. Three staging mechanisms:

- **Fresh deploy**: `nixos-anywhere --extra-files <dir>` where `<dir>`
  mirrors `/var/lib/cert-manager/ca.{crt,key}` on the target.
- **Incremental update**: `scp` the files, then
  `systemctl restart cert-manager-ca-secret.service`.
- **Production**: encrypt at rest with `agenix` / `sops-nix` and point
  `caSecret.certPath` / `keyPath` at the decrypted tmpfs paths.

See [`examples/static-network/secrets/README.md`](./examples/static-network/secrets/README.md)
for copy-pasteable commands.

## In-repo reference deployment (`soctalk` host)

For working on the upstream itself, or for a single deployment that
doesn't warrant a consumer flake:

```bash
# 1. Provision a Proxmox VM (see below), boot the NixOS installer ISO,
#    set a temporary root password, note the IP.

# 2. Edit the in-repo tenant values (IP, hostname, etc.):
$EDITOR hosts/soctalk/tenant.nix

# 3. From your workstation:
cd /wa/soc/soctalk-nixos
./scripts/deploy.sh soctalk <vm-temp-ip>

# 4. After reboot (~2 min), SSH in with your key:
ssh atricore@<address-from-tenant.nix>
kubectl get nodes              # Ready
kubectl -n kube-system get pods  # all Running
```

The four files most likely to need editing:

| To change | Edit |
|---|---|
| Authorized SSH keys (in-repo default) | `config/ssh-keys.nix` |
| Admin usernames (in-repo default) | `config/users.nix` |
| Hostname / IP / gateway / DNS / timezone / locale / disk | `hosts/soctalk/tenant.nix` |
| cert-manager version | `soctalk.tenant.certManager.version` in `hosts/soctalk/tenant.nix` (or chart-version default in `modules/cert-manager.nix`) |
| Cilium values | `cilium/values.yaml` (+ `spec.version` in `modules/k3s.nix`) |

Other dials:

| To change | Edit |
|---|---|
| K3s package version | bump nixpkgs-unstable, or pin `pkgs.k3s_1_34` in `modules/k3s.nix` |
| K3s server flags | `modules/k3s.nix` (`extraFlags`) |
| Open firewall ports | `modules/k3s.nix` (`allowedTCPPorts`) |
| Disk layout (e.g. UEFI) | add a new file under `disko/`, swap in `flake.nix` |

## Provisioning a Proxmox VM (BIOS, virtio, ready for nixos-anywhere)

1. Download the NixOS minimal ISO from <https://nixos.org/download>
   (the "Minimal ISO image" 64-bit / Intel/AMD). Upload to a Proxmox
   storage that accepts ISOs (e.g. `local`).

2. **Create VM** → fill in:
   - **General**: any name, any VM ID
   - **OS**: Linux 6.x; ISO image = the NixOS minimal ISO
   - **System**:
     - BIOS: **seabios** (NOT OVMF — this project uses BIOS boot)
     - Machine: i440fx (default)
     - SCSI Controller: VirtIO SCSI single
     - Qemu Agent: enabled
   - **Disks**: single disk, **20+ GB**, bus = SCSI, format = qcow2 or raw
   - **CPU**: 2+ cores, Type = `host`
   - **Memory**: 4096+ MB (recommend 8192 for headroom)
   - **Network**: bridge = your LAN bridge, Model = VirtIO (paravirtualized)
   - Confirm; do **not** start yet.

3. Start the VM. It boots the NixOS minimal ISO and drops you at a
   shell.

4. On the VM console:
   ```bash
   sudo passwd                  # set a temporary root password
   ip -br a                     # note the IP (typically DHCP from your LAN)
   ```

5. From your workstation, run:
   ```bash
   cd /wa/soc/soctalk-nixos
   ./scripts/deploy.sh soctalk <vm-ip>
   ```
   You'll be prompted for the temporary root password set in step 4.
   Subsequent runs use SSH keys from `config/ssh-keys.nix`.

6. nixos-anywhere will:
   1. kexec a small NixOS installer into the running VM
   2. partition + format the disk per `disko/single-disk-bios.nix`
   3. install the system closure
   4. reboot

7. Once the VM reboots (~2 min) it has the hostname / IP / etc. from
   `hosts/soctalk/tenant.nix`, K3s up, Cilium deployed declaratively
   by helm-controller. SSH in:
   ```bash
   ssh atricore@<address>
   kubectl get nodes
   kubectl -n kube-system get pods -o wide
   ```

## Adding a new in-repo host

```bash
mkdir hosts/<new-name>
cp hosts/soctalk/tenant.nix hosts/<new-name>/tenant.nix
$EDITOR hosts/<new-name>/tenant.nix     # change IP/domain/timezone/etc.
$EDITOR flake.nix                       # add nixosConfigurations.<new-name>
nix flake check                         # validate
./scripts/deploy.sh <new-name> <ip>
```

In `flake.nix`, the addition looks like:

```nix
nixosConfigurations.<new-name> = mkHost {
  hostName = "<new-name>";
  tenant = import ./hosts/<new-name>/tenant.nix;
};
```

## Adding a new cloud / platform

See `modules/platforms/README.md`. Each platform contributes its own
hardware profile (qemu-guest vs amazon-image vs ...), initrd modules,
and bootloader settings. The default bundle imports
`modules/platforms/proxmox.nix`; for other platforms you'll currently
need to fork or override that import via `extraModules` + `mkForce`.

## Updating an already-deployed host

Two options:

```bash
# Soft re-apply (preserves data, no reboot unless kernel changes):
nixos-rebuild switch --flake .#soctalk --target-host root@<address>

# Destructive re-install (re-partitions disk; use only on disposable hosts):
./scripts/deploy.sh soctalk <address>
```

## Development

```bash
nix develop          # shell with nixos-anywhere + jq on PATH
nix flake check      # evaluate all nixosConfigurations
nix build .#nixosConfigurations.soctalk.config.system.build.toplevel

# Sanity-check every example flake:
for d in examples/*/; do nix flake check "./${d%/}"; done
```

## Project layout

```
flake.nix                       inputs / outputs / overlay / mkHost / nixosModules
flake.lock
.gitignore
README.md                       you are here

config/
  ssh-keys.nix                  defaults for soctalk.tenant.sshAuthorizedKeys
  users.nix                     defaults for soctalk.tenant.adminUsers

modules/
  base.nix                      nix settings, openssh, base CLI packages
  tenant.nix                    options + translation for soctalk.tenant.*
  users.nix                     creates users from tenant options
  k3s.nix                       K3s + Cilium manifest + firewall
  cert-manager.nix              cert-manager HelmChart + ClusterIssuer + CA Secret loader
  kubectl-tooling.nix           CLI tools (kubectl + helm + k9s + cilium-cli + hubble + cmctl) + KUBECONFIG + k alias
  platforms/
    proxmox.nix                 qemu-guest, virtio, GRUB BIOS
    README.md                   extension guide

disko/
  single-disk-bios.nix          GPT + 1M BIOS-boot + 100% ext4

cilium/
  values.yaml                   validated Cilium values

hosts/
  soctalk/
    tenant.nix                  soctalk's tenant values (plain attrset)

examples/
  README.md                     index
  minimal/                      smallest consumer flake
  static-network/               full tenant override + cert-manager CA ClusterIssuer + caSecret loader
    secrets/                    .gitignore + README; consumer-supplied ca.{crt,key} live here
  dhcp/                         tenant with DHCP

scripts/
  deploy.sh                     wrapper for `nix run .#deploy`
```

## Provenance & non-obvious choices

Lifted from `/wa/nix/mynix/hosts/soctalk/`. A few decisions worth
calling out:

- **`routingMode: native`** in `cilium/values.yaml`. The earlier
  `tunnel` (VXLAN) mode produced a particularly subtle failure on a
  single-node cluster: packets were silently consumed by Cilium's BPF
  with no drop counter, no iptables hits, and no kernel forwarding
  recorded. Native routing was the fix.
- **`bpf.masquerade: false`** and **`enableIPv4Masquerade: true`**.
  NixOS uses iptables-nft as the iptables backend; BPF masquerade is
  flaky on this combo today. Iptables masquerade is the reliable path.
- **`endpointRoutes.enabled: true`**. Installs per-pod /32 routes on
  the host so even strict reverse-path-filtering setups work.
- **`networking.firewall.checkReversePath = "loose"`** in
  `modules/k3s.nix`. Pod traffic enters via `lxc*` veths but the route
  to the pod CIDR is via `cilium_host`; strict RPF drops it.
- **GPT + 1M BIOS-boot partition** instead of pure MBR (msdos). Boot-
  equivalent on seabios, but disko prefers GPT and avoids deprecation
  warnings. To switch to UEFI later, replace `single-disk-bios.nix`
  with a new disko profile that includes an ESP and use
  `boot.loader.systemd-boot` instead of `boot.loader.grub`.
- **K3s from nixos-unstable**. The base system is on 25.11; only K3s
  + Cilium-related CLIs (kubecolor, k9s, cilium-cli, hubble) come from
  unstable, so cluster tooling can stay fresh without churning the
  whole system.
- **Coarse `nixosModules.default`**. The bundle is deliberately
  all-or-nothing (base + tenant + users + K3s + Cilium + kubectl
  tooling + proxmox + single-disk-bios + unstable overlay). This is a
  K3s appliance flake, not a generic NixOS base. Consumers who want
  the base without K3s should fork rather than mix-and-match modules.
