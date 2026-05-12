# Disk layout: single disk, GPT with a 1M BIOS-boot partition for GRUB
# stage-1.5, plus a 100%-fill ext4 root. BIOS-bootable on seabios VMs;
# no separate /boot partition.
#
# Override `disko.devices.disk.main.device` in your host's disko.nix
# if the disk isn't /dev/sda.
{ lib, ... }: {
  disko.devices = {
    disk.main = {
      type = "disk";
      device = lib.mkDefault "/dev/sda";
      content = {
        type = "gpt";
        partitions = {
          # 1M BIOS-boot partition. Required for GRUB to install on a GPT
          # disk while still booting via legacy seabios. Type EF02 is the
          # GPT "BIOS boot" partition type.
          boot = {
            size = "1M";
            type = "EF02";
            priority = 1;
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
