# AGENTS.md

Operational guide for agents (human or AI) working on `soctalk-nixos`.
Captures the design decisions that the source files alone don't make
obvious, so you can change the code without re-deriving the
architecture from scratch.

---

## 1. What this project is

A **library flake** that produces a single-node K3s + Cilium NixOS
host, deployable via `nixos-anywhere`. Two intended consumption modes,
both supported in parallel:

1. **Library mode** — downstream flakes call
   `soctalk-nixos.lib.mkHost { hostName = "..."; tenant = { ... }; }`
   and override per-host facts via the `soctalk.tenant.*` option
   namespace. See `examples/`.
2. **In-repo reference mode** — the upstream itself defines
   `nixosConfigurations.soctalk`, which is the canonical example and
   the deployment target for the original use case (the `/wa/soc`
   Proxmox lab). Built through the same `mkHost` so the two modes
   never diverge.

The same module bundle (`nixosModules.default`) backs both modes. The
in-repo host is **not** a special path; it's a `mkHost` call like any
consumer's.

## 2. The cardinal design rule

**Per-host facts go through `soctalk.tenant.*`, never directly into
`networking.*`/`time.*`/`i18n.*`/`users.*`/`disko.*`.**

`modules/tenant.nix` is the single source of truth for the override
surface. If you find yourself reaching into raw NixOS keys from
inside a tenant or host file, you are almost certainly doing it wrong;
the correct move is to **add an option to `modules/tenant.nix`** and
update the translation block, then set the new option from the host
file.

Exceptions:
- Per-LC overrides via `i18n.extraLocaleSettings` directly (the
  `locale` option fans out the same key to all `LC_*`; module merging
  lets you stomp specific entries).
- One-off `extraModules` passed to `mkHost` for things genuinely
  out-of-scope for the tenant schema (secrets, one-off firewall rules,
  experimental kernel modules).

If you violate this rule, you break the library-flake contract:
downstream consumers can no longer get a clean override path and have
to use `mkForce` / `mkOverride` gymnastics.

## 3. Project layout (anchored to actual files)

```
flake.nix
  ├─ inputs: nixpkgs (25.11), nixpkgs-unstable, disko, nixos-anywhere
  ├─ overlay-unstable    → exposes pkgs.unstable.*
  ├─ soctalkModule       → the coarse module bundle (let-binding)
  ├─ mkHost              → the library helper (let-binding)
  ├─ outputs:
  │    nixosModules.default          = soctalkModule
  │    lib.mkHost                    = mkHost
  │    nixosConfigurations.soctalk   = mkHost { hostName = "soctalk"; tenant = import ./hosts/soctalk/tenant.nix; }
  │    apps.x86_64-linux.deploy      = wrapper around nixos-anywhere
  │    devShells.x86_64-linux.default

modules/
  base.nix              shared baseline (nix settings, openssh, base CLIs)
  tenant.nix            DECLARES soctalk.tenant.* options + TRANSLATES them
  users.nix             reads tenant.adminUsers / tenant.sshAuthorizedKeys
  k3s.nix               K3s server + declarative Cilium HelmChart + firewall
  cert-manager.nix      cert-manager HelmChart + optional ClusterIssuer + optional CA Secret loader
  oidc.nix              OAuth2-Proxy HelmChart + optional Ingress + optional cert-manager Certificate + Secret loader
  kubectl-tooling.nix   kubectl + helm + k9s + cilium-cli + hubble + cmctl + completions
  platforms/
    proxmox.nix         qemu-guest profile + virtio drivers + GRUB BIOS
    README.md           how to add a new platform

disko/
  single-disk-bios.nix  GPT + 1M EF02 BIOS-boot + 100% ext4 root

config/
  users.nix             defaults for soctalk.tenant.adminUsers
  ssh-keys.nix          defaults for soctalk.tenant.sshAuthorizedKeys

cilium/
  values.yaml           validated single-node Cilium Helm values

hosts/
  soctalk/
    tenant.nix          plain attrset of the in-repo host's tenant values

examples/
  README.md             index
  minimal/              smallest consumer flake (only required network fields)
  static-network/       full tenant override (every option set)
  dhcp/                 tenant with network.useDHCP = true

scripts/
  deploy.sh             chdir + `nix run .#deploy`

README.md               user-facing docs
AGENTS.md               you are here
```

## 4. Module composition (and why it is coarse)

`flake.nix:soctalkModule` imports **all** of:

- `disko.nixosModules.disko` (from the flake input)
- `./modules/base.nix`
- `./modules/tenant.nix`
- `./modules/users.nix`
- `./modules/k3s.nix`
- `./modules/cert-manager.nix`
- `./modules/oidc.nix`
- `./modules/kubectl-tooling.nix`
- `./modules/platforms/proxmox.nix`
- `./disko/single-disk-bios.nix`

and sets `nixpkgs.overlays = [ overlay-unstable ]`.

**Decision: coarse bundle, not à-la-carte modules.**

Rationale:
- This is a **K3s appliance flake**, not a generic NixOS base. The
  whole reason it exists is the validated K3s+Cilium config; ripping
  K3s out defeats the purpose.
- Coarse keeps the API tiny: one `nixosModules.default`, one
  `lib.mkHost`. Adding à-la-carte modules later is non-breaking;
  removing them after the fact is not.
- Consumers who genuinely need a different stack (e.g. base + their
  own k8s distribution) should **fork** rather than mix-and-match.

If you ever need à-la-carte: split into `nixosModules.{base, k3s,
proxmox, ...}` and keep `nixosModules.default` as a re-export of the
full bundle. **Do not break the existing `default` attr** — downstream
flakes pin to it.

## 5. The `mkHost` helper

```nix
mkHost =
  { hostName
  , system ? "x86_64-linux"
  , tenant ? { }
  , extraModules ? [ ]
  }:
  nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = { inherit self; };
    modules = [
      self.nixosModules.default
      ({ ... }: {
        networking.hostName = hostName;
        soctalk.tenant = tenant;
      })
    ] ++ extraModules;
  };
