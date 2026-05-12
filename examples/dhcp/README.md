# dhcp

A consumer flake that disables static IP and uses DHCP on the primary
interface.

## What gets configured

| Option | Value |
|---|---|
| `network.useDHCP` | `true` |
| `network.interface` | `ens18` |
| `timeZone` | `America/New_York` |

`address`, `gateway`, `prefixLength` are left at their defaults
(`null`, `null`, `24`) — the tenant-level assertions only require
those when `useDHCP` is false.

## Verify

```bash
nix flake check .

# Confirm DHCP is on and no static address is configured:
nix eval --json .#nixosConfigurations.dhcp-demo.config.networking.interfaces.ens18
nix eval --json .#nixosConfigurations.dhcp-demo.config.networking.defaultGateway
```

## When to use this

- VMs in a lab where you don't know the IP up front.
- Cloud instances where the provider injects the lease via cloud-init.
- Quick smoke tests where deterministic addressing isn't required.

For production hosts you almost certainly want a static address — see
[`../static-network/`](../static-network).
