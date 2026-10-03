#!/usr/bin/env bash
set -euo pipefail
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Integration test for shared folder isolation. The contract is that the guest
# is never served the bare host directory: if the loop image is missing, fails
# to mount, or the mount point is backed by something else, the VM must refuse
# to start rather than run without nosymfollow and the size cap.
#
# Run from test/vm, the bare fixture these scripts are built for:
#   cd test/vm && ../test-shared-folder.sh
#
# Prerequisites:
#   - migrant setup has been run (with the updated hooks)
#   - sudo, for the decoy-mount case
#   - No VM with this name currently exists (the test creates and destroys one)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"

if [[ ! -f Migrantfile ]]; then
  echo "[FAIL] No Migrantfile in $(pwd). Run from a VM directory." >&2
  exit 1
fi

# shellcheck source=/dev/null
source Migrantfile

WS="$PWD/workspace"
IMG="$PWD/workspace.img"
SIZED_WS="$PWD/sized"
SIZED_IMG="$PWD/sized.img"
EXTRA_WS="$PWD/extrafs"
EXTRA_IMG="$PWD/extrafs.img"
JOURNAL_WS="$PWD/journal"
JOURNAL_IMG="$PWD/journal.img"
WORK=""
RECORD="/run/migrant/${VM_NAME}.shared"
HOOKS_DIR="./hooks"
TEST_HOOK="$HOOKS_DIR/pre-up"
TEST_HOOK_BACKUP=""
DECOY_MOUNTED=false
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

cleanup() {
  if [[ "$DECOY_MOUNTED" == true ]]; then
    sudo umount "$WS" 2>/dev/null || true
  fi
  # Restore any pre-existing pre-up hook the test displaced; otherwise remove
  # the one the test installed. Never rm -rf $HOOKS_DIR — it may hold hooks
  # that predate this test.
  if [[ -n "$TEST_HOOK_BACKUP" && -f "$TEST_HOOK_BACKUP" ]]; then
    mv "$TEST_HOOK_BACKUP" "$TEST_HOOK"
  else
    rm -f "$TEST_HOOK"
  fi
  virsh dominfo "$VM_NAME" &>/dev/null && "$MIGRANT" destroy 2>/dev/null || true
  rm -f "$EXTRA_IMG" "$SIZED_IMG" "$JOURNAL_IMG"
  rmdir "$EXTRA_WS" "$SIZED_WS" "$JOURNAL_WS" 2>/dev/null || true
  [[ -n "$WORK" ]] && rm -rf "$WORK" || true
  # A directory placed at $IMG to force a truncate failure (below) is only
  # ever empty, so this is a no-op unless that test was interrupted before
  # its own cleanup ran — never remove a real workspace.img this way. One
  # chain, not a bare '[[ ]] &&' statement: under set -e a false test here
  # would otherwise abort the trap itself.
  [[ -d "$IMG" ]] && rmdir "$IMG" 2>/dev/null || true
  if [[ -f Migrantfile.test-backup ]]; then
    mv Migrantfile.test-backup Migrantfile
  fi
}
trap cleanup EXIT

# hook.log is append-only, so a message from an earlier run would satisfy any
# grep over the whole file. Mark the end, then read only what follows.
log_mark() { wc -l < /run/migrant/hook.log 2>/dev/null || echo 0; }
log_since() { tail -n +"$(( ${1:-0} + 1 ))" /run/migrant/hook.log 2>/dev/null || true; }

# Everything below reads the record the loop hook writes. Locate a mount's
# backing image the way migrant does — findmnt names the loop device, sysfs
# names the file behind it.
backing_of() {
  local dev
  dev=$(findmnt -nro SOURCE "$1" 2>/dev/null) || return 1
  [[ "$dev" == /dev/loop* ]] || return 1
  local f="/sys/block/${dev#/dev/}/loop/backing_file"
  [[ -r "$f" ]] || return 1
  f=$(<"$f")
  echo "${f% (deleted)}"
}

cp Migrantfile Migrantfile.test-backup

echo "=== Shared folder isolation test ==="
echo "VM: $VM_NAME"
echo "Workspace: $WS"
echo ""

if virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "Cleaning up leftover VM '$VM_NAME'..."
  "$MIGRANT" destroy 2>/dev/null || true
fi

reset_migrantfile() {
  cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
SHARED_FOLDERS=("workspace:workspace")
SHARED_FOLDER_SIZE_GB=1
EOF
}
reset_migrantfile

# ============================================================
# Part 0: per-entry size validation (no VM needed)
# ============================================================
# Validation runs in sync_managed_config, before virt-install, so a bad
# value never reaches the point of creating a domain.

echo "--- test: per-entry size validation ---"

for bad in 5GB 3x 0 -1 999999; do
  cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
SHARED_FOLDERS=("workspace:workspace:$bad")
EOF
  set +e
  out=$("$MIGRANT" up 2>&1); rc=$?
  set -e
  if grep -q "\[ERROR\] invalid size in SHARED_FOLDERS entry: workspace:workspace:$bad" <<<"$out" \
      && (( rc == 65 )); then
    pass "rejects per-entry size '$bad' with exit 65"
  else
    fail "per-entry size '$bad': status=$rc output=$out"
    "$MIGRANT" destroy 2>/dev/null || true
  fi
done

# A valid first entry must not short-circuit validation of the rest of the
# array — the loop has to keep checking every entry, not just the first.
cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
SHARED_FOLDERS=(
  "workspace:workspace:5"
  "sized:sized:5GB"
)
EOF
set +e
out=$("$MIGRANT" up 2>&1); rc=$?
set -e
if grep -q "\[ERROR\] invalid size in SHARED_FOLDERS entry: sized:sized:5GB" <<<"$out" \
    && (( rc == 65 )); then
  pass "rejects an invalid size in a later entry despite a valid first entry"
else
  fail "mixed valid/invalid entries: status=$rc output=$out"
  "$MIGRANT" destroy 2>/dev/null || true
fi

cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
SHARED_FOLDERS=("workspace:workspace:5")
SHARED_FOLDER_ISOLATION=false
EOF
set +e
out=$("$MIGRANT" up 2>&1); rc=$?
set -e
if grep -q "\[ERROR\] SHARED_FOLDERS entry has a size limit but SHARED_FOLDER_ISOLATION=false" <<<"$out" \
    && (( rc == 65 )); then
  pass "rejects a per-entry size with SHARED_FOLDER_ISOLATION=false"
else
  fail "size + SHARED_FOLDER_ISOLATION=false: status=$rc output=$out"
  "$MIGRANT" destroy 2>/dev/null || true
fi

for bad in 5GB 3x 0 -1; do
  cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
SHARED_FOLDERS=("workspace:workspace")
SHARED_FOLDER_SIZE_GB=$bad
EOF
  set +e
  out=$("$MIGRANT" up 2>&1); rc=$?
  set -e
  if grep -q "\[ERROR\] invalid SHARED_FOLDER_SIZE_GB: '$bad'" <<<"$out" && (( rc == 65 )); then
    pass "rejects SHARED_FOLDER_SIZE_GB=$bad with exit 65"
  else
    fail "SHARED_FOLDER_SIZE_GB=$bad: status=$rc output=$out"
    "$MIGRANT" destroy 2>/dev/null || true
  fi
done

# Like a per-entry size, a journal has nothing to apply to without a loop
# image, so asking for one with isolation off is an error, not a silent no-op.
cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
SHARED_FOLDERS=("workspace:workspace")
SHARED_FOLDER_ISOLATION=false
SHARED_FOLDER_JOURNAL=true
EOF
set +e
out=$("$MIGRANT" up 2>&1); rc=$?
set -e
if grep -q "\[ERROR\] SHARED_FOLDER_JOURNAL=true but SHARED_FOLDER_ISOLATION=false" <<<"$out" \
    && (( rc == 65 )); then
  pass "rejects SHARED_FOLDER_JOURNAL=true with SHARED_FOLDER_ISOLATION=false"
else
  fail "journal + SHARED_FOLDER_ISOLATION=false: status=$rc output=$out"
  "$MIGRANT" destroy 2>/dev/null || true
fi