```

Notes:
- **`hostName` is wired via `networking.hostName`**, not via
  `specialArgs`. The old codebase passed `hostName` as a specialArg
  consumed by `hosts/soctalk/default.nix`; that file no longer
  exists. `specialArgs.self` is retained so platform / extra modules
  can reach back into the flake if needed.
- **`tenant` is a plain attrset**, not a NixOS module. The inline
  module inside `mkHost` lifts it into `soctalk.tenant = tenant;`.
  Consumers therefore write data, not modules. If you ever want to
  let consumers pass a module instead, **add a separate `extraModules`
  entry** — do not change the type of `tenant`.
- **`extraModules` is appended after the bundle.** This means
  `extraModules` definitions win over bundle defaults via normal
  module merging (without needing `mkForce`), as long as the bundle
  uses `mkDefault` for anything it expects consumers to override.
- **Do not call `mkHost` more than once per host** in the in-repo
  `nixosConfigurations` — one `mkHost` per `nixosConfigurations.<name>`
  is the only sanctioned pattern.

## 6. The `soctalk.tenant.*` option schema

Declared in `modules/tenant.nix`. Full schema:

| Path | Type | Default | Translates to |
|---|---|---|---|
| `timeZone` | str | `UTC` | `time.timeZone` |
| `locale` | str | `en_US.UTF-8` | `i18n.defaultLocale` + all 9 `LC_*` |
| `diskDevice` | str | `/dev/sda` | `disko.devices.disk.main.device` |
| `adminUsers` | listOf `{name, description}` | `config/users.nix` | `users.users.<name>` (via `modules/users.nix`) |
| `sshAuthorizedKeys` | listOf str | `config/ssh-keys.nix` | `users.users.<u>.openssh.authorizedKeys.keys` + root |
| `network.useDHCP` | bool | `false` | `interfaces.<iface>.useDHCP` |
| `network.interface` | str | `ens18` | the `<iface>` in `networking.interfaces.<iface>` |
| `network.address` | nullOr str | `null` | `interfaces.<iface>.ipv4.addresses[0].address` |
| `network.prefixLength` | int (0–32) | `24` | `interfaces.<iface>.ipv4.addresses[0].prefixLength` |
| `network.gateway` | nullOr str | `null` | `networking.defaultGateway` |
| `network.nameservers` | listOf str | `[]` | `networking.nameservers` |
| `network.domain` | nullOr str | `null` | `networking.domain` |
| `network.enableIPv6` | bool | `false` | `networking.enableIPv6` |
| `certManager.version` | str | `"v1.20.1"` | `services.k3s.manifests.cert-manager.content.spec.version` |
| `certManager.namespace` | str | `"cert-manager"` | `services.k3s.manifests.cert-manager.content.spec.targetNamespace` |
| `certManager.installCRDs` | bool | `true` | `crds.enabled` inside the HelmChart `valuesContent` |
| `certManager.clusterIssuer.enable` | bool | `false` | gates the `cluster-issuer` K3s manifest |
| `certManager.clusterIssuer.name` | str | `"default"` | ClusterIssuer `metadata.name` |
| `certManager.clusterIssuer.type` | enum (selfSigned/ca/letsencryptStaging/letsencryptProd) | `"selfSigned"` | shape of ClusterIssuer `spec` |
| `certManager.clusterIssuer.ca.secretName` | nullOr str | `null` | `spec.ca.secretName` when type=`ca` |
| `certManager.clusterIssuer.letsencrypt.email` | nullOr str | `null` | `spec.acme.email` for letsencrypt* |
| `certManager.clusterIssuer.letsencrypt.solver.type` | enum (http01) | `"http01"` | which solver array entry to render |
| `certManager.clusterIssuer.letsencrypt.solver.http01.ingressClass` | str | `"traefik"` | `spec.acme.solvers[0].http01.ingress.class` |
| `certManager.caSecret.enable` | bool | `false` | gates the `cert-manager-ca-secret.service` systemd unit |
| `certManager.caSecret.name` | str | `"ca-key-pair"` | k8s Secret name applied by the loader |
| `certManager.caSecret.certPath` | str | `"/var/lib/cert-manager/ca.crt"` | path on target read by the loader |
| `certManager.caSecret.keyPath` | str | `"/var/lib/cert-manager/ca.key"` | path on target read by the loader |
| `oidc.enable` | bool | `false` | gates the entire OIDC stack (HelmChart + Ingress + Cert + secrets loader) |
| `oidc.version` | str | `"10.4.3"` | oauth2-proxy **chart** version (bundles app `v7.15.2`). The chart version and the app version are decoupled — see https://oauth2-proxy.github.io/manifests/index.yaml |
| `oidc.namespace` | str | `"ingress-system"` | install namespace |
| `oidc.releaseName` | str | `"oauth2-proxy"` | Helm release + in-cluster Service name |
| `oidc.host` | str | derived `${hostName}.${domain}` | OAuth2-Proxy public hostname; cookie-domain default; redirect-url default |
| `oidc.redirectUrl` | nullOr str | `null` | overrides derived `https://<host>/oauth2/callback`; for localhost / split-horizon DNS |
| `oidc.issuerUrl` | nullOr str | `null` | OIDC issuer URL; required when `oidc.enable` |
| `oidc.provider` | str | `"oidc"` | OAuth2-Proxy provider (`oidc` / `google` / `keycloak-oidc` / …) |
| `oidc.upstream` | str | `"static://202"` | OAuth2-Proxy upstream (auth-url-only mode by default) |
| `oidc.cookieDomain` | str | = `oidc.host` | cookie scope |
| `oidc.extraArgs` | attrs | `{}` | additional OAuth2-Proxy CLI flags merged into rendered extraArgs |
| `oidc.secretsPath.{clientId,clientSecret,cookieSecret,secretName}` | str | `/var/lib/oauth2-proxy/...`, `oauth2-proxy-secrets` | on-target paths + k8s Secret name |
| `oidc.ingress.{enable,className,path}` | bool/str/str | `true`/`"traefik"`/`"/oauth2"` | rendered Ingress for /oauth2/* |
| `oidc.tls.enable` | bool | `false` | render cert-manager Certificate + Ingress TLS block |
| `oidc.tls.secretName` | str | `"oauth2-proxy-tls"` | Secret holding the TLS cert |
| `oidc.tls.issuerRef` | nullOr str | = `clusterIssuer.name` when enabled, else `null` | ClusterIssuer the Certificate references |

### Assertions

Inside `modules/tenant.nix`:
- `useDHCP || address != null` — static mode requires an address.
- `useDHCP || gateway != null` — static mode requires a gateway.

Inside `modules/cert-manager.nix`:
- `clusterIssuer.enable && type == "ca"` ⇒ `ca.secretName != null`.
- `clusterIssuer.enable && type ∈ {letsencryptStaging, letsencryptProd}` ⇒ `letsencrypt.email != null`.

Inside `modules/oidc.nix`:
- `oidc.enable` ⇒ `issuerUrl != null`.
- `oidc.enable` ⇒ `host != ""` (defensive — should be unreachable given the default).
- `oidc.enable && tls.enable` ⇒ `tls.issuerRef != null`.

All fire at evaluation time via `config.assertions`. **Always add an
assertion when you add an option that has cross-field validity
requirements.** The cost is zero at runtime; the alternative is
"deployed VM hangs on boot waiting for a non-existent gateway".

### Why `soctalk.tenant` and not `site` / `host` / `mySite`

Decided collectively:
- `site.*` was the original name in `hosts/soctalk/site.nix` and is
  too generic for an exported option namespace (collides easily with
  other NixOS modules a consumer might use).
- `host.*` reads weird (`host.network.address`).
- `soctalk.tenant.*` is unambiguous, project-branded, and unlikely to
  collide. The "tenant" framing also matches the library-flake mental
  model: each consumer flake = one tenant of the upstream module bundle.

**Do not rename the namespace.** Downstream consumers pin to it. If a
rename ever becomes necessary, ship both names for at least one
release with a deprecation warning via `lib.mkRenamedOptionModule`.

### Adding a new tenant option

1. Add the `lib.mkOption` declaration to `options.soctalk.tenant.*` in
   `modules/tenant.nix`. Include `type`, `default`, `example`,
   `description`.
2. Add the translation in the same file's `config` block.
3. Add an assertion if cross-field validity matters.
4. Document it in the README's option table.
5. Add an evaluation parity check (see §10) to prove the translation
   does what you expect.
6. If the default needs to live in `config/*.nix` (like `adminUsers`),
   import it at the top of `modules/tenant.nix` and use it as the
   option's `default = ...`.

### Adding a new option vs adding to `extraModules`

If the knob is:
- **Reasonable for every host** → add to `soctalk.tenant.*`.
- **One consumer's special need** → tell them to pass it via
  `extraModules`. Do not pollute the option schema with knobs that
  exist for exactly one consumer.

## 7. Locale handling

The `soctalk.tenant.locale` option sets **both** `i18n.defaultLocale`
**and** all nine `LC_*` keys in `i18n.extraLocaleSettings` to the same
value. This is the 90% case.

`modules/base.nix` **must not** set `i18n.defaultLocale` — that caused
a "conflicting definitions" error before the refactor. The tenant
module is now the only place that sets it.

For mixed locales (e.g. en_US UI with es_ES regional formats), the
consumer sets `i18n.extraLocaleSettings.LC_TIME = "es_ES.UTF-8";`
directly in an `extraModules` block; module merging overrides the
tenant-produced value for that single key.

## 8. Disk device handling

`disko/single-disk-bios.nix` sets
`disko.devices.disk.main.device = lib.mkDefault "/dev/sda"`.

`modules/tenant.nix` sets the same key (without `mkDefault`) from
`cfg.diskDevice`.

Result: the tenant value always wins, regardless of whether the
consumer set `diskDevice` or left it at the default. The
`mkDefault` in the disko file is preserved as a fallback for the
edge case where someone imports `disko/single-disk-bios.nix` standalone
(outside the `soctalk-nixos` bundle).

To support a different partitioning layout entirely (UEFI, multiple
disks, ZFS), add a new file under `disko/` and swap the import in
`flake.nix:soctalkModule`. Do not try to make `tenant.nix` describe
the partition table — that's `disko`'s job.

## 9. Users and SSH keys

`modules/users.nix` reads from `config.soctalk.tenant.adminUsers` and
`config.soctalk.tenant.sshAuthorizedKeys`, applies the keys to every
admin user **and root**, and sets `wheelNeedsPassword = false`.

The defaults come from `config/users.nix` and `config/ssh-keys.nix`,
**imported inside `modules/tenant.nix`** as the option defaults — not
inside `modules/users.nix`. This is so:
- External consumers who set `soctalk.tenant.adminUsers = [ ... ]`
  fully replace the in-repo defaults.
- The in-repo `soctalk` host gets the historical default users
  without an explicit `adminUsers = [ ... ];` line in
  `hosts/soctalk/tenant.nix`.

**Do not import `config/users.nix` or `config/ssh-keys.nix` from
anywhere other than `modules/tenant.nix`.** That guarantees the
override path through the option system always works.

The wheel passwordless setting is a deliberate trade-off documented
in `modules/users.nix`: convenient remote rebuilds at the cost of
making SSH access the only trust boundary. **Do not change this
without a corresponding tightening of `openssh` settings.**

## 10. Verification protocol

Before declaring a refactor done, run all of:

```bash
# 1. The root flake type-checks and every nixosConfiguration evaluates.
nix flake check

# 2. Tenant translation parity for the in-repo soctalk host.
for attr in \
  networking.hostName \
  networking.domain \
  networking.defaultGateway \
  networking.nameservers \
  time.timeZone \
  i18n.defaultLocale \
  networking.interfaces.ens18.ipv4.addresses \
  disko.devices.disk.main.device \
; do
  printf "%-55s %s\n" "$attr" \
    "$(nix eval --json ".#nixosConfigurations.soctalk.config.${attr}")"
done

# 3. SSH key + admin user plumbing.
nix eval --json '.#nixosConfigurations.soctalk.config.users.users.atricore.openssh.authorizedKeys.keys' | jq 'length'   # → 3
nix eval --json '.#nixosConfigurations.soctalk.config.users.users.root.openssh.authorizedKeys.keys'       | jq 'length' # → 3

# 4. cert-manager HelmChart rendered for the in-repo soctalk host.
nix eval --json '.#nixosConfigurations.soctalk.config.services.k3s.manifests.cert-manager.content.spec' \
  | jq '{chart, version, targetNamespace, createNamespace, valuesContent}'

# 5. In-repo soctalk has NO ClusterIssuer and NO caSecret unit.
nix eval --impure --expr 'let f = builtins.getFlake (toString /wa/soc/soctalk-nixos); c = f.nixosConfigurations.soctalk.config; in {
  hasClusterIssuer    = c.services.k3s.manifests ? cluster-issuer;       # → false
  hasCaSecretService  = c.systemd.services ? cert-manager-ca-secret;    # → false
}' --json | jq

# 6. cmctl is in the closure.
nix eval '.#nixosConfigurations.soctalk.config.environment.systemPackages' \
  --apply 'pkgs: builtins.length (builtins.filter (p: (p.pname or "") == "cmctl") pkgs)'   # → 1

# 7. Every example evaluates.
for d in examples/*/; do nix flake check "./${d%/}"; done

