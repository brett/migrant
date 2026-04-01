# Implementation Plan: Loop Image for Shared Folder Security

## Background and rationale

Two attack vectors exist against the host from a malicious guest via the shared folder:

**Symlink traversal.** The guest can create symlinks inside the shared folder pointing
to arbitrary host paths, e.g.:

```bash
# inside the guest
ln -s /etc/passwd /home/agent/workspace/evil
```

Any host process that then follows `evil` — a shell, a file watcher, a backup tool,
an IDE — reads or writes the real host target. Confirmed exploitable: `cat
~/workspace/evil` on the host reads the host's `/etc/passwd`.

virtiofsd itself is _not_ vulnerable to this: the standalone Rust virtiofsd package
on Arch defaults to `--sandbox namespace`, which calls `pivot_root(2)` to make the
shared directory the daemon's filesystem root. Symlinks pointing outside it resolve
to paths _inside_ it. This is a documented guarantee in the virtiofsd README, and
confirmed via `ps aux` showing no `--sandbox` flag (i.e. the safe default is in
effect). The threat is from other host processes — including the user's own shell.

**Disk exhaustion.** The guest can fill the host disk by writing large files into the
shared folder. There is currently no cap on how much data can be written to
`$(pwd)/workspace/`. (The `DISK_GB` cap on the VM's qcow2 overlay is a genuine hard
limit — verified experimentally — but it is separate from the shared folder.)

### Why a loop image is the best solution

`MS_NOSYMFOLLOW` (Linux 5.10+) is a VFS-level mount flag that instructs the kernel
not to follow symlinks during path resolution for **any process** accessing a
mountpoint. It is not specific to virtiofsd, is not bypassable from userspace, and
applies equally to relative and absolute symlinks. `readlink(2)` and symlink creation
still work — the flag only prevents traversal.

A fixed-size ext4 image file, loop-mounted with `nosymfollow`, provides both
mitigations in a single mechanism:

- The `nosymfollow` flag on the mountpoint closes the symlink traversal gap for all
  host processes.
- The fixed image size caps the total data the guest can write to the share, with the
  same `ENOSPC` semantics as `DISK_GB` on the VM disk.

The image is created with `truncate`, producing a sparse file. Actual host disk usage
starts at approximately 67 MB (ext4 metadata only) and grows proportionally with
contents. The cap is not paid upfront.

Alternative approaches considered and rejected:

- **Bind mount + `nosymfollow` only**: fixes symlink traversal but leaves disk
  exhaustion entirely unmitigated.
- **Filesystem project quotas (ext4/XFS)**: filesystem-specific, complex to set up
  and tear down programmatically, no symlink protection.
- **btrfs subvolumes + qgroups**: only works if the host uses btrfs, and btrfs qgroup
  accounting has known reliability issues under heavy I/O.


## Architecture

```
workspace.img  ──(loop mount, nosymfollow)──▶  workspace/  ──(virtiofsd)──▶  ~/workspace
   on disk                                    host dir                        inside guest
```

The loop image is mounted onto the virtiofs `host_path` directory by the libvirt QEMU
hook, which already runs as root and fires at the correct lifecycle points. This keeps
`migrant.sh up` and `migrant.sh halt` free of sudo calls. Two new subcommands —
`mount` and `unmount` — provide host-side access to the image when the VM is not
running; these do require sudo.

**Image path convention:** `${host_path%/}.img` — the image lives alongside the
`Migrantfile` in the project directory. For the default Migrantfile,
`host_path = $(pwd)/workspace`, so the image is `$(pwd)/workspace.img`.

```
~/my-vm/
├── Migrantfile
├── cloud-init.yml
├── workspace/          ← mount point (populated when VM is up or manually mounted)
└── workspace.img       ← loop image (add to .gitignore)
```

The QEMU hook derives the image path from the virtiofs source directory extracted
from the domain XML — no separate config file is required.


## Changes to `Migrantfile` (example: `claude/Migrantfile`)

Add `SHARED_FOLDER_SIZE_GB` with a comment:

```bash
# Shared folder loop image size in gigabytes. A sparse ext4 image of this size
# is created the first time 'migrant.sh up' or 'migrant.sh mount' is run. The
# image starts at ~67 MB on disk and grows with contents up to this cap.
# Add workspace.img (or *.img) to .gitignore to avoid committing it.
SHARED_FOLDER_SIZE_GB=10
```