# ============================================================
# Part 0b: SHARED_FOLDER_JOURNAL at image creation (no VM needed)
# ============================================================
# 'up' and 'mount' create missing images through the same function, but only
# 'mount' gets there without building a domain. Stubbing sudo and virsh on
# PATH stops it there: virsh reports no domain, so the VM is "not running",
# and the stubbed sudo makes the final loop mount a no-op — so no root and no
# VM. Journal state is read with dumpe2fs, not the debugfs probe migrant
# itself uses, so a bug in that probe cannot make these agree with it.

echo "--- test: SHARED_FOLDER_JOURNAL at image creation ---"

WORK=$(mktemp -d)
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/virsh" <<'WRAP'
#!/usr/bin/env bash
exit 1
WRAP
cat > "$WORK/fakebin/sudo" <<'WRAP'
#!/usr/bin/env bash
exit 0
WRAP
chmod +x "$WORK/fakebin/virsh" "$WORK/fakebin/sudo"

has_journal() { LC_ALL=C dumpe2fs -h "$1" 2>/dev/null | grep -qE '^Filesystem features:.* has_journal( |$)'; }

# Usage: run_journal_mount [journal_value [mke2fs_config]]
# An empty journal_value leaves SHARED_FOLDER_JOURNAL unset. mke2fs_config, if
# given, is exported as MKE2FS_CONFIG for this run only.
run_journal_mount() {
  cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
SHARED_FOLDERS=("journal:journal:1")
${1:+SHARED_FOLDER_JOURNAL=$1}
EOF
  set +e
  if [[ -n "${2:-}" ]]; then
    out=$(PATH="$WORK/fakebin:$PATH" MKE2FS_CONFIG="$2" "$MIGRANT" mount 2>&1); rc=$?
  else
    out=$(PATH="$WORK/fakebin:$PATH" "$MIGRANT" mount 2>&1); rc=$?
  fi
  set -e
}

# An mke2fs.conf whose ext4 defaults leave out has_journal. A host with one
# must still get a journal when SHARED_FOLDER_JOURNAL=true asks for it, so
# migrant has to request the feature, not just stop refusing it.
NOJOURNAL_CONF="$WORK/mke2fs-nojournal.conf"
cat > "$NOJOURNAL_CONF" <<'EOF'
[defaults]
	base_features = sparse_super,large_file,filetype,resize_inode,dir_index,ext_attr
	blocksize = 4096
	inode_size = 256
	inode_ratio = 16384
[fs_types]
	ext4 = {
		features = extent,huge_file,flex_bg,metadata_csum,64bit,dir_nlink,extra_isize
	}
EOF

rm -f "$JOURNAL_IMG"
run_journal_mount ""
if (( rc == 0 )) && [[ -f "$JOURNAL_IMG" ]] && ! has_journal "$JOURNAL_IMG"; then
  pass "default creates the image without a journal"
else
  fail "default image: status=$rc journal=$(has_journal "$JOURNAL_IMG" && echo yes || echo no) output=$out"
fi

# The image already exists, so the setting changes nothing on disk — it only
# earns a NOTE naming the command to convert it.
run_journal_mount true
if (( rc == 0 )) \
    && grep -q "\[NOTE\] $JOURNAL_IMG has no ext4 journal but SHARED_FOLDER_JOURNAL=true" <<<"$out" \
    && grep -q "run 'migrant unmount', 'e2fsck -f $JOURNAL_IMG', then 'tune2fs -O has_journal $JOURNAL_IMG'" <<<"$out"; then
  pass "an existing journal-less image with SHARED_FOLDER_JOURNAL=true gets a NOTE"
else
  fail "no-journal mismatch note: status=$rc output=$out"
fi
if has_journal "$JOURNAL_IMG"; then
  fail "SHARED_FOLDER_JOURNAL=true modified an existing image"
else
  pass "SHARED_FOLDER_JOURNAL=true leaves an existing image untouched"
fi

