#!/usr/bin/env bash
set -euo pipefail
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Integration test for shared folder isolation. The contract is that the guest
# is never served the bare host directory: if the loop image is missing, fails
# to mount, or the mount point is backed by something else, the VM must refuse
# to start rather than run without nosymfollow and the size cap.
#
# Run from a VM directory that has a working Migrantfile + cloud-init.yml:
#   cd examples/arch && ../../test/test-shared-folder.sh
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
EXTRA_WS="$PWD/extrafs"
EXTRA_IMG="$PWD/extrafs.img"
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
  rm -f "$EXTRA_IMG"
  rmdir "$EXTRA_WS" 2>/dev/null || true
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

cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
SHARED_FOLDERS=("workspace:workspace")
SHARED_FOLDER_SIZE_GB=1
EOF

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
