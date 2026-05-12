# static-network

A complete consumer flake that overrides **every** tenant option,
including a cert-manager `ClusterIssuer` backed by an internal CA.
Use this as the template for a production deployment.

## What gets configured

### System

| Option | Value |
|---|---|
| `timeZone` | `Europe/Madrid` |
| `locale` | `es_ES.UTF-8` (sets defaultLocale + all `LC_*`) |
| `diskDevice` | `/dev/nvme0n1` |
| `adminUsers` | one user: `ops` |
| `sshAuthorizedKeys` | placeholder key — **replace before deploying** |

### Networking

| Option | Value |
|---|---|
| `network.interface` | `ens18` |
| `network.address` | `192.168.10.50/24` |
| `network.gateway` | `192.168.10.1` |
| `network.nameservers` | `[1.1.1.1, 9.9.9.9]` |
| `network.domain` | `example.org` |

### cert-manager

| Option | Value |
|---|---|
| `certManager.clusterIssuer.enable` | `true` |
| `certManager.clusterIssuer.name` | `internal-ca` |
| `certManager.clusterIssuer.type` | `ca` |
| `certManager.clusterIssuer.ca.secretName` | `ca-key-pair` |
| `certManager.caSecret.enable` | `true` |
| `certManager.caSecret.name` | `ca-key-pair` *(default)* |
| `certManager.caSecret.certPath` | `/var/lib/cert-manager/ca.crt` *(default)* |
| `certManager.caSecret.keyPath` | `/var/lib/cert-manager/ca.key` *(default)* |

CA materials (`ca.crt`, `ca.key`) live under [`secrets/`](./secrets/);
they are **not** read by Nix and **not** in the closure. See
[`secrets/README.md`](./secrets/README.md) for generation and staging
instructions.

## Verify

```bash
nix flake check .

# System-level translated values:
nix eval --raw  .#nixosConfigurations.edge-01.config.time.timeZone
nix eval --raw  .#nixosConfigurations.edge-01.config.i18n.defaultLocale
nix eval --json .#nixosConfigurations.edge-01.config.networking.interfaces.ens18.ipv4.addresses
nix eval --raw  .#nixosConfigurations.edge-01.config.disko.devices.disk.main.device

# cert-manager HelmChart:
nix eval --json .#nixosConfigurations.edge-01.config.services.k3s.manifests.cert-manager.content.spec \
  | jq '{chart, version, targetNamespace}'

# ClusterIssuer (type=ca) spec:
nix eval --json .#nixosConfigurations.edge-01.config.services.k3s.manifests.cluster-issuer.content.spec

# caSecret systemd unit script references the right paths:
nix eval --raw .#nixosConfigurations.edge-01.config.systemd.services.cert-manager-ca-secret.script \
  | grep -E 'kubectl create secret|/var/lib/cert-manager'
```

## Deploy

```bash
# 1. Place CA materials under secrets/ (see secrets/README.md).
# 2. Stage them for nixos-anywhere:
mkdir -p extra-files/var/lib/cert-manager
cp secrets/ca.crt extra-files/var/lib/cert-manager/ca.crt
cp secrets/ca.key extra-files/var/lib/cert-manager/ca.key
chmod 0400 extra-files/var/lib/cert-manager/ca.key

# 3. Deploy:
nix run github:nix-community/nixos-anywhere -- \
  --extra-files ./extra-files \
  --flake .#edge-01 \
  root@<ip>
```

After boot, on the target:

```bash
systemctl status cert-manager-ca-secret.service        # loader ran OK
cmctl check api                                        # cert-manager up
kubectl -n cert-manager get secret ca-key-pair         # CA Secret present
kubectl get clusterissuer internal-ca                  # Ready: True
```

## Note on the SSH key

The `sshAuthorizedKeys` value in `flake.nix` is a placeholder. If you
deploy without replacing it, **you will lock yourself out** of the
target host because no real key authorizes you. Replace it with your
own `ssh-ed25519 …` / `ssh-rsa …` public key first.

## Ingress controller (only required for ACME http01)

This example uses a **CA** ClusterIssuer, which has no external
dependencies. If you instead switch to `letsencryptStaging` /
`letsencryptProd`, cert-manager's http01 solver needs an ingress
controller — the bundle does **not** ship one. Install one of:

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

Then set:

```nix
certManager.clusterIssuer = {
  enable = true;
  name = "letsencrypt-prod";
  type = "letsencryptProd";
  letsencrypt = {
    email = "ops@example.org";
    solver.http01.ingressClass = "traefik";   # or "nginx"
  };
};
```

(You can drop `certManager.caSecret.*` in this scenario — Let's
Encrypt mints the certificates; you don't need to provide a CA.)
