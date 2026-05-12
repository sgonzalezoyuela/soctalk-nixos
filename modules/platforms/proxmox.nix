# Proxmox VE platform module.
#
# Assumes a BIOS-boot (seabios) VM with virtio-scsi storage, virtio-net
# NIC, and the qemu guest agent enabled. See README.md for VM creation
# steps and modules/platforms/README.md for how to add other platforms.
{ modulesPath, ... }: {
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  # Standard virtio + legacy PC bus drivers for broad VM compatibility.
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];

  # BIOS boot via GRUB. disko provisions a 1M EF02 (BIOS-boot) partition
  # on the disk for GRUB's stage-1.5 to live in AND automatically adds
  # the disk to boot.loader.grub.devices, so we only need to enable GRUB
  # here. Setting boot.loader.grub.device manually triggers a
  # "duplicated devices in mirroredBoots" assertion.
  boot.loader.grub.enable = true;

  nixpkgs.hostPlatform = "x86_64-linux";
}
