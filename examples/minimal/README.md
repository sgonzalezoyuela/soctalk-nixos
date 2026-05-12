# minimal

The smallest consumer flake that still produces a deployable host.

## What gets configured

Only the three required network fields are set:

| Field | Value |
|---|---|
| `soctalk.tenant.network.address` | `10.0.0.50` |
| `soctalk.tenant.network.gateway` | `10.0.0.1` |
| `soctalk.tenant.network.nameservers` | `[ "1.1.1.1" ]` |

Everything else falls back to the option defaults declared in
[`modules/tenant.nix`](../../modules/tenant.nix):

| Option | Default |
|---|---|
| `timeZone` | `UTC` |
| `locale` | `en_US.UTF-8` |
| `diskDevice` | `/dev/sda` |
| `network.interface` | `ens18` |
| `network.prefixLength` | `24` |
| `network.useDHCP` | `false` |
| `network.enableIPv6` | `false` |
| `network.domain` | (unset) |
| `adminUsers` | `config/users.nix` from upstream |
| `sshAuthorizedKeys` | `config/ssh-keys.nix` from upstream |

For real-world use you almost certainly want to override `adminUsers`
and `sshAuthorizedKeys` — see [`../static-network/`](../static-network).

## Verify

```bash
nix flake check .
nix eval --raw .#nixosConfigurations.demo.config.networking.hostName
nix eval --json .#nixosConfigurations.demo.config.networking.interfaces.ens18.ipv4.addresses
```

## Deploy

```bash
nix run github:nix-community/nixos-anywhere -- --flake .#demo root@<ip>
```
