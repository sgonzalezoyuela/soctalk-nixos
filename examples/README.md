# Consumer flake examples

These flakes demonstrate consuming `soctalk-nixos` as a library to
build your own NixOS host without forking the repository. Each example
is a fully evaluable flake — `nix flake check` from inside the example
directory will type-check it against the real module schema.

## What's here

| Example | What it demonstrates |
|---|---|
| [`minimal/`](./minimal) | Smallest possible consumer flake: only the required network fields, everything else defaulted (UTC, en_US.UTF-8, in-repo admin users + SSH keys, /dev/sda, ens18). |
| [`static-network/`](./static-network) | Full tenant override: timezone, locale, static IP, DNS, gw, admin user, SSH key, plus a cert-manager `ca` ClusterIssuer with the CA loaded from on-target files. The "this is how you really configure a host" example. |
| [`dhcp/`](./dhcp) | `network.useDHCP = true` — no static IP/gateway needed, the tenant-level assertion lets DHCP through. |
| [`oidc/`](./oidc) | End-to-end auth stack: cert-manager + CA ClusterIssuer + OAuth2-Proxy + Ingress + cert-manager-minted TLS for the OIDC host. Demonstrates the host-derivation pattern (`oidc.host = "${hostName}.${domain}"`), the `redirectUrl` override, and the canonical ingress-nginx / Traefik auth-url annotation patterns. |

## Local vs github inputs

Each example uses a **relative path input** for `soctalk-nixos`:

```nix
inputs.soctalk-nixos.url = "path:../..";
```

That makes the examples evaluable from a fresh clone of this repo
without needing the upstream to be published. In your own consumer
flake, swap that to the published URL, e.g.

```nix
inputs.soctalk-nixos.url = "github:atricore/soctalk-nixos";
```

(or pin to a tag / commit: `github:atricore/soctalk-nixos/v0.1.0`).

## Trying an example

```bash
# Evaluate the example's module tree:
nix flake check ./examples/minimal

# Build the system closure (no deploy, just produces a derivation):
nix build ./examples/minimal#nixosConfigurations.demo.config.system.build.toplevel

# Deploy to a fresh VM via nixos-anywhere:
nix run github:nix-community/nixos-anywhere -- \
  --flake ./examples/minimal#demo root@<vm-ip>
```

## Checking everything at once

```bash
for d in examples/*/; do
  echo "=== $d ==="
  nix flake check "./${d%/}"
done
```

(The `./` prefix is required so `nix flake check` treats the argument
as a path rather than a registry lookup.)

## flake.lock files

Each example commits its own `flake.lock` so the example is bit-for-bit
reproducible from a fresh clone. They are kept in sync with the root
`flake.lock` by running `nix flake update` inside each example dir
when the root lock is bumped.
