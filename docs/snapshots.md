# Snapshots, archives, and restores

Four commands, two jobs:

- **`snapshot`** and **`reset`** checkpoint a VM in place and roll it back
- **`archive`** and **`restore`** move a VM's full state to a different host

All four rest on the same mechanism. A snapshot is a *flattened* qcow2 — no
backing file of its own — produced with `qemu-img convert` from the VM's disk.
Rebuilding points a fresh copy-on-write overlay at it, so the snapshot becomes
the new disk's backing file and must stay where it is for as long as the VM
lives. See [architecture.md](architecture.md#disk-images-and-caching) for how
that fits the wider image layout.

None of these commands need `sudo`.

---

## `migrant snapshot [path]`

Shuts the VM down and saves a flattened copy of its disk. The VM stays down
afterward.

The optional argument has three forms:

| Argument              | Result                                                   |
| --------------------- | -------------------------------------------------------- |
| *(none)*              | `$IMAGES_DIR/<VM_NAME>-snapshot.qcow2`, the default slot |
| An existing directory | `<dir>/<VM_NAME>-snapshot-<YYYYmmdd-HHMMSS>.qcow2`       |
| Anything else         | Used verbatim as the full output path                    |

```console
$ migrant snapshot
Shutting down 'arch-claude' for snapshot...
Creating snapshot (this may take a few minutes)...
Snapshot saved: /var/lib/libvirt/images/arch-claude-snapshot.qcow2
Run 'migrant reset' to rebuild the VM from this snapshot.
```

A running VM is shut down gracefully first, which fires `pre-down` and
`post-down` (see [hooks.md](hooks.md)). A VM already shut off is converted
directly, with no shutdown message. Any other state — `paused`, for instance —
is refused with exit 1 rather than snapshotted mid-flight.

Re-running against an existing file prints `Overwriting existing snapshot.`
before converting. An output directory that doesn't exist or isn't writable is
refused with exit 73, before the VM is touched.

Only the default slot appears in `migrant status` and `migrant storage`; both
look in `IMAGES_DIR` and nowhere else. A checkpoint written elsewhere is
invisible to them, so keep track of it yourself.

### Re-snapshotting a VM that was rebuilt from a snapshot

Once `reset` — or `restore`, which ends in one — has rebuilt a VM, its disk is a
copy-on-write overlay whose backing file *is* that snapshot. Snapshotting back
into the same file therefore cannot be a copy: it would mean overwriting the
image the disk is reading through. `migrant snapshot` recognises this and
commits instead, merging the overlay's accumulated writes down into the
snapshot:

```console
$ migrant snapshot
Shutting down 'arch-claude' for snapshot...
Updating snapshot in place (this may take a few minutes)...
Snapshot saved: /var/lib/libvirt/images/arch-claude-snapshot.qcow2
Run 'migrant reset' to rebuild the VM from this snapshot.
```

The outcome is the same either way — the file ends up holding the VM's current
disk state and stays flattened, so it remains a valid source for the next
`reset`. Committing is also cheaper than converting, since only the overlay's
changed clusters are written, and it grows the snapshot if `DISK_GB` was raised
since the VM was built.

This is the ordinary path for any VM that came from `reset` or `restore`. A VM
built from a base image shares nothing with its snapshot and is converted as
before, leaving the cached base image untouched.

One caveat for custom paths: once `reset` points a VM at a snapshot, that file
becomes the disk's backing file, and **qemu** — not you — has to open it for as
long as the VM exists. It runs under its own uid, so every directory on the way
to the checkpoint needs to be traversable by it. A checkpoint under a `0700`
home will leave the VM unable to start. libvirt can adjust ownership of the file
itself, but not of the directories above it. `IMAGES_DIR` is set up for exactly
this, which is why the default slot never has the problem.

---

## `migrant reset [path]`

Destroys the VM and rebuilds it from a snapshot. With no argument it uses the
default slot; with one, any snapshot file, at any path. A relative path is
resolved against the caller's working directory, not `IMAGES_DIR`.

```console
$ migrant reset
VM 'arch-claude' wiped. Rebuilding...
Using snapshot: /var/lib/libvirt/images/arch-claude-snapshot.qcow2
```

The `Migrantfile` is validated *before* the teardown, so an invalid or
incomplete config fails with the VM still intact rather than halfway through a
rebuild.

Reset preserves the old domain's MAC addresses, one per NIC. This matters more
than it looks: cloud-init writes netplan rules that match interfaces **by MAC**,
and those rules are baked into the snapshot. A rebuild with fresh random MACs
would leave them matching nothing, and the VM would come up with no network. If
the domain is already gone, reset warns that it cannot preserve them.

The basename of whatever image the VM was built from is recorded in
`$VM_DIR/.migrant-base-image`, so a later `up` recognises a VM built from a
custom-named snapshot instead of reporting it as drift.

Because cloud-init does not re-run on a rebuild, provisioning that lives in
`cloud-init.yml` is *not* reapplied — the snapshot already contains its results.
Ansible (`migrant provision`) can be re-run at any time. See
[architecture.md](architecture.md) on that split.

---

## `migrant archive <dest>`

Snapshots the VM and bundles everything needed to resume it elsewhere into one
zstd-compressed tarball. Like `snapshot`, it halts a running VM first and leaves
it down, firing the same `pre-down`/`post-down` hooks.

```console
$ migrant archive ~/backups/
Snapshotting 'arch-claude'...
Creating snapshot (this may take a few minutes)...
Snapshot saved: /home/u/backups/tmp.Xa91bK/arch-claude-snapshot.qcow2
Building archive...

Archive ready: /home/u/backups/arch-claude-20260828-141133.tar.zst
```

The tarball holds the whole VM directory plus two files beside it:

```
arch-claude/                        the VM directory, verbatim
  Migrantfile
  cloud-init.yml
  playbook.yml
  hooks/
  workspace.img                     shared-folder images living in the directory
arch-claude-snapshot.qcow2          a snapshot taken for this archive
arch-claude-mac-addresses.txt       one MAC per line, every NIC
```

A VM with no NICs — an empty or unset `NETWORKS` — archives fine; the
MAC-address file is simply empty.

`<dest>` follows the same convention as `snapshot`: an existing directory gets a
timestamped filename built inside it, anything else is used as the full path. A
trailing slash on a path that isn't a directory is refused (exit 73) rather than
silently creating a file of that name, and a destination inside the VM directory
is refused (exit 64) — the archive would otherwise be bundled into itself.

**Shared folders.** An entry whose host path resolves inside the VM directory —
the common case, and what a relative path in `SHARED_FOLDERS` produces — is
swept up automatically with the directory. An entry pointing *outside* it is
**not** included, and says so:

```
[WARNING] shared folder '/srv/data.img' is outside the VM directory and will not be included in the archive.
```

Capturing those would require `restore` to write outside the directory it
otherwise confines itself to, so for now it warns and skips.

The scratch directory holding the snapshot is created next to the eventual
output rather than in `/tmp`, since the snapshot can be many gigabytes and the
destination filesystem already needs room for it. It is removed when the command
exits, however it exits.

**The tarball is written mode 0600.** It contains the guest's entire disk and,
for a VM with a `wireguard.conf`, that file's private key — so it is created
with restrictive permissions rather than whatever the default umask would give,
and the mode is reset even when overwriting an existing archive. Treat a migrant
archive as a secret; the default umask would not.

---

## `migrant restore [--force] <tarball> [dest]`

Unpacks an archive and rebuilds the VM from it. `restore` is the one subcommand
with no VM directory yet at invocation time, so it does not read a `Migrantfile`
from the current directory the way every other command does.

`[dest]` is the **exact** directory the VM ends up in — not a parent to nest a
new subdirectory under. Omitted, it follows the same rule as every other
subcommand: `MIGRANT_DIR` if that is set, otherwise the current directory (see
[usage.md](usage.md#migrant_dir)). It need not exist yet, but if it does it must
be empty. This is deliberate: running `migrant restore archive.tar.zst` from
inside an existing VM directory should refuse, not quietly nest a second VM
inside it.

Everything is checked before anything is moved into `[dest]`, so a rejected
restore leaves no half-unpacked state:

1. `IMAGES_DIR` exists and is writable — i.e. `migrant setup` has been run on
   this host. Checked first, since the rebuild has to put a disk and a snapshot
   there
2. `[dest]` is empty or absent — checked before the tarball is even opened
3. The tarball has exactly one VM directory, containing a `Migrantfile` with a
   `VM_NAME`, plus the matching `<VM_NAME>-snapshot.qcow2` and
   `<VM_NAME>-mac-addresses.txt`
4. No VM of that name already exists on this host (see `--force` below)
5. The managed SSH key is present and matches (see below)

Only then are the contents moved into place and `migrant reset` re-invoked
against the enclosed snapshot.

### The managed SSH key must be copied across separately

An archive deliberately carries **no private key**. If the VM authenticates with
the [managed SSH key](usage.md#managed-ssh-key-recommended), copy
`~/.ssh/migrant` and `~/.ssh/migrant.pub` to the destination host before
restoring, or `restore` refuses:

```
[ERROR] the archived VM authenticates with the managed SSH key, but
  '/home/u/.ssh/migrant.pub' was not found on this host.
```

This is checked up front because it cannot be repaired afterwards. cloud-init
does not re-run on a restore, so the guest's `authorized_keys` is fixed inside
the snapshot — generating a fresh key on the destination host would produce one
the restored guest has never heard of.

### Replacing a VM that already exists

A domain of the archived name already on the destination host is not necessarily
the same VM. `restore` takes that name from a foreign tarball, and rebuilding
would undefine whatever it finds with `--remove-all-storage`, so by default it
refuses:

```
[ERROR] a VM named 'arch-claude' already exists on this host (state: running).
  Restoring would destroy it and delete its disk.
  Pass --force to replace it, or restore an archive whose Migrantfile
  uses a different VM_NAME.
```

`--force` opts into exactly that replacement — the old VM, its disk, and its
default-slot snapshot are destroyed first:

```bash
mv ~/vms/mine ~/vms/mine.old                       # or restore to a fresh path
migrant restore --force backup.tar.zst ~/vms/mine  # destroys the old VM first
```

`--force` covers the *domain* only. `[dest]` must still be empty or absent —
`--force` replaces a VM, never the caller's files.

### Where the archived snapshot ends up

The snapshot is moved out of the tarball into the **default slot**,
`$IMAGES_DIR/<VM_NAME>-snapshot.qcow2` — exactly where `migrant snapshot` would
have written it — and the restored disk is a copy-on-write overlay backed by it.
Nothing snapshot-shaped is left in `[dest]`.

That placement is the point: a restored VM is indistinguishable from one
snapshotted locally, so everything else behaves normally. `status` and `storage`
list the snapshot, a bare `migrant reset` rolls back to the archived state,
`migrant destroy` removes it, and the next `migrant archive` doesn't bundle it a
second time. It also keeps the backing file out of the caller's home directory,
which qemu may not be able to traverse (see below).

If a snapshot is already sitting in that slot — only possible as an orphan,
since a live domain of that name would have been refused — `restore` prints
`Overwriting existing snapshot.` and replaces it.

---

## Moving a VM to another host

On the source host:

```bash
migrant archive ~/backups/          # halts the VM, leaves it down
```

Copy two things across — the tarball, and the managed key pair if the VM uses
one:

```bash
scp ~/backups/arch-claude-20260828-141133.tar.zst  otherhost:~/
scp ~/.ssh/migrant ~/.ssh/migrant.pub              otherhost:~/.ssh/
```

On the destination host:

```bash
mkdir -p ~/vms/arch-claude
migrant restore ~/arch-claude-20260828-141133.tar.zst ~/vms/arch-claude
```

`restore` re-invokes `reset`, which rebuilds the domain with the archived MAC
addresses and brings the VM up. Ansible does not re-run; the snapshot already
holds the provisioned state.

An archive is as trusted as a shell script: its `Migrantfile` is sourced and its
`hooks/` execute on the host that restores it. Only restore archives you made or
trust.

---

## Exit codes

Following `sysexits.h`, as elsewhere in `migrant`:

| Code | Meaning                                                                                                         |
| ---- | --------------------------------------------------------------------------------------------------------------- |
| 1    | VM in an unsnapshottable state, no snapshot found, no MAC found, or a domain-name collision on restore          |
| 64   | Usage — missing `<dest>`, unknown option, too many arguments, or an archive destination inside the VM directory |
| 65   | The tarball is not a well-formed migrant archive                                                                |
| 66   | Tarball not found, `[dest]` is not a directory, or the managed key is missing                                   |
| 73   | Output directory missing or unwritable, `[dest]` is non-empty, or `IMAGES_DIR` is missing or unwritable         |
| 78   | The host's managed key does not match the archived VM's                                                         |