# Control: the config must actually withhold the journal from a plain mkfs,
# or the case after it proves nothing.
rm -f "$JOURNAL_IMG"
truncate -s 64M "$JOURNAL_IMG"
if ! MKE2FS_CONFIG="$NOJOURNAL_CONF" mkfs.ext4 -F -q "$JOURNAL_IMG" >/dev/null 2>&1; then
  fail "control: mkfs.ext4 with the no-journal mke2fs.conf failed"
elif ! sb=$(LC_ALL=C dumpe2fs -h "$JOURNAL_IMG" 2>&1); then
  fail "control: dumpe2fs could not read the superblock it just created: $sb"
elif grep -qE '^Filesystem features:.* has_journal( |$)' <<<"$sb"; then
  fail "control: the no-journal mke2fs.conf still produced a journal"
else
  pass "control: the no-journal mke2fs.conf withholds the journal from a plain mkfs"
fi

rm -f "$JOURNAL_IMG"
run_journal_mount true "$NOJOURNAL_CONF"
if (( rc == 0 )) && [[ -f "$JOURNAL_IMG" ]] && has_journal "$JOURNAL_IMG"; then
  pass "SHARED_FOLDER_JOURNAL=true creates the image with a journal, even when mke2fs.conf omits it"
else
  fail "journaled image: status=$rc journal=$(has_journal "$JOURNAL_IMG" && echo yes || echo no) output=$out"
fi
if grep -q "\[NOTE\].*journal" <<<"$out"; then
  fail "a freshly created image matching the setting got a journal NOTE: $out"
else
  pass "no journal NOTE when the image matches the setting"
fi

run_journal_mount ""
if (( rc == 0 )) \
    && grep -q "\[NOTE\] $JOURNAL_IMG has an ext4 journal but SHARED_FOLDER_JOURNAL is not true" <<<"$out" \
    && grep -q "run 'migrant unmount', 'e2fsck -f $JOURNAL_IMG', then 'tune2fs -O ^has_journal $JOURNAL_IMG'" <<<"$out"; then
  pass "an existing journaled image with the default setting gets a NOTE"
else
  fail "journal mismatch note: status=$rc output=$out"
fi

# The probe is advisory: when it gets no answer there must be no NOTE under
# either setting. Each case runs under both, so a probe that falls back to
# either answer prints a NOTE in one of them.
#
# Unreadable here means an image with no ext4 superblock. debugfs fails on it
# exactly as on a permission-denied image — exit 0, no features line — and
# unlike mode 000 that holds for root too.
#
# For the missing debugfs case the image is real ext4 whose journal state
# contradicts the setting, so a probe that read it anyway would print a NOTE.
for journal in true ""; do
  setting="${journal:-default}"

  rm -f "$JOURNAL_IMG"
  truncate -s 1G "$JOURNAL_IMG"
  run_journal_mount "$journal"
  if (( rc == 0 )) && ! grep -q "\[NOTE\].*journal" <<<"$out"; then
    pass "an unreadable image gets no journal NOTE ($setting setting)"
  else
    fail "unreadable image, $setting setting: status=$rc output=$out"
  fi

  if [[ "$journal" == true ]]; then
    mkfs.ext4 -F -q -O ^has_journal "$JOURNAL_IMG" >/dev/null 2>&1
  else
    mkfs.ext4 -F -q -O has_journal "$JOURNAL_IMG" >/dev/null 2>&1
  fi
  cat > "$WORK/fakebin/debugfs" <<'WRAP'
#!/usr/bin/env bash
exit 127
WRAP
  chmod +x "$WORK/fakebin/debugfs"
  run_journal_mount "$journal"
  rm -f "$WORK/fakebin/debugfs"
  if (( rc == 0 )) && ! grep -q "\[NOTE\].*journal" <<<"$out"; then
    pass "a missing debugfs gets no journal NOTE ($setting setting)"
  else
    fail "missing debugfs, $setting setting: status=$rc output=$out"
  fi
done

rm -f "$JOURNAL_IMG"

