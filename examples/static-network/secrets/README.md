# `secrets/` — tenant CA materials

This directory holds the **CA certificate and private key** consumed
by the example's `certManager.clusterIssuer` (type = `ca`) plus
`certManager.caSecret` loader.

Two invariants:

1. **The bytes never enter the Nix store.** The flake does *not*
   call `builtins.readFile` on anything in here. The files are
   staged onto the target machine out-of-band; the on-target systemd
   unit `cert-manager-ca-secret.service` reads them at boot and
   `kubectl apply`s them as a `kubernetes.io/tls` Secret.
2. **Only `.gitignore` and `README.md` are tracked** (see
   `.gitignore`). Real CA materials are gitignored and your
   responsibility to keep safe.

## 1. Generate a self-signed CA (lab / dev)

```bash
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/CN=Example Internal CA" -out ca.crt
chmod 0400 ca.key
```

For production, mint the CA in an offline ceremony, store the
private key in an HSM / vault, and only ever expose the operational
intermediate to the cluster.

## 2. Stage onto the target

### Option A — `nixos-anywhere --extra-files` (fresh, destructive deploy)

```bash
# Build a staging tree whose layout mirrors the target root.
mkdir -p extra-files/var/lib/cert-manager
cp secrets/ca.crt extra-files/var/lib/cert-manager/ca.crt
cp secrets/ca.key extra-files/var/lib/cert-manager/ca.key
chmod 0400 extra-files/var/lib/cert-manager/ca.key

# Then deploy normally:
nix run github:nix-community/nixos-anywhere -- \
  --extra-files ./extra-files \
  --flake .#edge-01 \
  root@<ip>
```

`systemd-tmpfiles` rules in `modules/cert-manager.nix` enforce
`0400 root:root` on `ca.key` and `0444 root:root` on `ca.crt` at
boot, so even if `--extra-files` lands them with looser perms they
get tightened.

### Option B — scp + `nixos-rebuild` (incremental update)

```bash
ssh root@<ip> 'install -d -m 0700 /var/lib/cert-manager'
scp secrets/ca.crt root@<ip>:/var/lib/cert-manager/ca.crt
scp secrets/ca.key root@<ip>:/var/lib/cert-manager/ca.key
ssh root@<ip> 'chmod 0400 /var/lib/cert-manager/ca.key && chmod 0444 /var/lib/cert-manager/ca.crt'

nixos-rebuild switch --flake .#edge-01 --target-host root@<ip>
ssh root@<ip> 'systemctl restart cert-manager-ca-secret.service'
```

### Option C — `agenix` / `sops-nix` (production)

Encrypt `ca.crt` / `ca.key` at rest in the consumer repo with
[agenix](https://github.com/ryantm/agenix) or
[sops-nix](https://github.com/Mic92/sops-nix). The agenix / sops-nix
NixOS module decrypts to a `tmpfs`-backed path on the target at
boot. Point the tenant options at those paths:

```nix
certManager.caSecret = {
  enable = true;
  certPath = "/run/agenix/cert-manager-ca.crt";
  keyPath  = "/run/agenix/cert-manager-ca.key";
};
```

This is the **recommended pattern for production** — keys are never
at rest in plaintext on the deploy workstation, in the repo, or on
the target outside the encrypted-at-rest tmpfs lifetime.

AGENTS.md §18 explicitly leaves secrets-backend choice to the
consumer; `soctalk-nixos` only provides the on-target loader.

## 3. Verify after deploy

```bash
ssh root@<ip>

# The loader ran successfully:
systemctl status cert-manager-ca-secret.service

# cert-manager is reachable and CRDs are established:
cmctl check api

# The Secret exists in the cert-manager namespace:
kubectl -n cert-manager get secret ca-key-pair

# The ClusterIssuer is Ready:
kubectl get clusterissuer internal-ca
kubectl describe clusterissuer internal-ca | tail -10
```

When the ClusterIssuer reports `Ready: True`, certificate requests
that reference `issuerRef: { kind: ClusterIssuer, name: internal-ca }`
will be signed by your CA.

## 4. Rotating the CA

1. Replace `ca.crt` and `ca.key` in this directory.
2. Re-stage onto the target via your chosen mechanism (A / B / C above).
3. `systemctl restart cert-manager-ca-secret.service` on the target
   — the unit's `kubectl apply` is idempotent and updates the Secret
   in place.
4. Existing certificates remain valid until expiration; new ones
   issued from this ClusterIssuer use the new CA.
