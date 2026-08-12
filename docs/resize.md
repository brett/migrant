# Resizing the disk

Disk size is the one resource that needs its own command. `RAM_MB` and `VCPUS`
are reconciled automatically by `migrant up` — see
[Changing RAM and vCPUs](#changing-ram-and-vcpus) at the bottom of this page.

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

## Changing RAM and vCPUs

Unlike the disk, `RAM_MB` and `VCPUS` need no separate command. Edit them in the
`Migrantfile` and run `migrant up`; a stopped VM has its persistent libvirt
definition brought into line before it starts:

```console
$ migrant up
Reconciling resources: RAM 8192 -> 16384 MB, vCPUs 4 -> 6.
VM 'census' exists but is not running. Starting...
```

Shrinking is allowed here, and says so. The mark sits on the resource that
shrank, so a run that grows one and shrinks the other reads correctly:

```console
$ migrant up
Reconciling resources: RAM 16384 -> 8192 MB (shrink); Migrantfile is authoritative.
$ migrant up
Reconciling resources: RAM 8192 -> 16384 MB, vCPUs 6 -> 4 (shrink); Migrantfile is authoritative.
```

The asymmetry with disk resize is deliberate. Shrinking a disk means shrinking a
filesystem inside the guest and risks data loss; shrinking RAM or vCPU count
only edits the domain definition, needs no guest cooperation, and is undone by
editing the value back.

**The `Migrantfile` is authoritative.** If you changed a VM's memory or CPU
count by hand with `virsh`, the next `migrant up` reverts it to whatever the
`Migrantfile` says.

### A running VM is never modified

If the VM is already up, `migrant up` reports the mismatch and changes nothing:

```console
$ migrant up
VM 'census' is already running.
[WARNING] Migrantfile resources differ from the defined VM: RAM 8192 -> 16384 MB.
  Run 'migrant halt && migrant up' to apply.
```

Exit status is still `0`, so `migrant up && ...` keeps working.

The state is checked twice — once when `up` decides what to do, and again in the
moment before the first `virsh` call — so a VM that something else starts
partway through is warned about rather than reconciled behind libvirt's back.

Raising either value above what the VM booted with requires a reboot regardless
— the domains `migrant` creates have no memory-hotplug slots and a fixed vCPU
maximum. Lowering them live would be possible through the balloon driver, but
applying shrinks immediately while grows waited for a reboot would be more
confusing than doing neither, and ballooning memory away from a running workload
is its own hazard.

Nothing surfaces a mismatch until you run `migrant up` — `migrant status` does
not report it.

### Failures are rolled back

The change takes up to four `virsh` calls (memory maximum, memory current, vCPU
maximum, vCPU current), and only the resource that actually drifted is touched.
If one fails partway, the previous definition is restored with `virsh define`
and the VM is not started, so it never boots with a half-applied configuration.
Ctrl-C or a `SIGTERM` mid-sequence restores it the same way.

### Snapshots do not capture resources

`migrant snapshot` saves the disk image only. `migrant reset` therefore rebuilds
with whatever `RAM_MB` and `VCPUS` say **at reset time**, not the values that
were in effect when the snapshot was taken.

### Validation

`RAM_MB` must be 1–9999999 (megabytes) and `VCPUS` 1–9999. Anything else exits
`78` before the VM is touched — including on `migrant reset`, which would
otherwise tear the VM down and only then discover it could not rebuild it.
Over-provisioning is not checked here: libvirt permits overcommit, and it
reports a genuinely impossible allocation better than a guess at host capacity
would.