## Changes to `migrant.sh`

### 1. `usage()`

Add `mount` and `unmount` entries to the usage heredoc (descriptions must match the
README word-for-word, per CLAUDE.md). Insert after the `status` entry:

```
  mount               Mount the shared folder loop image for host-side access;
                      creates the image if it does not exist
  unmount             Unmount the shared folder loop image
```

### 2. `cmd_up` — create image if absent

Image creation (`truncate` + `mkfs.ext4`) requires no root and can run as the current
user. It belongs in `cmd_up` so the image is ready before the QEMU hook fires its
`prepare` event.

The creation block runs only when the VM is being created for the first time (the path
that reaches `virt-install`). For an existing stopped VM being restarted, the image
was already created on first `up` and the hook re-mounts it automatically.

In the shared folder loop inside `cmd_up`, after the existing `mkdir -p "$host_path"`:

```bash
for shared_folder in "${SHARED_FOLDERS[@]+"${SHARED_FOLDERS[@]}"}"; do
  local host_path="${shared_folder%%:*}"
  local guest_tag="${shared_folder##*:}"
  # Relative paths are resolved relative to the VM directory, matching the
  # existing SHARED_FOLDERS handling already in cmd_up.
  [[ "$host_path" != /* ]] && host_path="$VM_DIR/$host_path"
  local img_path="${host_path%/}.img"
  local size_gb="${SHARED_FOLDER_SIZE_GB:-10}"

  if [[ ! -f "$img_path" ]]; then
    echo "Creating ${size_gb}G shared folder image at $img_path..."
    truncate -s "${size_gb}G" "$img_path"
    if ! mkfs.ext4 -F -q "$img_path"; then
      rm -f "$img_path"
      echo "Error: mkfs.ext4 failed for $img_path." >&2
      exit 1
    fi
  fi

  mkdir -p "$host_path"
  extra_args+=(--filesystem "source=$host_path,target=$guest_tag,driver.type=virtiofs")
  has_shared_folders=true
done
```

`mkfs.ext4` is provided by `e2fsprogs`, which is a standard dependency on all Linux
distributions and almost certainly already installed. It is not added to the
`pacman -S` prerequisites in the README because it is universally present, but it
should be mentioned in the Security notes.

### 3. `cmd_destroy` — preserve the image, print a note

`virsh destroy` force-kills the VM. The QEMU hook fires `release`, which unmounts the
image automatically. No explicit unmount call is needed in `cmd_destroy`.

The image is **not deleted** — it is workspace data, not VM infrastructure. A note is
printed so the user knows it persists:

```bash
cmd_destroy() {
  if ! virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "VM '$VM_NAME' does not exist."
    return
  fi
  teardown_vm
  echo "VM '$VM_NAME' destroyed."

  # Print paths of any loop images that were preserved
  for shared_folder in "${SHARED_FOLDERS[@]+"${SHARED_FOLDERS[@]}"}"; do
    local host_path="${shared_folder%%:*}"
    [[ "$host_path" != /* ]] && host_path="$VM_DIR/$host_path"
    local img_path="${host_path%/}.img"
    if [[ -f "$img_path" ]]; then
      echo "Shared folder image preserved at: $img_path"
      echo "  To delete it: rm '$img_path'"
    fi
  done
}
```

The VM files are deleted by `teardown_vm` (the shared helper already used by
`cmd_destroy` and `cmd_reset`); no need to inline `virsh destroy` / `rm` here.
The QEMU hook fires `release` during `teardown_vm`, which unmounts the image
automatically before the loop above runs.

### 4. `cmd_mount` (new subcommand)

`mount` provides host-side access to the loop image when the VM is not running. It
also serves as the mechanism to pre-populate the workspace before the first
`migrant.sh up`.

Behaviour by state:

| VM state | Image mounted? | Action |
|---|---|---|
| Running | Yes (hook mounted it) | Report path, note concurrent access |
| Running | No (anomaly) | Error — do not attempt to mount |
| Not running / doesn't exist | Yes | Report already mounted |
| Not running / doesn't exist | No, image exists | Mount with sudo |
| Not running / doesn't exist | No, image absent | Create image, then mount with sudo |

