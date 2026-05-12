# static-network

A complete consumer flake that overrides **every** tenant option. Use
this as the template for a production deployment.

## What gets configured

| Option | Value |
|---|---|
| `timeZone` | `Europe/Madrid` |
| `locale` | `es_ES.UTF-8` (sets defaultLocale + all `LC_*`) |
| `diskDevice` | `/dev/nvme0n1` |
| `adminUsers` | one user: `ops` |
| `sshAuthorizedKeys` | placeholder key — **replace before deploying** |
| `network.interface` | `ens18` |
| `network.address` | `192.168.10.50/24` |
| `network.gateway` | `192.168.10.1` |
| `network.nameservers` | `[1.1.1.1, 9.9.9.9]` |
| `network.domain` | `example.org` |

## Verify

```bash
nix flake check .

# Confirm a few translated values:
nix eval --raw  .#nixosConfigurations.edge-01.config.time.timeZone
nix eval --raw  .#nixosConfigurations.edge-01.config.i18n.defaultLocale
nix eval --json .#nixosConfigurations.edge-01.config.networking.interfaces.ens18.ipv4.addresses
nix eval --raw  .#nixosConfigurations.edge-01.config.disko.devices.disk.main.device
```

## Deploy

```bash
nix run github:nix-community/nixos-anywhere -- --flake .#edge-01 root@<ip>
```

## Note on the SSH key

The `sshAuthorizedKeys` value in `flake.nix` is a placeholder. If you
deploy without replacing it, **you will lock yourself out** of the
target host because no real key authorizes you. Replace it with your
own `ssh-ed25519 …` / `ssh-rsa …` public key first.
