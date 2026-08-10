# Resizing the disk

`migrant resize` grows a VM's disk to match `DISK_GB` in the `Migrantfile`. Edit
the value, then run it against the running VM:

```console
$ migrant resize
Growing 'arch-claude' disk to 40G...
Growing the in-guest partition and filesystem...
...growpart, filesystem-grow, and df output from the guest...
Disk resized to 40G.
```

The VM stays up throughout. There is no reboot, and no `pre-up`/`post-up` or
`pre-down`/`post-down` hook fires — resize is not a state transition, and the VM
is running before and after (see [hooks.md](hooks.md)).

## What it does

Two steps, in order:

1. **Grows the block device on the host** with `virsh blockresize`. virtio
   surfaces the new capacity to the running guest immediately.
2. **Grows the partition and filesystem in the guest** over SSH: `growpart` on
   the root partition, then `btrfs filesystem resize`, `xfs_growfs`, or
   `resize2fs` depending on what the root filesystem actually is.

The second step is why resize needs SSH and a running VM rather than doing
everything from the host. The example playbooks disable cloud-init after first
boot (`/etc/cloud/cloud-init.disabled`), so cloud-init's `growpart` module can't
extend the partition on a later reboot — nothing in the guest will do it for
you.

The in-guest script reads the root device, partition number, and filesystem type
from the live system, so it doesn't assume a disk layout or an ext-family
filesystem. A root filesystem it doesn't recognize is reported as an error and
left alone for you to grow by hand.

## Requirements

- **The VM must be running.** `migrant up` first.
- **SSH must be configured.** `cloud-init.yml` needs `ssh_authorized_keys`;
  resize has no console fallback.
- **`growpart` must be installed in the guest.** It ships in the
  `cloud-guest-utils` package (`pacman -S cloud-guest-utils` on Arch,
  `apt install cloud-guest-utils` on Debian/Ubuntu). No example `playbook.yml`
  installs it, so whether it's present depends on the base cloud image. Resize
  reports its absence with the same install hint rather than failing silently.

## Growing only

Resize refuses to shrink:

```console
$ migrant resize
[ERROR] shrinking is not supported (current: 40G, requested: 20G).
  Run 'migrant destroy && migrant up' to rebuild at the smaller size.
```

Shrinking a disk safely means shrinking the filesystem and partition inside the
guest first, in that order, and getting the ordering wrong destroys data. Since
the VM is meant to be disposable, rebuilding at the smaller size is both simpler
and safer.

## Re-running it

Resize is safe to run again. If the host-side image is already at `DISK_GB` but
the guest never caught up — an interrupted resize, or a disk grown outside
`migrant` — it skips `blockresize` and goes straight to the in-guest grow:

```console
$ migrant resize
Disk image already at 40G; growing the in-guest filesystem to match...
Growing the in-guest partition and filesystem...
```

`growpart` reporting `NOCHANGE` is treated as success, so a VM that is already
fully grown resizes to a no-op rather than an error.

## Exit codes

| Code | Cause                                                                      |
| ---- | -------------------------------------------------------------------------- |
| `78` | `DISK_GB` unset, no `ssh_authorized_keys`, or a requested shrink           |
| `1`  | VM not running, or the disk's virtual size could not be read from libvirtd |