```bash
cmd_mount() {
  if [[ -z "${SHARED_FOLDERS[*]+"${SHARED_FOLDERS[*]}"}" ]]; then
    echo "No shared folders configured in Migrantfile."
    return
  fi

  local size_gb="${SHARED_FOLDER_SIZE_GB:-10}"
  local vm_running=false
  if virsh dominfo "$VM_NAME" &>/dev/null \
      && [[ "$(virsh domstate "$VM_NAME")" == "running" ]]; then
    vm_running=true
  fi

  for shared_folder in "${SHARED_FOLDERS[@]}"; do
    local host_path="${shared_folder%%:*}"
    local img_path="${host_path%/}.img"

    if mountpoint -q "$host_path" 2>/dev/null; then
      if $vm_running; then
        echo "$host_path: mounted (VM is running — host and guest share access)."
      else
        echo "$host_path: already mounted."
      fi
      continue
    fi

    # Image is not mounted. Refuse if VM is running — mounting under an active
    # virtiofsd session is unsafe and indicates something went wrong.
    if $vm_running; then
      echo "Error: VM '$VM_NAME' is running but $host_path is not mounted." >&2
      echo "  The QEMU hook should have mounted it. Check the hook is installed" >&2
      echo "  by re-running 'migrant.sh setup', then halt and restart the VM." >&2
      exit 1
    fi

    # Create the image if it does not exist.
    if [[ ! -f "$img_path" ]]; then
      echo "Creating ${size_gb}G shared folder image at $img_path..."
      truncate -s "${size_gb}G" "$img_path"
      if ! mkfs.ext4 -F -q "$img_path"; then
        rm -f "$img_path"
        echo "Error: mkfs.ext4 failed for $img_path." >&2
        exit 1
      fi
    fi

    mkdir -p "$host_path"
    echo "Mounting $img_path at $host_path (requires sudo)..."
    sudo mount -o loop,nosymfollow "$img_path" "$host_path"
    echo "  Mounted. Unmount with 'migrant.sh unmount' when done."
  done
}
```

### 5. `cmd_unmount` (new subcommand)

`unmount` releases the manual mount obtained via `cmd_mount`. It refuses if the VM is
running — pulling the mount from under an active virtiofsd session would corrupt the
guest's view of the filesystem.

```bash
cmd_unmount() {
  if [[ -z "${SHARED_FOLDERS[*]+"${SHARED_FOLDERS[*]}"}" ]]; then
    echo "No shared folders configured in Migrantfile."
    return
  fi

  # Refuse if VM is running — unmounting would break virtiofsd.
  if virsh dominfo "$VM_NAME" &>/dev/null \
      && [[ "$(virsh domstate "$VM_NAME")" == "running" ]]; then
    echo "Error: VM '$VM_NAME' is running." >&2
    echo "  Halt the VM with 'migrant.sh halt' before unmounting." >&2
    exit 1
  fi

  for shared_folder in "${SHARED_FOLDERS[@]}"; do
    local host_path="${shared_folder%%:*}"

    if mountpoint -q "$host_path" 2>/dev/null; then
      echo "Unmounting $host_path (requires sudo)..."
      sudo umount "$host_path"
    else
      echo "$host_path: not mounted."
    fi
  done
}
```

If `umount` fails because a file is open (device busy), the error from `umount` is
allowed to propagate. The user must close any open files and retry.

### 6. Dispatch table

Add `mount` and `unmount` to the existing `case` statement:

```bash
case "$SUBCOMMAND" in
  setup)            cmd_setup ;;
  up)               require_config; cmd_up ;;
  halt)             require_config; cmd_halt ;;
  destroy)          require_config; cmd_destroy ;;
  console)          require_config; cmd_console ;;
  ssh)              require_config; cmd_ssh "${@:2}" ;;
  pubkey)           require_config; cmd_pubkey ;;
  ip)               require_config; cmd_ip ;;
  snapshot)         require_config; cmd_snapshot ;;
  reset)            require_config; cmd_reset ;;
  provision)        require_config; cmd_provision ;;
  storage)          cmd_storage ;;
  mount)            require_config; cmd_mount ;;
  unmount)          require_config; cmd_unmount ;;
  -h|--help|help)   usage 0 ;;
  *)                usage ;;
esac
```


