# NixOS example

A minimal NixOS VM with development tools, managed by migrant.sh.

Unlike the arch and claude examples, NixOS does not publish pre-built cloud
images. The qcow2 is built locally from `flake.nix` instead.

## Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled
- migrant.sh host setup complete (`migrant.sh setup`)

## Usage

Build the image (first time only, or after changing `flake.nix`):

    cd nixos
    nix build

Update the SSH key in `cloud-init.yml` to match your managed key:

    migrant.sh pubkey

Copy the output into the `ssh_authorized_keys` field in `cloud-init.yml`.

Start the VM:

    migrant.sh up

Connect:

    migrant.sh ssh

## What's in the image

Defined in `flake.nix` (NixOS 25.11):

- cloud-init (NoCloud datasource)
- OpenSSH
- Serial console on ttyS0
- virtiofs kernel support
- git, gcc, gnumake, binutils, pkg-config
- Nix flakes enabled

## What cloud-init configures

Defined in `cloud-init.yml` (per-instance, applied at first boot):

- User `migrant` with passwordless sudo
- Managed SSH key
- Shared folder mounted at `/home/migrant/workspace` via virtiofs

## Differences from the arch example

NixOS is declarative, which changes how provisioning works:

- **No `playbook.yml`** — packages and system configuration are baked into the
  image via `flake.nix`, not installed after boot by Ansible.
- **Shell path** — NixOS does not have `/bin/bash`; the cloud-init user shell
  is set to `/run/current-system/sw/bin/bash`.
- **fstab is read-only** — NixOS generates `/etc/fstab` from its configuration,
  so the virtiofs mount uses an explicit `mount -t virtiofs` command in
  cloud-init `runcmd` rather than appending to fstab.

## Rebuilding the image

If you change `flake.nix`, rebuild and recreate the VM:

    nix build
    migrant.sh destroy
    migrant.sh up

Changes to `cloud-init.yml` also require a destroy/up cycle since
cloud-init only runs on first boot.
