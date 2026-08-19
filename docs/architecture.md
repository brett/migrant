# Architecture

## How it works

Each project directory contains these files:

- **`Migrantfile`** — a sourced bash file declaring VM name, resources, image,
  and shared folders
- **`cloud-init.yml`** — a standard
  [cloud-init](https://cloudinit.readthedocs.io/) user-data file that handles
  first-boot system setup: creating users, configuring SSH keys, and mounting
  shared folders
- **`playbook.yml`** (optional) — an [Ansible](https://docs.ansible.com/)
  playbook for ongoing configuration management: installing packages, deploying
  dotfiles, and anything that may change over the VM's lifetime

The `migrant` script lives in your `PATH` and reads these files from the current
directory by default, just like `vagrant` reads a `Vagrantfile`. Alternatively,
set the `MIGRANT_DIR` environment variable to point at the project directory and
run `migrant` from anywhere (see [MIGRANT_DIR](usage.md#migrant_dir)).

On first `migrant up`, the script:

1. Downloads the base cloud image (once, cached in `/var/lib/libvirt/images/` —
   or `LIBVIRT_IMAGES_DIR` if set; `file://` image URLs are always re-copied
   instead of cached, since the source may have been rebuilt, as with a
   locally-built NixOS image)
2. Creates a qcow2 disk using the base image as a backing file (copy-on-write —
   fast, no full copy)
3. Packages your `cloud-init.yml` into a seed ISO, substituting the
   `__MIGRANT_PUBKEY__` placeholder (if present) with the managed key's public
   half — see [Managed SSH key](usage.md#managed-ssh-key-recommended)
4. Calls `virt-install` to define and start the VM
5. cloud-init runs inside the VM on first boot to create users, configure SSH
   keys, and mount shared folders
6. If `playbook.yml` is present, waits for SSH to become available, waits for
   cloud-init to finish, then runs `ansible-playbook` to complete provisioning;
   `up` blocks until done and the VM is fully ready when it returns

On subsequent `migrant up` calls, the VM already exists so the script starts it
with `virsh start`, then waits for SSH if configured. A paused domain is resumed
with `virsh resume` instead: it is already active, with its taps, firewall
rules, and mounts in place and its `pre-up`/`post-up` hooks long since fired, so
it needs unfreezing rather than starting. `up` also compares the domain's
defined memory and vCPU count against `RAM_MB` and `VCPUS` and warns on a
mismatch, as does `migrant status`; neither edits an existing domain's
definition. Both read the comparison out of one `virsh dumpxml --inactive`. See
[resize.md](resize.md#changing-ram-and-vcpus).

`up` also compares each `SHARED_FOLDERS` entry's current host path against the
directory `virt-install` baked into the domain's `<filesystem>` element at
create time — a mismatch means the VM directory moved (e.g. `mv`) since it was
built. Unlike the RAM/vCPU check, this is not a warn-and-proceed: it refuses to
start with exit 78, since continuing would either fail in `virtiofsd` or mount
whatever now happens to sit at the stale path. See
[shared-folder-isolation.md](security/shared-folder-isolation.md).

Destroying the VM with `migrant destroy` removes the libvirt domain and deletes
the VM's disk, seed ISO, and any snapshot, leaving the cached base image intact
so the next `migrant up` is fast.

## Disk images and caching

All VM-related files are stored in `/var/lib/libvirt/images/`, or
`LIBVIRT_IMAGES_DIR` if set (e.g. `migrant setup` uses it to pick where the
images directory is created):

| File       | Example                                  | Purpose                                              |
| ---------- | ---------------------------------------- | ---------------------------------------------------- |
| Base image | `ubuntu-25.10-server-cloudimg-amd64.img` | Shared read-only backing file; downloaded once       |
| VM disk    | `claude.qcow2`                           | Per-VM qcow2 overlay (copy-on-write over base image) |
| Seed ISO   | `claude-seed.iso`                        | cloud-init data for first-boot provisioning          |
| Snapshot   | `claude-snapshot.qcow2`                  | Flattened disk image saved by `migrant snapshot`     |

The qcow2 overlay means:

- Creating a VM is fast — only changed blocks are written to the VM's own disk
- The base image is never modified
- Multiple VMs can share the same base image simultaneously
- `migrant destroy` deletes the VM's disk, seed ISO, and snapshot; the base
  image remains
- `migrant reset` also deletes the disk and seed ISO but preserves the snapshot,
  then calls `up` to rebuild from it

To free the base image:

```bash
rm /var/lib/libvirt/images/ubuntu-25.10-server-cloudimg-amd64.img
```

It will be re-downloaded next time a VM using that image is created.

## Firmware (BIOS vs UEFI)

By default, VMs use BIOS firmware (SeaBIOS). Setting `BOOT_FIRMWARE=uefi` in a
Migrantfile switches to UEFI (OVMF):

```bash
BOOT_FIRMWARE=uefi
```

**When to use this:** the Debian generic cloud image requires UEFI. Its BIOS
GRUB uses a VBE framebuffer; `--graphics none` removes the VGA device entirely,
so the kernel hangs on framebuffer initialisation before any serial output
appears. UEFI avoids this by using EFI GOP instead of VBE and falling back
gracefully to serial-only when no display is present.

Ubuntu's BIOS GRUB handles a missing VGA device correctly and does not need this
setting. Arch does not need it either — its `archlinux` osinfo-db entry already
enables UEFI automatically.