# 'mount' returns early when isolation is off or no share is configured. The
# journal setting must be checked ahead of both, as 'up' checks it, or the same
# Migrantfile is an error on one command and silently accepted on the other.
cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
SHARED_FOLDERS=("journal:journal")
SHARED_FOLDER_ISOLATION=false
SHARED_FOLDER_JOURNAL=true
EOF
set +e
out=$(PATH="$WORK/fakebin:$PATH" "$MIGRANT" mount 2>&1); rc=$?
set -e
if grep -q "\[ERROR\] SHARED_FOLDER_JOURNAL=true but SHARED_FOLDER_ISOLATION=false" <<<"$out" \
    && (( rc == 65 )); then
  pass "mount rejects SHARED_FOLDER_JOURNAL=true with SHARED_FOLDER_ISOLATION=false"
else
  fail "mount, journal + SHARED_FOLDER_ISOLATION=false: status=$rc output=$out"
fi

cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
SHARED_FOLDER_ISOLATION=false
SHARED_FOLDER_JOURNAL=true
EOF
set +e
out=$(PATH="$WORK/fakebin:$PATH" "$MIGRANT" mount 2>&1); rc=$?
set -e
if grep -q "\[ERROR\] SHARED_FOLDER_JOURNAL=true but SHARED_FOLDER_ISOLATION=false" <<<"$out" \
    && (( rc == 65 )); then
  pass "mount rejects SHARED_FOLDER_JOURNAL=true with SHARED_FOLDER_ISOLATION=false and no shares"
else
  fail "mount, journal + SHARED_FOLDER_ISOLATION=false, no shares: status=$rc output=$out"
fi
rmdir "$JOURNAL_WS" 2>/dev/null || true
rm -rf "$WORK"
WORK=""

reset_migrantfile

# ============================================================
# Part 1: the loop image is mounted, recorded, and torn down
# ============================================================

echo "--- test: mounted and recorded on up ---"
"$MIGRANT" up

if mountpoint -q "$WS" 2>/dev/null; then
  pass "workspace is a mount point while the VM runs"
else
  fail "workspace is not mounted"
fi

# nosymfollow is half of what isolation buys; a mount without it is not the
# protection the README describes.
if findmnt -no OPTIONS "$WS" 2>/dev/null | grep -q nosymfollow; then
  pass "mounted with nosymfollow"
else
  fail "mounted without nosymfollow: $(findmnt -no OPTIONS "$WS" 2>/dev/null)"
fi

if [[ "$(backing_of "$WS" 2>/dev/null || true)" == "$IMG" ]]; then
  pass "workspace is backed by $IMG"
else
  fail "workspace is backed by '$(backing_of "$WS" 2>/dev/null || true)', expected $IMG"
fi

# Part 0b covers this through 'mount'; this is the 'up' path itself.
if has_journal "$IMG"; then
  fail "up created $IMG with a journal though SHARED_FOLDER_JOURNAL is unset"
else
  pass "up creates $IMG without a journal by default"
fi

if [[ -f "$RECORD" ]]; then
  pass "loop hook wrote $RECORD"
else
  fail "loop hook wrote no mount record"
fi

if grep -qx "$(printf '%s\t%s' "$WS" "$IMG")" "$RECORD" 2>/dev/null; then
  pass "record names the workspace mount and its image"
else
  fail "record does not name $WS"
  cat "$RECORD" 2>/dev/null || true
fi

"$MIGRANT" halt

if mountpoint -q "$WS" 2>/dev/null; then
  fail "workspace still mounted after halt"
else
  pass "workspace unmounted after halt"
fi

if [[ -f "$RECORD" ]]; then
  fail "mount record survived halt"
else
  pass "mount record removed on halt"
fi

# ============================================================
# Part 1b: a per-entry size override is independent of the global default
# ============================================================
# Two shares in the same Migrantfile, only one with an override, so a bug
# that applied the override to every entry (or the default to the
# overridden one) shows up as an equal, not merely wrong, image size.

echo "--- test: per-entry size override ---"

cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
SHARED_FOLDERS=(
  "workspace:workspace"
  "sized:sized:2"
)
SHARED_FOLDER_SIZE_GB=1
EOF

# Part 1 left the domain defined (only halted), and --filesystem args are
# only added to a domain at virt-install time, on first create — the same
# reason Part 4 destroys before adding its extra-args filesystem. Without
# this, 'up' just restarts the existing (workspace-only) domain and 'sized'
# is never attached, though its image still gets created on disk regardless.
"$MIGRANT" destroy 2>/dev/null || true
"$MIGRANT" up

