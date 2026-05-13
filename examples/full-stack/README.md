# full-stack

End-to-end production-shape consumer flake: K3s + Cilium +
cert-manager + ClusterIssuer + OAuth2-Proxy (OIDC) + Ingress +
TLS-via-cert-manager + **soctalk-system** itself.

This example proves the full chain from a fresh VM to a running
SocTalk install — every other example is a strict subset.

## What gets configured

### System

| | |
|---|---|
| Hostname | `edge-01` |
| FQDN | `edge-01.example.org` (used as the OIDC host) |
| Static IP | `192.168.10.50/24`, gateway `192.168.10.1` |
| Admin user | `ops` |

### cert-manager

| | |
|---|---|
| ClusterIssuer | `internal-ca` (type `ca`) |
| CA Secret | loaded by `cert-manager-ca-secret.service` from `/var/lib/cert-manager/ca.{crt,key}` |

### OAuth2-Proxy

| | |
|---|---|
| Chart version | `10.4.3` (bundles app `v7.15.2`) |
| Host | `edge-01.example.org` |
| OIDC issuer | `https://idp.example.org/` — **replace** with your IdP |
| Ingress class | `traefik` |
| TLS | enabled; cert minted by `internal-ca` into Secret `oauth2-proxy-tls` |
| Credentials | `client-id` + `client-secret` from `/var/lib/oauth2-proxy/` (you stage these); `cookie-secret` auto-generated on first boot |

### soctalk-system

| | |
|---|---|
| Chart | `oci://ghcr.io/gbrigandi/charts/soctalk-system` v `0.1.0` |
| MSSP UUID | `11111111-…` — **replace** with your real UUID (`uuidgen \| tr A-Z a-z`) |
| MSSP name | `Acme Security` — **replace** |
| Install UUID | `22222222-…` — **replace** |
| Install label | `pilot-prod` |
| MSSP hostname | `mssp.example.org` |
| Customer hostname | `*.customers.example.org` |
| Ingress class | `traefik` |
| TLS | enabled; cert for `mssp.example.org` minted by `internal-ca` into Secret `soctalk-tls`. **Wildcard customer host needs a separate DNS-01 cert** (see [Wildcard certificate](#wildcard-certificate) below) |
| Trusted proxy CIDRs | `[10.42.0.0/16]` (K3s pod CIDR) |
| Postgres | enabled; 20Gi PVC on local-path-provisioner |

## Prerequisites

1. **Generate / obtain CA materials** — see [`secrets/README.md`](./secrets/README.md).
2. **Register an OIDC client** with your IdP. Configure
   `https://edge-01.example.org/oauth2/callback` as the authorized
   redirect URI.
3. **Generate MSSP / install UUIDs** locally and pin them in
   `flake.nix`:
   ```bash
   uuidgen | tr A-Z a-z   # msspId
   uuidgen | tr A-Z a-z   # installId
   ```
   These must be stable across re-deploys of the same MSSP
   installation.
4. **DNS**: point both `mssp.example.org` and `*.customers.example.org`
   at the target host's public IP.

## Deploy

```bash
# 1. Stage CA + OIDC IdP credentials for nixos-anywhere --extra-files
mkdir -p extra-files/var/lib/cert-manager extra-files/var/lib/oauth2-proxy
cp secrets/ca.crt        extra-files/var/lib/cert-manager/ca.crt
cp secrets/ca.key        extra-files/var/lib/cert-manager/ca.key
cp secrets/client-id     extra-files/var/lib/oauth2-proxy/client-id
cp secrets/client-secret extra-files/var/lib/oauth2-proxy/client-secret
chmod 0400 extra-files/var/lib/cert-manager/ca.key \
           extra-files/var/lib/oauth2-proxy/*

# 2. Deploy
nix run github:nix-community/nixos-anywhere -- \
  --extra-files ./extra-files \
  --flake .#edge-01 \
  root@<ip>
```

## Post-deploy: install the ingress controller

The bundle does **not** ship one. Install Traefik v3 to match the
default `ingress.className`:

```bash
ssh ops@edge-01.example.org

helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik \
  -n ingress-system --create-namespace
```

If you switch the consumer flake to `ingress.className = "nginx"`,
use ingress-nginx instead:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-system --create-namespace
```

## Verify

```bash
# Loaders ran successfully:
systemctl status cert-manager-ca-secret.service
systemctl status oauth2-proxy-secrets.service

# cert-manager + ClusterIssuer:
cmctl check api
kubectl get clusterissuer internal-ca

# OAuth2-Proxy stack:
kubectl -n ingress-system get pods,svc,ingress,certificate,secret \
  -l 'app.kubernetes.io/name in (oauth2-proxy)'
kubectl -n ingress-system get certificate oauth2-proxy-tls

# soctalk-system stack:
kubectl -n soctalk-system get pods,svc,ingress,certificate
kubectl -n soctalk-system get certificate soctalk-tls
kubectl -n soctalk-system logs deploy/soctalk-system --tail=30

# Hit the auth + main endpoints:
curl -kI https://edge-01.example.org/oauth2/start    # → 302 to IdP
curl -kI https://mssp.example.org/                   # → through OAuth2-Proxy → SocTalk
```

## Wildcard certificate

`*.customers.example.org` requires a wildcard TLS certificate. **The
default `tls.includeWildcard = false`** in `system.tls.*`, so the
rendered Certificate covers **only** `mssp.example.org`. Let's Encrypt
http01 (and our internal CA) cannot issue wildcards in the current
bundle.

Three paths for the customer-host TLS:

1. **Provide it externally**: manually `kubectl apply` a `Secret`
   named `soctalk-tls` (or change `system.tls.secretName`) that
   contains a wildcard cert + key.
2. **Use a DNS-01 ClusterIssuer for the wildcard**: wire a
   DNS-01-capable Issuer (cert-manager's
   `letsencrypt-prod-dns01` pattern, ACME-DNS, Cloudflare, etc.) and
   render a *second* `Certificate` resource via `extraModules` that
   covers `*.customers.example.org`.
3. **Flip `system.tls.includeWildcard = true`**: the rendered
   Certificate's `dnsNames` will include both hostnames. **Only
   works** when the configured ClusterIssuer can do DNS-01; with
   http01 it will sit in `Issuing` failed forever.

## Note on the placeholder values

Both the SSH key and the MSSP/install UUIDs in `flake.nix` are
placeholders. Replace them before deploying — leaving the UUIDs as-is
won't break the install, but it will conflict with anyone else who
forgot to replace them.
