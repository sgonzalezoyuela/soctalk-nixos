# Platform modules

Each `.nix` file in this directory captures the hardware/bootloader
profile for a specific cloud or hypervisor. Exactly one is imported
by the coarse `nixosModules.default` bundle in `flake.nix`.

## Existing

- `proxmox.nix` — Proxmox VE BIOS VMs (seabios + virtio-scsi disk +
  virtio-net NIC + GRUB MBR on `/dev/sda`).

## Adding a new platform

1. Create a new `<cloud>.nix` here. Typical contents:

   ```nix
   { modulesPath, ... }: {
     imports = [
       # nixos-anywhere or nixpkgs ships profile modules for common clouds:
       #   /virtualisation/amazon-image.nix
       #   /virtualisation/google-compute-image.nix
       #   /virtualisation/hetzner-cloud-image.nix
       (modulesPath + "/virtualisation/<cloud>-image.nix")
     ];

     boot.initrd.availableKernelModules = [
       # cloud-specific virt drivers (nvme, xen, etc.)
     ];

     boot.loader.grub = {
       enable = true;
       efiSupport = false;     # or true, depending
       device = "/dev/nvme0n1"; # whatever the cloud presents
     };

     nixpkgs.hostPlatform = "x86_64-linux";  # or aarch64
   }
   ```

2. Swap the platform import inside `flake.nix`'s `soctalkModule`:

   ```nix
   soctalkModule = { ... }: {
     imports = [
       disko.nixosModules.disko
       ./modules/base.nix
       ./modules/tenant.nix
       ./modules/users.nix
       ./modules/k3s.nix
       ./modules/kubectl-tooling.nix
       ./modules/platforms/<cloud>.nix       # ← changed
       ./disko/single-disk-bios.nix
     ];
     nixpkgs.overlays = [ overlay-unstable ];
   };
   ```

3. Pick the disk device via `soctalk.tenant.diskDevice` in your host's
   `tenant.nix` (or per-consumer-flake), often `/dev/nvme0n1` on EC2
   or `/dev/vda` on Hetzner.

   For a partition *layout* change (UEFI clouds want an ESP partition),
   add a new file under `disko/` and swap the import in `flake.nix`
   the same way as the platform swap above.

## Mixing platforms in one flake

The coarse `nixosModules.default` bakes in one platform. If you need a
flake that targets multiple platforms (e.g. proxmox + AWS), the
cleanest path right now is to fork and split `nixosModules` per
platform. A future iteration could expose à-la-carte modules for this.

## Notes on bootloaders by platform

| Platform | Boot mode | GRUB device | Notes |
|---|---|---|---|
| Proxmox seabios | BIOS | `/dev/sda` | This project's default |
| Proxmox OVMF | UEFI | n/a, use systemd-boot | Switch to `boot.loader.systemd-boot.enable = true` |
| AWS EC2 (x86_64) | BIOS or UEFI | `/dev/xvda` or `/dev/nvme0n1` | depends on instance type |
| Hetzner Cloud | BIOS | `/dev/sda` | similar to Proxmox |
| Google Compute | BIOS | `/dev/sda` | use google-compute-image profile |