# 8. The full system closure derivation evaluates (does not build).
nix eval --raw '.#nixosConfigurations.soctalk.config.system.build.toplevel.drvPath'

# 9. SECRETS-IN-STORE INVARIANT (§15 + §16). Plant a sentinel into
#    every secret-bearing file under examples/*/secrets/ and confirm
#    it does NOT appear in any closure derivation. Failure of this
#    check is a critical regression.
MARKER="ZZZ-SECRET-MARKER-$(date +%s)"

# static-network: CA materials.
echo "$MARKER" > examples/static-network/secrets/ca.crt
echo "$MARKER" > examples/static-network/secrets/ca.key

# oidc: CA + OIDC credentials.
for f in ca.crt ca.key client-id client-secret cookie-secret; do
  echo "$MARKER" > examples/oidc/secrets/$f
done

# Re-evaluate both flakes.
nix flake check ./examples/static-network >/dev/null
nix flake check ./examples/oidc           >/dev/null

# Search both closures.
HITS=0
for top_attr in \
  './examples/static-network#nixosConfigurations.edge-01.config.system.build.toplevel.drvPath' \
  './examples/oidc#nixosConfigurations.edge-01.config.system.build.toplevel.drvPath' \
; do
  TOP=$(nix eval --raw "$top_attr")
  N=$(nix-store -qR "$TOP" | xargs grep -l "$MARKER" 2>/dev/null | wc -l)
  HITS=$(( HITS + N ))