img_size_gb() { du --apparent-size -b "$1" | cut -f1 | awk '{ print $1 / 1024 / 1024 / 1024 }'; }

if [[ "$(img_size_gb "$IMG")" == "1" ]]; then
  pass "workspace.img stays at the global default (1G)"
else
  fail "workspace.img is $(img_size_gb "$IMG")G, expected 1G"
fi

if [[ "$(img_size_gb "$SIZED_IMG")" == "2" ]]; then
  pass "sized.img uses its own per-entry size (2G), not the global default"
else
  fail "sized.img is $(img_size_gb "$SIZED_IMG")G, expected 2G"
fi

if mountpoint -q "$SIZED_WS" 2>/dev/null; then
  pass "sized share is mounted alongside workspace"
else
  fail "sized share is not mounted"
fi

# The loop hook mounts by matching <source dir>, never <target dir>, so the
# mount succeeding above proves nothing about guest_tag parsing. Only the
# domain XML shows whether the third field leaked into the tag — the bug
# fixed alongside per-entry sizing had "sized:sized:2" registering a
# virtiofs target of "2" instead of "sized".
if virsh dumpxml --inactive "$VM_NAME" 2>/dev/null \
    | grep -A2 "<source dir='$SIZED_WS'/>" \
    | grep -q "<target dir='sized'/>"; then
  pass "guest_tag for a 3-field entry is the middle field, not the size"
else
  fail "domain XML target for $SIZED_WS is not 'sized': $(virsh dumpxml --inactive "$VM_NAME" 2>/dev/null | grep -B2 -A2 "$SIZED_WS")"
fi

if grep -qx "$(printf '%s\t%s' "$SIZED_WS" "$SIZED_IMG")" "$RECORD" 2>/dev/null; then
  pass "record names the sized share alongside workspace"
else
  fail "record does not name $SIZED_WS"
  cat "$RECORD" 2>/dev/null || true
fi

"$MIGRANT" halt

if mountpoint -q "$WS" 2>/dev/null || mountpoint -q "$SIZED_WS" 2>/dev/null; then
  fail "a share is still mounted after halt with two shares configured"
else
  pass "both shares unmounted after halt"
fi

if [[ -f "$RECORD" ]]; then
  fail "mount record survived halt with two shares configured"
else
  pass "mount record removed after halt with two shares configured"
fi

"$MIGRANT" destroy
rm -f "$SIZED_IMG"
rmdir "$SIZED_WS" 2>/dev/null || true
reset_migrantfile

# ============================================================
# Part 1c: a failed image allocation leaves nothing behind
# ============================================================
# truncate can still fail for real reasons even once SHARED_FOLDERS values
# are validated — disk full, EFBIG, permissions. A directory sitting at the
# image path forces that failure deterministically, without depending on
# host filesystem size limits. mkfs.ext4 failure already had rm-on-failure
# cleanup; truncate's failure didn't, and a leftover empty image from a
# crash confuses every later 'up' with a false size-drift NOTE instead of
# a clean error — which is exactly what happened testing this feature.

echo "--- test: failed image allocation is cleaned up ---"

rm -f "$IMG"
mkdir "$IMG"
set +e
out=$("$MIGRANT" up 2>&1); rc=$?
set -e
if grep -q "\[ERROR\] failed to allocate $IMG at 1G" <<<"$out" && (( rc == 74 )); then
  pass "a truncate failure is reported with exit 74"
else
  fail "truncate failure: status=$rc output=$out"
fi

if [[ -d "$IMG" ]]; then
  pass "the directory blocking the image path is untouched (not silently deleted)"
else
  fail "\$IMG was removed even though it was never a file this code created"
fi

if [[ "$(virsh domstate "$VM_NAME" 2>/dev/null || true)" == "running" ]]; then
  fail "VM is running despite a failed shared folder image allocation"
  "$MIGRANT" halt
else
  pass "VM is not running after a failed image allocation"
fi

rmdir "$IMG"
reset_migrantfile

# ============================================================
# Part 2: an unmountable image refuses to start
# ============================================================

