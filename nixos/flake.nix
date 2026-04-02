{
  description = "NixOS qcow2 cloud image for migrant.sh";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      # NixOS system configuration for the cloud image
      nixosConfig = lib.nixosSystem {
        inherit system;
        modules = [
          # QEMU/KVM guest profile — loads virtio drivers and guest agent
          "${nixpkgs}/nixos/modules/profiles/qemu-guest.nix"

          ({ config, pkgs, modulesPath, ... }: {

            # --- Disk image builder ---
            # Use nixpkgs' make-disk-image to produce a qcow2.
            # The image is built as part of system.build so we can
            # reference it from the flake output.
            system.build.qcow2 = import "${modulesPath}/../lib/make-disk-image.nix" {
              inherit lib config pkgs;
              baseName = "nixos-base";    # avoid collision with migrant.sh's {VM_NAME}.qcow2
              diskSize = "auto";          # shrink to fit; growpart expands at boot
              format = "qcow2";
              partitionTableType = "legacy";  # MBR — no EFI partition needed
            };

            # --- Boot ---
            # GRUB in MBR mode — standard for qcow2 cloud images without UEFI.
            boot.loader.grub.enable = true;
            boot.loader.grub.device = "/dev/vda";

            # Grow the root partition to fill DISK_GB at first boot.
            # Works with cloud-init's growpart module or systemd-growfs.
            boot.growPartition = true;

            # Root filesystem — single ext4 partition
            fileSystems."/" = {
              device = "/dev/vda1";
              fsType = "ext4";
              autoResize = true;
            };

            # --- Serial console ---
            # migrant.sh console connects via serial (ttyS0)
            boot.kernelParams = [ "console=ttyS0,115200n8" ];
            systemd.services."serial-getty@ttyS0".enable = true;

            # --- virtiofs ---
            # Kernel module for host-guest shared folders.
            # The actual mount is done by cloud-init runcmd (explicit
            # mount -t virtiofs) because the mount point lives under
            # /home/migrant which doesn't exist until cloud-init creates
            # the user.
            boot.initrd.availableKernelModules = [ "virtiofs" ];

            # --- cloud-init ---
            # migrant.sh creates a NoCloud seed ISO with user-data and
            # attaches it as a CD-ROM at boot.
            services.cloud-init.enable = true;

            # --- OpenSSH ---
            # Required for `migrant.sh ssh`
            services.openssh = {
              enable = true;
              settings = {
                PermitRootLogin = "prohibit-password";
                PasswordAuthentication = true;
              };
            };

            # --- Nix flakes ---
            nix.settings.experimental-features = [ "nix-command" "flakes" ];

            # --- Development packages ---
            # Equivalent to Arch's base-devel group
            environment.systemPackages = with pkgs; [
              git
              gcc
              gnumake
              binutils
              pkg-config
            ];

            # Allow passwordless sudo for wheel group members
            # (cloud-init.yml grants NOPASSWD sudo to the user)
            security.sudo.wheelNeedsPassword = false;

            networking.hostName = "nixos";

            # Must match the nixpkgs channel
            system.stateVersion = "25.11";
          })
        ];
      };

    in {
      # Build with: nix build
      packages.${system} = let
        image = nixosConfig.config.system.build.qcow2;
      in {
        nixos-image = image;
        default = image;
      };
    };
}
