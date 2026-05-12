# oidc

End-to-end consumer flake demonstrating cert-manager + ClusterIssuer
+ OAuth2-Proxy (OIDC) + Ingress + TLS via cert-manager. This is the
"production-shape" example — everything wired together.

## What gets configured

### System

| | |
|---|---|
| Hostname | `edge-01` |
| FQDN | `edge-01.example.org` *(used as the OIDC host)* |
| Static IP | `192.168.10.50/24`, gateway `192.168.10.1` |
| Admin user | `ops` |

### cert-manager

| | |
|---|---|
| ClusterIssuer name | `internal-ca` |
| ClusterIssuer type | `ca` (signs with your internal CA) |
| CA Secret | loaded by `cert-manager-ca-secret.service` from `/var/lib/cert-manager/ca.{crt,key}` |

### OIDC (OAuth2-Proxy)

| | |
|---|---|
| Chart version | `10.4.3` *(default; bundles OAuth2-Proxy app `v7.15.2`)* |
| Namespace | `ingress-system` *(default)* |
| OIDC host | `edge-01.example.org` *(derived from hostname + domain)* |
| Redirect URL | `https://edge-01.example.org/oauth2/callback` *(derived)* |
| OIDC issuer | `https://idp.example.org/` — **replace** with your IdP |
| Ingress class | `traefik` — change if you installed `ingress-nginx` |
| TLS | enabled; cert minted by the `internal-ca` ClusterIssuer into Secret `oauth2-proxy-tls` |
| Credentials | loaded by `oauth2-proxy-secrets.service` from `/var/lib/oauth2-proxy/{client-id,client-secret,cookie-secret}` |

## Prerequisites

1. **Generate / obtain CA materials** — see [`secrets/README.md`](./secrets/README.md).
2. **Register an OIDC client** with your IdP (Keycloak, Authentik, Auth0, Okta, Dex, …). Note the client ID + secret. Configure the IdP to accept `https://edge-01.example.org/oauth2/callback` as a valid redirect URL.
3. **Stage credentials locally** under `./secrets/` — see [`secrets/README.md`](./secrets/README.md).
4. **Install an ingress controller** in the cluster (post-deploy, see below).

## Deploy

```bash
# 1. Stage all secrets for nixos-anywhere --extra-files
mkdir -p extra-files/var/lib/cert-manager extra-files/var/lib/oauth2-proxy
cp secrets/ca.crt        extra-files/var/lib/cert-manager/ca.crt
cp secrets/ca.key        extra-files/var/lib/cert-manager/ca.key
cp secrets/client-id     extra-files/var/lib/oauth2-proxy/client-id
cp secrets/client-secret extra-files/var/lib/oauth2-proxy/client-secret
cp secrets/cookie-secret extra-files/var/lib/oauth2-proxy/cookie-secret
chmod 0400 extra-files/var/lib/cert-manager/ca.key \
           extra-files/var/lib/oauth2-proxy/*

# 2. Deploy
nix run github:nix-community/nixos-anywhere -- \
  --extra-files ./extra-files \
  --flake .#edge-01 \
  root@<ip>
```

## Post-deploy: install an ingress controller

The bundle does **not** ship one. Install Traefik v3 to match the
default `ingress.className`:

```bash
ssh ops@edge-01.example.org   # or whatever IP/hostname

helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik \
  -n ingress-system --create-namespace
```

Or, if you'd rather use `ingress-nginx`, change
`oidc.ingress.className = "nginx"` in `flake.nix`, redeploy, and:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-system --create-namespace
```

## Verify

```bash
# Every loader ran successfully:
systemctl status cert-manager-ca-secret.service
systemctl status oauth2-proxy-secrets.service

# cert-manager + ClusterIssuer + Certificate:
cmctl check api
kubectl get clusterissuer internal-ca
kubectl -n ingress-system get certificate oauth2-proxy-tls
kubectl -n ingress-system get secret oauth2-proxy-tls

# OAuth2-Proxy + its secrets + its Ingress:
kubectl -n ingress-system get pods -l app.kubernetes.io/name=oauth2-proxy
kubectl -n ingress-system get secret oauth2-proxy-secrets
kubectl -n ingress-system get ingress oauth2-proxy

# Hit the auth endpoint (should 302 → IdP):
curl -kI https://edge-01.example.org/oauth2/start
```

## Protecting your own apps

Once OAuth2-Proxy is up, protect any Ingress with auth-url
annotations. ingress-nginx pattern (matches your prompt):

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/auth-url:     "https://$host/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin:  "https://$host/oauth2/start?rd=$escaped_request_uri"
    nginx.ingress.kubernetes.io/auth-response-headers: X-Auth-Request-User, X-Auth-Request-Email, X-Auth-Request-Groups
```

Traefik v3 equivalent (via a `Middleware` resource):

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: oauth2-proxy-forward-auth, namespace: <your-ns> }
spec:
  forwardAuth:
    address: http://oauth2-proxy.ingress-system.svc.cluster.local:80/oauth2/auth
    trustForwardHeader: true
    authResponseHeaders:
      - X-Auth-Request-User
      - X-Auth-Request-Email
      - X-Auth-Request-Groups
```

Then reference the Middleware on the protected app's Ingress
(via the `traefik.ingress.kubernetes.io/router.middlewares` annotation).

## Note on the SSH key

The `sshAuthorizedKeys` value is a placeholder. Replace it with your
real public key before deploying or you'll lock yourself out.

## Variants

### Local / dev: override `redirectUrl`

```nix
oidc = {
  enable = true;
  issuerUrl = "https://idp.example.org/";
  redirectUrl = "http://localhost:4180/oauth2/callback";   # for kubectl port-forward dev
  tls.enable = false;
};
```

### Let's Encrypt instead of internal CA

Drop `certManager.caSecret.*` and switch the issuer:

```nix
certManager.clusterIssuer = {
  enable = true;
  name = "letsencrypt-prod";
  type = "letsencryptProd";
  letsencrypt = {
    email = "ops@example.org";
    solver.http01.ingressClass = "traefik";   # must match installed ingress
  };
};
oidc.tls.issuerRef = "letsencrypt-prod";   # derived from clusterIssuer.name anyway
```

The Let's Encrypt http01 solver also needs the ingress controller
installed first (chicken-and-egg with a fresh deploy: cert won't
issue until you install the ingress).