## Changes to the QEMU hook (via `cmd_setup`)

### A separate hook file, not a restructured one

The script now installs hooks into subdirectories (`qemu.d/`, `network.d/`) rather
than single files. libvirtd calls every executable in `qemu.d/` in order, so the
shared-folder logic can live in its own file — **`/etc/libvirt/hooks/qemu.d/migrant-loop`**
— leaving the existing `qemu.d/migrant` (network isolation) completely untouched.

The new hook has no network-isolation guard at all: it only checks
`managed-by=migrant.sh` and handles `prepare`/`release` for all managed VMs.

`cmd_setup` gains a third hook installation block, using the same
compare-and-reinstall pattern already used for `qemu.d/migrant` and
`network.d/migrant`.

### New hook file: `qemu.d/migrant-loop`

```bash
#!/bin/bash
# Managed by migrant.sh

VM_NAME="$1"
OPERATION="$2"

# Check the domain description from the persistent XML file rather than via
# virsh: hooks are invoked synchronously while libvirtd holds the per-domain
# lock, so calling virsh against the same domain from within a hook deadlocks.
local_xml="/etc/libvirt/qemu/${VM_NAME}.xml"
grep -q "managed-by=migrant.sh" "$local_xml" 2>/dev/null || exit 0

# Extract the source directory for each virtiofs filesystem from the domain XML.
# python3 is used for robust XML parsing; it is available on all target systems.
virtiofs_sources() {
  python3 - "$local_xml" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.argv[1])
for fs in tree.findall('.//filesystem'):
    drv = fs.find('driver')
    if drv is not None and drv.get('type') == 'virtiofs':
        src = fs.find('source')
        if src is not None and src.get('dir'):
            print(src.get('dir'))
PYEOF
}

mount_shared_folders() {
  while IFS= read -r source_dir; do
    [[ -z "$source_dir" ]] && continue
    local img_path="${source_dir%/}.img"

    if [[ ! -f "$img_path" ]]; then
      # No image file alongside this source dir — it is a plain directory share.
      # Skip silently; virtiofsd will serve the directory as-is.
      continue
    fi

    if mountpoint -q "$source_dir" 2>/dev/null; then
      # Already mounted — idempotent, nothing to do.
      continue
    fi

    mkdir -p "$source_dir"
    mount -o loop,nosymfollow "$img_path" "$source_dir" \
      || echo "migrant: failed to mount $img_path at $source_dir" >&2
  done < <(virtiofs_sources)
}

unmount_shared_folders() {
  while IFS= read -r source_dir; do
    [[ -z "$source_dir" ]] && continue
    if mountpoint -q "$source_dir" 2>/dev/null; then
      umount "$source_dir" \
        || echo "migrant: failed to unmount $source_dir" >&2
    fi
  done < <(virtiofs_sources)
}

case "$OPERATION" in
  prepare) mount_shared_folders ;;
  release) unmount_shared_folders ;;
esac
```

#### Why `prepare` and `release`

- **`prepare`** fires before libvirt starts the QEMU process, which means before
  virtiofsd is launched. The loop image must be mounted before virtiofsd opens the
  source directory, so `prepare` is the correct point. `started` would be too late.
- **`release`** fires after all domain resources are fully released, including after
  virtiofsd has exited. This is the safe point to unmount. Both graceful shutdown
  (`virsh shutdown`) and forced stop (`virsh destroy`) trigger `release`.


## Visible behaviour changes for the user

### While the VM is running

No change. The loop image is mounted onto `workspace/` by the hook before the VM
starts. The host can read and write `workspace/` as a normal directory. The only
difference from the current plain-directory approach is that `nosymfollow` is in
effect: host processes cannot follow symlinks created by the guest. Normal file
access is unaffected.

### While the VM is halted

**Change from current behaviour.** Currently, `workspace/` is a plain directory that
is always readable on the host. With the loop image, the hook unmounts the image when
the VM stops, leaving `workspace/` as an empty directory. The files are inside
`workspace.img` but are not accessible until the image is mounted.

To access the workspace while the VM is halted, use the new subcommands:

```bash
migrant.sh mount    # mounts workspace.img → workspace/ (requires sudo)
# ... read, write, copy files in workspace/ ...
migrant.sh unmount  # unmounts (requires sudo)
```