echo "--- test: unmountable image refuses to start ---"

# Replace the image with a same-sized file that holds no filesystem, so
# ensure_shared_folder_images leaves it alone and the mount is what fails.
# Overwriting in place is not enough: the loop device from the previous mount
# detaches asynchronously, and mount reuses a live binding for the same inode
# along with its cached superblock. A new inode cannot be matched that way.
rm -f "$IMG"
truncate -s "${SHARED_FOLDER_SIZE_GB:-1}G" "$IMG"

mark=$(log_mark)
if "$MIGRANT" up >/dev/null 2>&1; then
  fail "VM started despite an unmountable shared folder image"
else
  pass "up refused with an unmountable image"
fi

if [[ "$(virsh domstate "$VM_NAME" 2>/dev/null || true)" == "running" ]]; then
  fail "VM is running after the mount failure"
  "$MIGRANT" halt
else
  pass "VM is not running after the mount failure"
fi

if log_since "$mark" | grep -q "failed to mount $IMG"; then
  pass "hook log names the mount failure"
else
  fail "hook log does not name the mount failure"
fi

# Removing it lets ensure_shared_folder_images build a fresh one on the next up.
rm -f "$IMG"

# ============================================================
# Part 3: a mount from somewhere else refuses to start
# ============================================================

echo "--- test: foreign mount at the workspace refuses to start ---"

mkdir -p "$WS"
sudo mount -t tmpfs -o size=1M none "$WS"
DECOY_MOUNTED=true

mark=$(log_mark)
if "$MIGRANT" up >/dev/null 2>&1; then
  fail "VM started with the workspace backed by an unrelated mount"
else
  pass "up refused a workspace backed by an unrelated mount"
fi

if log_since "$mark" | grep -q "is mounted from"; then
  pass "hook log names the wrong backing source"
else
  fail "hook log does not explain the refusal"
fi

# Releasing the domain after the aborted start runs the hook's unmount path,
# which umounts whatever sits at the source dir — the decoy included.
if mountpoint -q "$WS" 2>/dev/null; then
  sudo umount "$WS"
fi
DECOY_MOUNTED=false

# ============================================================
# Part 4: a filesystem migrant does not know about is still verified
# ============================================================

echo "--- test: extra-args filesystem is recorded and verified ---"

# SHARED_FOLDERS names only the workspace. This second virtiofs mount reaches
# the domain through .virt-install-extra-args, so anything driving off the
# Migrantfile cannot see it — which is why verification reads the record.
mkdir -p "$EXTRA_WS"
truncate -s 256M "$EXTRA_IMG"
mkfs.ext4 -F -q -E root_owner -O ^has_journal,^resize_inode "$EXTRA_IMG"

mkdir -p "$HOOKS_DIR"
if [[ -f "$TEST_HOOK" ]]; then
  TEST_HOOK_BACKUP="$TEST_HOOK.test-shared-folder.bak"
  mv "$TEST_HOOK" "$TEST_HOOK_BACKUP"
fi
cat > "$TEST_HOOK" <<HOOKEOF
#!/usr/bin/env bash
set -euo pipefail
cat > "\$MIGRANT_VM_DIR/.virt-install-extra-args" <<ARGS
--filesystem
source=$EXTRA_WS,target=extrafs,driver.type=virtiofs
ARGS
HOOKEOF
chmod +x "$TEST_HOOK"

# extra-args are read only on the first-create path.
"$MIGRANT" destroy 2>/dev/null || true
"$MIGRANT" up

if grep -qx "$(printf '%s\t%s' "$EXTRA_WS" "$EXTRA_IMG")" "$RECORD" 2>/dev/null; then
  pass "record includes the extra-args filesystem"
else
  fail "record omits $EXTRA_WS — verification would never check it"
  cat "$RECORD" 2>/dev/null || true
fi

if mountpoint -q "$EXTRA_WS" 2>/dev/null; then
  pass "extra-args filesystem is mounted from its own image"
else
  fail "extra-args filesystem is not mounted"
fi

"$MIGRANT" halt
"$MIGRANT" destroy

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  exit 1
fi