done

if [ "$HITS" -gt 0 ]; then
  echo "REGRESSION: $HITS closure entries contain secret bytes"; exit 1
fi

# Cleanup
rm -f examples/static-network/secrets/{ca.crt,ca.key} \
      examples/oidc/secrets/{ca.crt,ca.key,client-id,client-secret,cookie-secret}
echo "secrets-in-store invariant: PASS"
```

```bash
# 10. OIDC: in-repo soctalk has no OIDC artifacts (default disabled).
nix eval --impure --json --expr 'let c = (builtins.getFlake (toString /wa/soc/soctalk-nixos)).nixosConfigurations.soctalk.config; in {
  hasHelmChart = c.services.k3s.manifests ? oauth2-proxy;
  hasIngress   = c.services.k3s.manifests ? oauth2-proxy-ingress;
  hasCert      = c.services.k3s.manifests ? oauth2-proxy-cert;
  hasService   = c.systemd.services ? oauth2-proxy-secrets;
}' | jq    # → all four: false

# 11. OIDC example renders all four pieces; host derives correctly; redirect-url is the derived default.
nix eval --json './examples/oidc#nixosConfigurations.edge-01.config.services.k3s.manifests.oauth2-proxy.content.spec.valuesContent' \
  | jq '. | fromjson | .extraArgs'   # contains "redirect-url" matching derived URL

nix eval --raw './examples/oidc#nixosConfigurations.edge-01.config.soctalk.tenant.oidc.host'
# → "edge-01.example.org"
```

If any value in (2) changes from a known-good snapshot without a
deliberate reason, you've introduced a regression.

For new options, add an entry to (2) checking the translated value.

## 11. The `apps.deploy` design

`apps.x86_64-linux.deploy` is a `pkgs.writeShellScript` wrapper around
`nixos-anywhere`. Usage: `nix run .#deploy -- <host> <ip>`. It
expects to be invoked from the project root because the inner
`--flake ".#$host"` is relative.