The `mount` subcommand creates the image if it does not yet exist, making it the
correct entry point for pre-populating the workspace before the first `migrant.sh up`.

### After `migrant.sh destroy`

The qcow2 disk and seed ISO are deleted as before. The loop image (`workspace.img`) is
**preserved**. A message is printed noting the image path and how to delete it:

```
VM 'claude' destroyed.
Shared folder image preserved at: /home/user/my-vm/workspace.img
  To delete it: rm '/home/user/my-vm/workspace.img'
```

### After a host reboot

Loop mounts do not survive a reboot. The next `migrant.sh up` starts the VM, the QEMU
hook fires `prepare`, and the image is re-mounted automatically before virtiofsd
starts. No user action required. `workspace/` is populated again as soon as the VM is
running.

If the user wants access to the workspace before starting the VM after a reboot, they
run `migrant.sh mount` as usual.


## Edge cases

**VM has no shared folders.** If `SHARED_FOLDERS` is empty or unset, `virtiofs_sources`
returns nothing and both `mount_shared_folders` and `unmount_shared_folders` are
no-ops. `cmd_mount` and `cmd_unmount` print "No shared folders configured" and return.

**Image does not exist at VM start.** If the image file has been deleted and the VM is
started, the hook's `mount_shared_folders` detects `! -f "$img_path"` and skips
mounting. virtiofsd serves an empty plain directory (no `nosymfollow`, no size cap —
degraded security). The correct remedy is to run `migrant.sh mount` to recreate the
image, then `migrant.sh destroy && migrant.sh up`. This edge case does not need to
be detected in `cmd_up` for the "existing stopped VM" path, but a warning could be
added in future.

**`SHARED_FOLDER_SIZE_GB` changed after image already exists.** The new value has no
effect on an existing image — `mkfs.ext4` has already run. A warning in `cmd_up` is
advisable: if `$img_path` exists and its size differs from `${SHARED_FOLDER_SIZE_GB}G`,
print a notice that the existing image size will be used.

**`umount` fails with "device is busy".** A file open in the mounted image prevents
unmounting. The error from `umount` propagates to the user. They must close the file
and retry `migrant.sh unmount`.

**Multiple shared folders.** All `cmd_mount`, `cmd_unmount`, `mount_shared_folders`,
and `unmount_shared_folders` iterate all entries in `SHARED_FOLDERS`. Each entry gets
its own `${host_path%/}.img`.

**`host_path` configured as an absolute path outside the project directory.** The
image would be created at `${host_path%/}.img` adjacent to the mount point, not in
the project directory. This is consistent but might be surprising. The convention
should be documented — for the standard Migrantfile pattern of `$(pwd)/workspace`,
the image is always in the project directory.

**`cmd_reset` requires no changes.** `reset` calls `teardown_vm keep_snapshot`
(which fires the hook's `release`, unmounting the image) and then re-runs `cmd_up`
(which recreates the VM; the hook fires `prepare` and remounts the image before
virtiofsd starts). The loop image is preserved across resets because it is in the
project directory, not in `IMAGES_DIR`.

**Existing users upgrading.** Users with an existing VM (plain directory, no loop
image) must re-run `migrant.sh setup` to install the updated hook, then
`migrant.sh destroy && migrant.sh up` to recreate the VM with the loop image. Their
existing `workspace/` contents will need to be copied into the new loop image manually.
A migration note in the README is appropriate.


## `.gitignore`

The example `claude/` directory should include a `.gitignore`:

```
workspace.img
```

Or more broadly:

```
*.img
```

The README should note that `*.img` files must not be committed.


## Summary of files changed

| File                    | Change                                                                                           |
| ----------------------- | ------------------------------------------------------------------------------------------------ |
| `migrant.sh`            | `usage()`, `cmd_up`, `cmd_destroy`, new `cmd_mount`, new `cmd_unmount`, new hook block in `cmd_setup` for `qemu.d/migrant-loop` |
| `claude/Migrantfile`    | Add `SHARED_FOLDER_SIZE_GB=10`                                                                   |
| `claude/.gitignore`     | Add `*.img` (new file)                                                                           |
| `README.md`             | Security notes, prerequisites, new subcommands, migration note                                   |
| `TODO.md`               | Mark symlink traversal and disk exhaustion items as resolved                                     |
