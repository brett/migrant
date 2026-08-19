# Shared folder isolation

By default, the shared folder is backed by a fixed-size ext4 loop image
(`workspace.img` alongside your `Migrantfile`) rather than a plain host
directory. This provides two protections:

- **Symlink traversal prevention**: the image is mounted with the `nosymfollow`
  kernel flag. Host processes — your shell, editors, file watchers — cannot
  follow symlinks that the VM planted inside the share to reach files elsewhere
  on the host (e.g. `~/.ssh`, `/etc/passwd`). The flag is enforced at the VFS
  level and cannot be bypassed from userspace. `virtiofsd` itself is already
  safe due to its `pivot_root` sandbox, but this protects all other host
  processes.

- **Disk exhaustion prevention**: the image has a fixed size, set per entry in
  `SHARED_FOLDERS` — see "Multiple shared folders" below (default: 10 GB if
  unspecified). The guest cannot write more than this cap. The image is sparse —
  actual host disk usage starts at ~67 MB and grows with contents; the full cap
  is never paid upfront.

Both protections are enforced rather than assumed. If the image is missing,
fails to mount, or the mount point turns out to be backed by something other
than that image, the VM refuses to start — otherwise `virtiofsd` would serve the
bare host directory with neither `nosymfollow` nor the size cap. `migrant up`
re-checks once the VM is running and halts it if what is mounted is not what the
hook recorded.

## Accessing the workspace while the VM is halted

The loop image is mounted automatically by the QEMU hook when the VM starts, and
unmounted when it stops. While the VM is halted, the workspace files are inside
the image and not directly accessible on the host. To access them:

```bash
migrant mount    # mounts workspace.img → workspace/ (requires sudo)
# ... read, write, copy files in workspace/ ...
migrant unmount  # unmounts (requires sudo)
```

`migrant mount` can also be used to pre-populate the workspace before the first
`migrant up`.

## Opting out

To opt out of the loop image and use a plain host directory instead, set
`SHARED_FOLDER_ISOLATION=false` in the `Migrantfile`. This restores the
pre-loop-image behaviour (no size cap, no symlink protection) and is appropriate
only if you trust the VM's workload.

## Multiple shared folders

`SHARED_FOLDERS` is an array — a `Migrantfile` can define more than one entry,
each backed by its own loop image (`<name>.img`) and mounted at whatever guest
path its `fstab` entry names. Each gets the same `nosymfollow` and size-cap
protections as the default `workspace` share, and `migrant` requires no code
changes to support an additional one.

Size each entry with a third, colon-separated field:
`"host_path:guest_tag:size_gb"`. This only applies to loop-image-backed shares —
pairing a size with `SHARED_FOLDER_ISOLATION=false` is a validation error, since
a plain host directory has no image to size.

Older `Migrantfile`s may instead set `SHARED_FOLDER_SIZE_GB` once, applying it
to every entry that omits the third field. That form still works and is not
going away, but the per-entry field is the current way to size a share — it lets
shares with different needs coexist without one setting having to fit all of
them, which is the more common case once there's more than one.

### Example: persisting Claude Code conversation history across rebuilds

`migrant destroy && migrant up` gives you a clean VM, which also means losing
any in-progress Claude Code conversation — the transcripts `claude --resume`
reads live under `~/.claude/projects/` in the guest. A second shared folder
scoped to just that directory lets transcripts survive the rebuild without
carrying along the rest of `~/.claude` (OAuth credentials in
`.credentials.json`, and unrelated caches that can run into the hundreds of MB).
Login state isn't covered by this — `~/.claude.json` lives directly under the
guest's home directory, not under `~/.claude/`, so it isn't reachable by a share
rooted there; re-authenticating after a rebuild is the trade-off.

Transcripts are small, so the example gives this share its own low cap rather
than reusing `workspace`'s:

`Migrantfile`:

```bash
SHARED_FOLDERS=(
  "workspace:workspace:10"
  "claude-projects:claude-projects:2"
)
```

`cloud-init.yml`, alongside the existing `workspace` mount:

```yaml
runcmd:
  - mkdir -p /home/migrant/.claude/projects
  - echo "claude-projects /home/migrant/.claude/projects virtiofs defaults 0 0" >> /etc/fstab
```

Weigh this against the project's threat model before using it: the point of
`destroy && up` is that a compromised or misbehaving agent is wiped, not patched
in place (see `docs/security/README.md`). Conversation transcripts are content
the model reads back in on resume, so anything prompt-injected into a transcript
during a compromised session carries forward into the rebuilt VM right along
with the legitimate history. Treat this as an opt-in convenience for trusted
sessions, not a default.

## Restrictions

A shared folder may not contain the VM directory's `hooks/`. Hooks run on the
host as the invoking user, so a guest able to write `hooks/pre-up` would run
code on the host at the next `migrant up`. Sharing the VM directory itself, or
any parent of it, is refused for the same reason — share a subdirectory.

## Setup notes

Add `*.img` to `.gitignore` to avoid committing the loop image to source
control. The `e2fsprogs` package (`mkfs.ext4`) must be installed on the host; it
is standard on all Linux distributions.