**It is in-repo-only.** Downstream consumers do **not** run
`nix run github:atricore/soctalk-nixos#deploy` against their own
flake — there's no way for an app defined in this flake to know about
the *consumer's* flake. Consumers call `nixos-anywhere` directly:

```bash
nix run github:nix-community/nixos-anywhere -- --flake .#myhost root@<ip>
```

If you ever want a generalized deploy app, add a second app
(`apps.deploy-external`) that takes both the consumer flake URL and
the host. **Do not break the existing `deploy` app's semantics.**

## 12. Inputs and pinning policy

- **`nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11"`** — the base
  channel. Bump only on intentional NixOS upgrades; update
  `system.stateVersion` in `modules/base.nix` at the same time.
- **`nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable"`** —
  source of `pkgs.unstable.*` via the overlay. Used **only** for
  K3s + Cilium-related CLIs (k3s, kubecolor, k9s, cilium-cli,
  hubble). Bump aggressively; the rest of the system is insulated.
- **`disko`** and **`nixos-anywhere`** both `follows = "nixpkgs"` so
  the closure stays coherent.

**Do not add a new flake input without a corresponding `follows`
relationship** unless the new input genuinely needs its own pinned
nixpkgs. Every loose input doubles the lock-file evaluation cost.

## 13. Examples

Four flakes under `examples/`:

| Dir | What it proves |
|---|---|
| `minimal/` | Defaults work: only the required `network.{address,gateway}` are set; everything else falls back. Validates the option-default path. |
| `static-network/` | Every tenant option overridable: timezone, locale, disk, users, SSH keys, full networking, plus cert-manager with a CA ClusterIssuer + caSecret loader. Validates the full override surface and the cert-manager secret-loader path. |
| `dhcp/` | The assertion-relaxation path when `useDHCP = true`. Validates that `address`/`gateway` correctly become optional. |
| `oidc/` | End-to-end auth stack: cert-manager + ClusterIssuer + OAuth2-Proxy + Ingress + TLS via cert-manager. Validates the OIDC host derivation, the `redirectUrl` override, and the cert-manager → OIDC integration through `tls.issuerRef`. |

The fourth example (`oidc/`) is justified despite §13's "don't add a
fourth" guidance because it's the **only** example that exercises
the full cert-manager + Ingress + TLS chain end-to-end, plus a
second on-target secret loader (`oauth2-proxy-secrets.service`). It
catches regressions that `static-network/` alone can't — notably,
the host-derivation logic and `tls.issuerRef` cross-module default.

Conventions:
- **Input style**: `inputs.soctalk-nixos.url = "path:../..";`. This
  makes examples evaluable from a fresh clone without a published
  reference. The README in each example documents the
  `github:atricore/soctalk-nixos` swap for real consumers.
- **`nixpkgs.follows = "soctalk-nixos/nixpkgs";`** — examples
  intentionally do **not** pin their own nixpkgs. Keeps lockfiles
  small and forces consistency with the upstream pin.
- **`flake.lock` is committed for every example.** Examples must be
  reproducible from a fresh clone; that costs ~5KB per example.
  When the root `flake.lock` is bumped, run `nix flake update` in
  each example dir to keep them in sync.

**Do not add a fourth example without a clear "this proves something
the other three don't" justification.** Example sprawl is the most
common failure mode of library flakes.

## 14. Non-obvious K3s / Cilium choices

These are written into `modules/k3s.nix` and `cilium/values.yaml`.
The README has the full prose; the AGENTS.md-relevant warnings:

- **`HelmChart.spec.bootstrap = true`** — load-bearing. Cilium is the
  cluster's CNI; without bootstrap the helm-install Job can't
  schedule on the CNI-less (NotReady) node and Cilium never gets
  installed. The Job pod's default tolerations cover only
  `not-ready:NoExecute` / `unreachable:NoExecute`, not
  `not-ready:NoSchedule` which K8s auto-applies when the node has no
  CNI. `bootstrap = true` makes K3s' helm-controller create the Job
  with `hostNetwork: true` and a blanket `Operator: Exists`
  toleration. **Symptom of regression**: every `kube-system` pod
  Pending with `0/1 nodes are available: 1 node(s) had untolerated
  taint(s)`. **Do not remove this field.** Reference:
  github.com/k3s-io/helm-controller — chart.go,
  `if chart.Spec.Bootstrap` branch.
- **cert-manager is NOT a bootstrap HelmChart** — it installs after
  the CNI is up, after the node is Ready, just like any normal
  workload. The HelmChart in `modules/cert-manager.nix` deliberately
  omits `bootstrap = true`. **Do not add it** — it would force
  cert-manager onto the host network and break the standard
  webhook / API path.
- **`routingMode: native`** — `tunnel` (VXLAN) failed silently on
  single-node, with no drop counters anywhere. Native fixed it.
  **Do not flip back to tunnel** without re-validating end-to-end
  pod-to-pod traffic.
- **`bpf.masquerade: false`** + **`enableIPv4Masquerade: true`** —
  iptables masquerade is reliable; BPF masquerade is flaky on
  NixOS+iptables-nft today. **Do not enable BPF masquerade** without
  reproducing the failure first.
- **`endpointRoutes.enabled: true`** — installs per-pod /32 routes,
  needed for strict RPF setups. The host firewall in `k3s.nix` uses
  `checkReversePath = "loose"` as belt-and-suspenders.
- **`checkReversePath = "loose"`** in `k3s.nix` — pod traffic enters
  via `lxc*` veths but the route to the pod CIDR is via
  `cilium_host`; strict RPF drops it. **Do not tighten without
  testing kube-system and any future workload traffic.**
- **K3s flags**: `--flannel-backend=none --disable-network-policy
  --disable-kube-proxy --disable=traefik` — Cilium handles all four
  responsibilities. **Do not re-enable any of these** without first
  disabling the matching Cilium feature.

## 15. cert-manager design

`modules/cert-manager.nix` is the cert-manager equivalent of
`modules/k3s.nix`: it bakes cert-manager into the appliance and
exposes a tenant-configurable surface for the two pieces consumers
actually care about — the ClusterIssuer and how the CA Secret gets
into the cluster.

### Always installed; never `enable`-able

Per §4, the bundle is coarse. cert-manager has no `enable` toggle;
it ships with every deploy. Only its **configuration** is tunable.

### `clusterIssuer` is a tagged union, opt-in

`soctalk.tenant.certManager.clusterIssuer.enable = false` by default.
When `true`, exactly one of four ClusterIssuer kinds is produced
based on `type`:

| `type` | Out-of-the-box | External dependency |
|---|---|---|
| `selfSigned` | ✅ | none |
| `ca` | ✅ if `caSecret.*` is also enabled | the CA tls Secret must exist in the namespace |
| `letsencryptStaging` | ❌ | needs an ingress controller matching `letsencrypt.solver.http01.ingressClass` |
| `letsencryptProd` | ❌ | same |

The bundle does **not** ship an ingress controller. AGENTS.md §19
says secrets backends are out of scope; the same logic applies here
— ingress controllers are downstream concerns. If a
consumer needs ACME http01, they install Traefik v3 or ingress-nginx
themselves and set `ingressClass` accordingly. See `README.md` for
the install snippets.

### `caSecret`: load a Secret from on-target files, NEVER from Nix

`soctalk.tenant.certManager.caSecret.enable = true` declares a
systemd one-shot (`cert-manager-ca-secret.service`) that:

1. Waits for the K3s API server (`/readyz`) and the cert-manager
   namespace.
2. Reads the CA cert + key from `caSecret.certPath` and
   `caSecret.keyPath` on the **target machine's** filesystem.
3. Pipes `kubectl create secret tls --dry-run=client -o yaml` into
   `kubectl apply -f -` so the bytes never touch disk outside their
   on-target paths.

**Critical invariant:** the cert / key bytes never enter the Nix
store. The module declares only **paths** (strings). It does not
call `builtins.readFile` on anything in the consumer's `secrets/`
directory. This is what makes "encrypted-at-rest in the consumer
repo, decrypted at boot via agenix/sops-nix" work: the consumer
points `certPath` / `keyPath` at the decrypted runtime paths and
the same loader keeps working without changes.

**The verification protocol §10 step 9 plants a sentinel into
`examples/static-network/secrets/ca.{crt,key}` and asserts the
sentinel does not appear in the closure.** Run it whenever you
touch `modules/cert-manager.nix` or the static-network example —
failure of that check is a critical regression and an immediate
"do not ship" gate.

### How CA files actually reach the target

Three paths, in increasing production-readiness:

| Mechanism | Use case |
|---|---|
| `nixos-anywhere --extra-files <dir>` | fresh, destructive deploy; consumer stages an `extra-files/var/lib/cert-manager/ca.*` tree |
| `scp` + `nixos-rebuild switch` | incremental update; `systemctl restart cert-manager-ca-secret.service` after |
| `agenix` / `sops-nix` | production; encrypted-at-rest in repo, decrypted at boot to a tmpfs path; point `certPath`/`keyPath` at that path |

The bundle has no opinion on which one — it just expects the files
to exist when the systemd unit runs. AGENTS.md §19 is explicit:
**we provide a Secret loader, not a secrets backend.**

### Manifest-apply ordering

K3s' addon-applier runs on a loop and retries failed manifests. When
the bundle installs cert-manager + a ClusterIssuer simultaneously,
the ClusterIssuer's first apply pass typically fails because the
CRDs haven't been established yet. Subsequent passes succeed
(usually within ~30s). **Expect a transient flurry of
`failed to apply ClusterIssuer …: no matches for kind` log lines on
fresh deploys.** Not a regression — it self-heals.

### Idempotent re-runs

`cert-manager-ca-secret.service` is `Type=oneshot,
RemainAfterExit=yes` and `Restart=on-failure`. The `kubectl apply`
is idempotent, so rebooting (or `systemctl restart`-ing the unit)
after rotating `ca.{crt,key}` propagates the update. There's no
`path` watcher; rotations require an explicit restart.

### Default paths and naming

- `caSecret.certPath = "/var/lib/cert-manager/ca.crt"` — under
  `/var/lib/` because that's the FHS-blessed location for variable
  state files owned by services. `tmpfiles` enforces `0444 root root`.
- `caSecret.keyPath = "/var/lib/cert-manager/ca.key"` — same dir;
  `tmpfiles` enforces `0400 root root`.
- `caSecret.name = "ca-key-pair"` — matches the cert-manager
  convention used in the project's docs.

Consumers using agenix/sops-nix override `certPath` / `keyPath` to
their runtime decryption paths (e.g., `/run/agenix/...`).

## 16. OIDC / OAuth2-Proxy design

`modules/oidc.nix` is the third "appliance plug-in", after
`modules/k3s.nix` and `modules/cert-manager.nix`. Unlike those two,
the OIDC stack is **opt-in** (`soctalk.tenant.oidc.enable = false`
by default) because OAuth2-Proxy refuses to start without
credentials.

### What `enable = true` produces

| Manifest / unit | Always present when enable=true | Notes |
|---|---|---|
| `oauth2-proxy` HelmChart | yes | Non-bootstrap. Standard K3s `services.k3s.manifests.<name>.content` |
| `oauth2-proxy-ingress` | gated on `oidc.ingress.enable` (default true) | Renders the `/oauth2/*` Ingress for the consumer's installed ingress controller to pick up |
| `oauth2-proxy-cert` | gated on `oidc.tls.enable` (default false) | cert-manager `Certificate` that mints the Ingress's TLS Secret |
| `oauth2-proxy-secrets.service` | yes | systemd one-shot that loads client-id / client-secret / cookie-secret from on-target files into a kubernetes Secret; same shape as `cert-manager-ca-secret.service` |
| `systemd.tmpfiles` 0400 rules | yes | enforces strict perms on the three credential paths |

### Host derivation

`oidc.host` defaults to:

```text
if networking.domain is set: "${networking.hostName}.${networking.domain}"
else:                        networking.hostName
```

Always overridable as a plain option. The derived host is used as:

- `Ingress.spec.rules[0].host`
- `Certificate.spec.dnsNames[0]`
- the default `cookieDomain`
- the default `redirectUrl` (`https://<host>/oauth2/callback`)

`oidc.redirectUrl` is an explicit nullable string. When set, it wins
verbatim over the derived default. Use it for:

- **localhost / port-forward testing**: `redirectUrl = "http://localhost:4180/oauth2/callback"`
- **split-horizon DNS**: the IdP sees a different public hostname than the in-cluster Ingress host.
- **reverse-proxy chains** that rewrite the Host header.

### Credentials loader

Three files on the target machine, one Kubernetes Secret. The chart's `config.existingSecret` is wired automatically to `secretsPath.secretName` (default `oauth2-proxy-secrets`). Key names inside the Secret match the chart's expectations: `client-id`, `client-secret`, `cookie-secret`.

**Critical invariant (shared with §15):** the bytes never enter the
`/nix/store`. The module declares only file *paths*. The loader
reads files at boot, pipes through `kubectl create --dry-run=client
-o yaml | kubectl apply -f -`, and never writes the rendered
manifest to disk.

**The verification protocol §10 step 9 covers BOTH `examples/static-network/secrets/` AND `examples/oidc/secrets/`.** Run it after touching either module.

### TLS via cert-manager

`tls.enable = false` by default — first-time consumers can flip on
OIDC without standing up a working ClusterIssuer first. Production
deploys should set `tls.enable = true`; most OIDC providers reject
http redirect URLs.

When `tls.enable = true`:

- A `Certificate` is rendered referencing `tls.issuerRef`.
- The Ingress gets a `spec.tls[]` block referencing `tls.secretName`.

`tls.issuerRef` has a smart default: if
`certManager.clusterIssuer.enable` is `true`, the default is
`certManager.clusterIssuer.name`. So enabling both is the
single-line "and now TLS" toggle:

```nix
certManager.clusterIssuer = { enable = true; type = "ca"; ca.secretName = "ca-key-pair"; };
oidc.tls.enable = true;   # issuerRef auto-derives
```

### Ingress controller dependency

Same as cert-manager's letsencrypt path: the bundle does **not**
ship an ingress controller. Consumer installs Traefik v3 or
ingress-nginx and aligns `oidc.ingress.className`. With the
controller missing, the `oauth2-proxy-ingress` manifest applies but
gets no traffic.

Default `ingress.className = "traefik"`. **Note** this differs from
some consumers' default of `nginx` — consumers using ingress-nginx
need to flip the option explicitly. (Set the cert-manager
`letsencrypt.solver.http01.ingressClass` to the same class to keep
the two aligned.)

### Provider value

`oidc.provider` defaults to the generic `"oidc"` value, which works
with any OIDC-compliant IdP (Keycloak, Authentik, Dex, Auth0,
Okta, …). Override for IdPs OAuth2-Proxy supports natively
(`google`, `github`, `gitlab`, …). The corresponding OAuth2-Proxy
flags they need (e.g., `--google-group`, `--github-org`) go through
`oidc.extraArgs` — that attrset is merged after our rendered defaults
so consumer keys win.

### Protecting apps with auth-url annotations

The bundle does NOT touch consumer apps' Ingresses — protection is
the app's responsibility. README.md and `examples/oidc/README.md`
document both:

- **ingress-nginx**: `nginx.ingress.kubernetes.io/auth-url`, `auth-signin`, `auth-response-headers`.
- **Traefik v3**: a `Middleware` of type `forwardAuth` referencing `http://oauth2-proxy.ingress-system.svc.cluster.local:80/oauth2/auth`.

### When to refactor the Secret-loader pattern

`cert-manager-ca-secret.service` and `oauth2-proxy-secrets.service`
are structural duplicates: same wait loop, same `kubectl ... --dry-run | kubectl apply -f -` shape, same tmpfiles perms enforcement. If a **third** loader appears (e.g., a generic database password loader),
**factor out a common `lib/secret-from-files` helper** rather than
copy-paste a third time. Until then, keeping them separate avoids
premature abstraction.

## 17. When to bump nixpkgs-unstable

The overlay isolates `pkgs.unstable` from the rest of the system, so
bumping it should only affect K3s + Cilium tooling. Bump when:
- A new K3s minor is needed (track `pkgs.unstable.k3s` version).
- `cilium-cli` / `hubble` lag the cluster's Cilium version.
- `k9s` / `kubecolor` have a needed fix.

After bumping, re-run the verification protocol (§10) and additionally
build the toplevel for real (not just eval) to catch package-build
regressions:

```bash
nix build .#nixosConfigurations.soctalk.config.system.build.toplevel
```

## 18. When to bump Cilium

Change two things together:
1. `cilium/values.yaml` — review release notes for value renames.
2. `modules/k3s.nix:services.k3s.manifests.cilium.content.spec.version` —
   the Helm chart version.

After bumping:
- Verify on a throwaway VM with `./scripts/deploy.sh soctalk <ip>`.
- Confirm `kubectl get nodes` is `Ready`.
- Confirm `kubectl -n kube-system get pods` are all `Running`.
- Confirm a test pod can reach `kubernetes.default.svc` and the
  outside internet.

## 19. Common pitfalls

| Pitfall | What happens | Avoid by |
|---|---|---|
| Removing / forgetting `spec.bootstrap = true` on the Cilium `HelmChart` | Every kube-system pod stuck Pending with "untolerated taint(s)" — Cilium never installs because its helm-install Job can't schedule on a NotReady (CNI-less) node | Keep `bootstrap = true` (see §14) |
| Adding `spec.bootstrap = true` to the cert-manager `HelmChart` | cert-manager runs with `hostNetwork: true`, breaks the webhook / API path | Leave it omitted (see §14) |
| Calling `builtins.readFile ./secrets/...` from a consumer flake | CA bytes get embedded into `/nix/store` → world-readable | Use `caSecret.{certPath, keyPath}` (paths only), stage files on the target via `--extra-files` / scp / agenix / sops-nix (see §15) |
| Using `letsencrypt*` ClusterIssuer without installing an ingress controller | Certificates never issue; http01 solvers stuck pending forever | Install Traefik v3 or ingress-nginx first, and align `letsencrypt.solver.http01.ingressClass` |
| Default `letsencrypt.solver.http01.ingressClass = "traefik"` mismatched with an installed `nginx` controller | ACME solver Ingress is ignored | Set the option to the actually-installed class name |
| Enabling `oidc.tls.enable` without `clusterIssuer.enable` and without setting `tls.issuerRef` | Eval-time assertion fires (see §16) | Either enable `certManager.clusterIssuer` or set `oidc.tls.issuerRef` explicitly |
| Setting `oidc.version` to the OAuth2-Proxy **app** version (e.g. `7.15.2`) instead of the **chart** version (e.g. `10.4.3`) | `helm-install-oauth2-proxy-*` Job CrashLoopBackOff with `Error: INSTALLATION FAILED: chart "oauth2-proxy" matching 7.15.2 not found in oauth2-proxy index` | Always use a chart version from https://oauth2-proxy.github.io/manifests/index.yaml; pick one whose `appVersion` matches the OAuth2-Proxy release you want. The two have separate version trains. |
| Enabling `oidc.enable` without staging `/var/lib/oauth2-proxy/{client-id,client-secret,cookie-secret}` | `oauth2-proxy-secrets.service` fails with "required file missing or empty"; OAuth2-Proxy CrashLoopBackOff (chart can't reference the Secret) | Stage all three files via `--extra-files` / scp / agenix / sops-nix before deploy |
| Default `oidc.ingress.className = "traefik"` mismatched with an installed `nginx` controller | `/oauth2/*` requests 404 — no controller picks up the Ingress | Set `oidc.ingress.className = "nginx"` (and consider aligning `letsencrypt.solver.http01.ingressClass` too) |
| `oidc.host` mismatched with the IdP's registered redirect URI | OIDC callback fails after login with "invalid redirect_uri" | Either fix `oidc.host` / `oidc.redirectUrl` to match what's registered, or update the IdP client's authorized redirect URIs |
| Setting `i18n.defaultLocale` in `modules/base.nix` | "conflicting definitions" with `modules/tenant.nix` | Only `modules/tenant.nix` sets it |
| Importing `config/{users,ssh-keys}.nix` outside `modules/tenant.nix` | Consumer overrides via tenant don't take effect | Only `modules/tenant.nix` imports them |
| Adding a per-host fact directly to `hosts/<name>/tenant.nix` outside the schema | Doesn't translate to any NixOS option | Add the option to `modules/tenant.nix` first |
| Adding `mkForce`/`mkOverride` inside the tenant module | Locks consumers out of the override path | Use plain assignments; let module merging do its job |
| Removing `mkDefault` from `disko/single-disk-bios.nix` | Standalone use of the file breaks | Keep `mkDefault`; tenant's plain assignment still wins |
| Passing `tenant` as a module instead of an attrset to `mkHost` | Type error or silent wrong-shape | Tenant is data; use `extraModules` for modules |
| Forgetting to `git add` before `nix flake check` | Stale evaluation against committed tree | Always `git add -A` before checking |
| Not bumping example lockfiles after a root bump | Examples drift from upstream | Run `nix flake update` in each example dir after a root bump |

## 20. What is intentionally NOT in scope

- **Multi-platform in one flake.** The bundle hard-imports
  `modules/platforms/proxmox.nix`. To target EC2 or Hetzner, fork or
  override that import via `extraModules` + `mkForce`. A future
  iteration could split per-platform; today, it's one flake = one
  platform.
- **High availability / multi-node K3s.** The Cilium values are tuned
  for single-node (`routingMode: native`, no kube-proxy, etc.).
  Multi-node would need a different Cilium config and likely an
  external etcd or sqlite-replacement.
- **Secrets backend.** No agenix, no sops-nix. Consumers add
  their own via `extraModules`. Hard-coding a secrets backend in the
  bundle would force every consumer onto it. **What the bundle DOES
  provide** (see §15) is `certManager.caSecret.*` — a *Secret loader*
  that consumes file paths on the target, plus systemd-tmpfiles rules
  that enforce strict perms on those paths. The consumer picks how
  the files arrive (manual scp, `--extra-files`, agenix-decrypted
  tmpfs, sops-nix-decrypted tmpfs, …) — the loader is mechanism-agnostic.
- **Container registry credentials, image building, CI** — out of
  scope; consumers wire their own.

If a request lands that looks like one of the above, push back: it
probably belongs in a downstream consumer flake, not in this
upstream.

## 21. Provenance

Lifted from `/wa/nix/mynix/hosts/soctalk/` after that cluster's
configuration was validated end-to-end. The non-obvious choices in
§14 are the result of that validation work; **do not undo them without
re-validating against a real cluster**.
