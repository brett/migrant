#!/usr/bin/env bash
set -euo pipefail
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Integration test for 'migrant snapshot' and 'migrant reset' — current
# (default-path-only) behavior, as a baseline before the optional path
# argument is added to either subcommand. Run from anywhere:
#   test/test-snapshot.sh
#
# No real VM boot: domains are defined straight from XML the way
# test-resources.sh does, with a real disk file attached so 'snapshot's
# qemu-img convert has content to act on. virt-install is shadowed on PATH
# for the reset-rebuild leg (same technique as
# test-managed-key-placeholder.sh), so reset never boots a real VM either.
#
# Prerequisites:
#   - libvirt reachable at qemu:///system
#   - No domain named "migrant-snapshot-test" exists

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"
VM="migrant-snapshot-test"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

if virsh dominfo "$VM" &>/dev/null; then
  echo "[FAIL] domain '$VM' already exists; remove it first." >&2
  exit 1
fi

# qemu runs under its own uid, which needs to traverse into $WORK — force the
# scratch dir under /tmp itself (mode 1777) rather than trusting $TMPDIR, which
# may point at a private per-user directory (e.g. mode 0700) no chmod of ours
# below it can work around.
WORK=$(TMPDIR=/tmp mktemp -d)
cleanup() {
  virsh destroy "$VM" &>/dev/null || true
  virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

cd "$WORK"
# qemu runs as its own unprivileged user, which needs to traverse into $WORK
# and read/write the disk file directly — mktemp's default 0700 blocks that,
# unlike /var/lib/libvirt/images, which already has the right ownership.
chmod 711 "$WORK"
IMAGES_DIR="$WORK/images"
mkdir -p "$IMAGES_DIR" fakebin
chmod 755 "$IMAGES_DIR"
DISK_PATH="$IMAGES_DIR/${VM}.qcow2"
SNAPSHOT_PATH="$IMAGES_DIR/${VM}-snapshot.qcow2"

cat > cloud-init.yml <<'EOF'
users:
  - name: migrant
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY test@example
EOF

cat > Migrantfile <<EOF
VM_NAME="$VM"
OS_VARIANT="generic"
RAM_MB=512
VCPUS=1
DISK_GB=1
IMAGE_URL="https://example.invalid/x.qcow2"
SHARED_FOLDERS=()
SHARED_FOLDER_ISOLATION=false
NETWORK_ISOLATION=false
NETWORKS=(
  "network=migrant"
)
EOF

OUT=""
STATUS=0
# Pass --timeout N before the migrant subcommand to override the default 25s
# (e.g. a call with no way to succeed, bounded only to outlast startup on a
# slow box). A PATH override to shadow virt-install, if needed, works
# unmodified as a caller-side prefix — 'PATH=... run_migrant ...' — since a
# temporary environment assignment on a function call propagates to any
# external command the function goes on to invoke.
run_migrant() {
  local timeout_s=25
  if [[ "${1:-}" == --timeout ]]; then
    timeout_s="$2"
    shift 2
  fi
  set +e
  LIBVIRT_IMAGES_DIR="$IMAGES_DIR" timeout "$timeout_s" "$MIGRANT" "$@" > out.log 2>&1
  STATUS=$?
  set -e
  OUT=$(cat out.log)
}

# --- disk fixture: a small qcow2 whose raw content is a known marker ----------
# Built via 'qemu-img convert' from raw bytes rather than through a booted
# guest — a stand-in for guest writes that gives the image real,
# distinguishable content a byte-for-byte extraction can verify survived
# 'snapshot's own conversion step.
head -c 65536 /dev/urandom > marker.bin

# Scratch paths are $WORK-anchored, not CWD-relative: archive/restore
# scenarios call this from inside a VM directory.
# Usage: extracted_matches_marker IMAGE [MARKER]   (MARKER defaults to marker.bin)
extracted_matches_marker() {
  local marker="${2:-$WORK/marker.bin}"
  qemu-img convert -O raw "$1" "$WORK/extracted.raw"
  # Only the marker's own length is compared: an image rebuilt by 'up' is sized
  # to DISK_GB, so its raw form is far larger than the marker written into it.
  head -c "$(stat -c %s "$marker")" "$WORK/extracted.raw" | cmp -s "$marker" -
}

# Domain: a real disk backed by the marker content, no boot media. QEMU has no
# bootable device and just idles in the guest BIOS, but the process stays
# "running" — the same trick test-resources.sh uses for a diskless domain.
define_domain() {
  virsh destroy "$VM" &>/dev/null || true
  virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
  qemu-img convert -f raw -O qcow2 "$WORK/marker.bin" "$DISK_PATH"
  chmod 666 "$DISK_PATH"
  cat > "$WORK/dom.xml" <<EOF
<domain type='kvm'>
  <name>$VM</name>
  <memory unit='KiB'>524288</memory>
  <currentMemory unit='KiB'>524288</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$DISK_PATH'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <console type='pty'/>
  </devices>
</domain>
EOF
  virsh define "$WORK/dom.xml" > /dev/null
}

# Domain: define_domain's marker-backed disk plus one NIC with a known MAC —
# archive/restore scenarios need both a snapshot to verify content on and a
# MAC to verify capture of, together.
define_domain_with_mac() {
  local mac="$1"
  virsh destroy "$VM" &>/dev/null || true
  virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
  qemu-img convert -f raw -O qcow2 "$WORK/marker.bin" "$DISK_PATH"
  chmod 666 "$DISK_PATH"
  cat > "$WORK/dom-archive.xml" <<EOF
<domain type='kvm'>
  <name>$VM</name>
  <memory unit='KiB'>524288</memory>
  <currentMemory unit='KiB'>524288</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$DISK_PATH'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='ethernet'>
      <mac address='$mac'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'/>
  </devices>
</domain>
EOF
  virsh define "$WORK/dom-archive.xml" > /dev/null
  virsh start "$VM" > /dev/null
}

# --- 1. snapshot from a shut-off VM converts directly --------------------------
define_domain
run_migrant snapshot
if (( STATUS == 0 )) && ! grep -q "Shutting down" <<<"$OUT" \
    && grep -q "Snapshot saved: $SNAPSHOT_PATH" <<<"$OUT" \
    && grep -q "Run 'migrant reset' to rebuild the VM from this snapshot." <<<"$OUT"; then
  pass "snapshot from a shut-off VM converts directly, no shutdown message"
else
  fail "snapshot from shut-off VM: status=$STATUS output=$OUT"
fi
if [[ -f "$SNAPSHOT_PATH" ]] && extracted_matches_marker "$SNAPSHOT_PATH"; then
  pass "snapshot content matches the VM disk"
else
  fail "snapshot content mismatch or missing file"
fi

# --- 2. re-running snapshot warns about overwriting -----------------------------
run_migrant snapshot
if (( STATUS == 0 )) && grep -q "Overwriting existing snapshot." <<<"$OUT"; then
  pass "re-running snapshot warns about overwriting"
else
  fail "overwrite warning missing: status=$STATUS output=$OUT"
fi

# --- 3. snapshot from a running VM shuts it down first --------------------------
# virsh is shadowed so 'shutdown' maps to an immediate 'destroy': there is no
# real guest OS to respond to the ACPI request, and the point of this case is
# proving cmd_snapshot takes the graceful-shutdown branch, not exercising a
# real guest shutdown (that's covered by the shared 'up'/'halt' hook tests).
rm -f "$SNAPSHOT_PATH"
define_domain
virsh start "$VM" > /dev/null

cat > fakebin/virsh <<'WRAP'
#!/usr/bin/env bash
if [[ "$1" == "shutdown" ]]; then
  exec /usr/bin/virsh destroy "$2"
fi
exec /usr/bin/virsh "$@"
WRAP
chmod +x fakebin/virsh

PATH="$WORK/fakebin:$PATH" run_migrant snapshot

if (( STATUS == 0 )) && grep -q "Shutting down '$VM' for snapshot" <<<"$OUT"; then
  pass "snapshot from a running VM shuts it down first"
else
  fail "running VM snapshot: status=$STATUS output=$OUT"
fi
if [[ "$(virsh domstate "$VM")" == "shut off" ]]; then
  pass "VM is shut off after a running-state snapshot"
else
  fail "VM left in state $(virsh domstate "$VM") after snapshot"
fi
if extracted_matches_marker "$SNAPSHOT_PATH"; then
  pass "snapshot content matches after graceful shutdown"
else
  fail "snapshot content mismatch after graceful shutdown"
fi
rm -f fakebin/virsh

# --- 4. snapshot refuses a VM in an unexpected state ----------------------------
rm -f "$SNAPSHOT_PATH"
define_domain
virsh start "$VM" > /dev/null
virsh suspend "$VM" > /dev/null
run_migrant snapshot
if (( STATUS == 1 )) && grep -q "\[ERROR\] VM '$VM' is in state 'paused'" <<<"$OUT" \
    && grep -q "Halt it before snapshotting." <<<"$OUT"; then
  pass "snapshot refuses a paused VM with exit 1"
else
  fail "paused VM snapshot: status=$STATUS output=$OUT"
fi
if [[ -f "$SNAPSHOT_PATH" ]]; then
  fail "snapshot file was created despite the paused-state error"
else
  pass "no snapshot file created for a paused VM"
fi
virsh destroy "$VM" &>/dev/null || true

# --- 5. snapshot refuses when the VM does not exist -----------------------------
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
run_migrant snapshot
if (( STATUS == 1 )) && grep -q "has not been created" <<<"$OUT"; then
  pass "snapshot refuses when the VM does not exist"
else
  fail "snapshot with no VM: status=$STATUS output=$OUT"
fi

# --- 6. reset refuses when no snapshot exists -----------------------------------
rm -f "$SNAPSHOT_PATH"
run_migrant reset
if (( STATUS == 1 )) && grep -q "no snapshot found for '$VM'" <<<"$OUT" \
    && grep -q "Run 'migrant snapshot' to create one." <<<"$OUT"; then
  pass "reset refuses when no snapshot exists"
else
  fail "reset with no snapshot: status=$STATUS output=$OUT"
fi

# --- 7. reset preserves MAC addresses and rebuilds from the snapshot ------------
qemu-img create -f qcow2 "$SNAPSHOT_PATH" 10M > /dev/null

cat > dom-mac.xml <<EOF
<domain type='kvm'>
  <name>$VM</name>
  <memory unit='KiB'>524288</memory>
  <currentMemory unit='KiB'>524288</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <devices>
    <interface type='ethernet'>
      <mac address='52:54:00:aa:bb:cc'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'/>
  </devices>
</domain>
EOF
virsh define dom-mac.xml > /dev/null
virsh start "$VM" > /dev/null

cat > fakebin/virt-install <<WRAP
#!/usr/bin/env bash
echo "\$@" > "$WORK/virt-install.args"
echo "fake virt-install invoked" >&2
exit 1
WRAP
chmod +x fakebin/virt-install

PATH="$WORK/fakebin:$PATH" run_migrant reset

if grep -q "Using snapshot: $SNAPSHOT_PATH" <<<"$OUT"; then
  pass "reset rebuilds from the default snapshot path"
else
  fail "reset did not report using the snapshot: $OUT"
fi
if grep -q "fake virt-install invoked" <<<"$OUT"; then
  pass "reset reached virt-install (rebuild path completed)"
else
  fail "reset did not reach virt-install: status=$STATUS output=$OUT"
fi
if grep -qF -- "--network network=migrant,mac=52:54:00:aa:bb:cc" "$WORK/virt-install.args" 2>/dev/null; then
  pass "reset preserves the old domain's MAC address"
else
  fail "MAC not preserved: $(cat "$WORK/virt-install.args" 2>/dev/null || echo missing)"
fi
if [[ -f "$DISK_PATH" ]] && qemu-img info "$DISK_PATH" | grep -q "backing file: $SNAPSHOT_PATH"; then
  pass "rebuilt disk is backed by the snapshot"
else
  fail "rebuilt disk backing file wrong: $(qemu-img info "$DISK_PATH" 2>&1 || true)"
fi
rm -f "$DISK_PATH" "$WORK/virt-install.args"

# --- 8. reset still rebuilds when the old domain is already gone ---------------
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true

PATH="$WORK/fakebin:$PATH" run_migrant reset

if grep -q "\[WARNING\] VM '$VM' domain not found; MAC addresses cannot be preserved." <<<"$OUT"; then
  pass "reset warns when the old domain is gone"
else
  fail "missing domain-not-found warning: $OUT"
fi
if grep -q "fake virt-install invoked" <<<"$OUT"; then
  pass "reset still rebuilds when the old domain is gone"
else
  fail "reset did not rebuild without the old domain: $OUT"
fi

# --- 8b. reset honors a caller-supplied _MIGRANT_RESET_MACS when the old domain
#         is gone, instead of clobbering it with an empty value (regression for
#         the cross-host restore case, where there's never a local domain to
#         source MACs from) -----------------------------------------------------
PATH="$WORK/fakebin:$PATH" _MIGRANT_RESET_MACS="52:54:00:de:ad:be" run_migrant reset

if grep -q "\[WARNING\] VM '$VM' domain not found; MAC addresses cannot be preserved." <<<"$OUT"; then
  fail "reset warned about MAC loss despite a caller-supplied _MIGRANT_RESET_MACS: $OUT"
else
  pass "reset does not warn when the caller already supplied _MIGRANT_RESET_MACS"
fi
if grep -qF -- "--network network=migrant,mac=52:54:00:de:ad:be" "$WORK/virt-install.args" 2>/dev/null; then
  pass "reset honors a caller-supplied _MIGRANT_RESET_MACS when the old domain is gone"
else
  fail "caller-supplied MAC not honored: $(cat "$WORK/virt-install.args" 2>/dev/null || echo missing)"
fi
rm -f "$DISK_PATH" "$WORK/virt-install.args"

# --- 9. snapshot writes to a given full path ------------------------------------
# The default path may still hold scenario 7's leftover stub snapshot; clear it
# so "custom path leaves the default alone" checks scenario 9's own behavior,
# not stale state from an earlier scenario.
rm -f "$SNAPSHOT_PATH"
define_domain
EXT_DIR="$WORK/external"
mkdir -p "$EXT_DIR"
CUSTOM_SNAP="$EXT_DIR/pre-risky-change.qcow2"
run_migrant snapshot "$CUSTOM_SNAP"
if (( STATUS == 0 )) && grep -q "Snapshot saved: $CUSTOM_SNAP" <<<"$OUT" \
    && grep -qF "Run 'migrant reset $CUSTOM_SNAP' to rebuild the VM from this snapshot." <<<"$OUT"; then
  pass "snapshot writes to a given full path"
else
  fail "snapshot with custom path: status=$STATUS output=$OUT"
fi
if [[ -f "$CUSTOM_SNAP" ]] && extracted_matches_marker "$CUSTOM_SNAP"; then
  pass "custom-path snapshot content matches the VM disk"
else
  fail "custom-path snapshot content mismatch or missing file"
fi
if [[ -f "$SNAPSHOT_PATH" ]]; then
  fail "snapshot also wrote to the default path when a custom path was given"
else
  pass "snapshot does not touch the default path when a custom path is given"
fi

# --- 10. snapshot builds its own filename when given a directory ---------------
rm -f "$CUSTOM_SNAP"
run_migrant snapshot "$EXT_DIR"
if (( STATUS != 0 )); then
  fail "snapshot to a directory failed: status=$STATUS output=$OUT"
else
  built_name=$(find "$EXT_DIR" -maxdepth 1 -type f -name "${VM}-snapshot-*.qcow2" -printf '%f\n')
  if [[ "$built_name" =~ ^${VM}-snapshot-[0-9]{8}-[0-9]{6}\.qcow2$ ]]; then
    pass "snapshot to a directory builds a timestamped filename"
  else
    fail "unexpected filename in directory: '$built_name' (output: $OUT)"
  fi
  if [[ -n "$built_name" ]] && extracted_matches_marker "$EXT_DIR/$built_name"; then
    pass "directory-target snapshot content matches the VM disk"
  else
    fail "directory-target snapshot content mismatch"
  fi
fi

# --- 11. snapshot refuses a nonexistent output directory, VM left untouched ----
virsh start "$VM" > /dev/null 2>&1 || true
run_migrant snapshot "$WORK/does-not-exist/out.qcow2"
if (( STATUS == 73 )); then
  pass "snapshot refuses a nonexistent output directory with exit 73"
else
  fail "snapshot to a missing dir: status=$STATUS output=$OUT"
fi
if [[ "$(virsh domstate "$VM")" == "running" ]]; then
  pass "a rejected output path leaves a running VM untouched"
else
  fail "VM state changed despite the path being rejected: $(virsh domstate "$VM")"
fi
virsh destroy "$VM" &>/dev/null || true

# --- 12. snapshot refuses a non-writable output directory -----------------------
READONLY_DIR="$WORK/readonly"
mkdir -p "$READONLY_DIR"
chmod 555 "$READONLY_DIR"
run_migrant snapshot "$READONLY_DIR/out.qcow2"
if (( STATUS == 73 )); then
  pass "snapshot refuses a non-writable output directory with exit 73"
else
  fail "snapshot to a read-only dir: status=$STATUS output=$OUT"
fi
chmod 755 "$READONLY_DIR"

# --- 12b. snapshot refuses a trailing-slash path that is not a directory -------
# A trailing slash means the caller meant a directory. With that intent not
# recorded, the path was taken as a full filename, 'dirname' stripped it back to
# a writable parent, the check passed, and qemu-img failed with 'Is a directory'
# — by which point the VM had already been shut down. 'archive' guards this.
virsh start "$VM" > /dev/null 2>&1 || true
run_migrant snapshot "$WORK/no-such-snapshot-dir/"
if (( STATUS == 73 )) && grep -qF "directory does not exist" <<<"$OUT"; then
  pass "snapshot rejects a trailing-slash path that is not a directory"
else
  fail "snapshot did not reject a trailing-slash non-directory: status=$STATUS output=$OUT"
fi
if [[ ! -e "$WORK/no-such-snapshot-dir" ]]; then
  pass "snapshot created no file for the rejected trailing-slash path"
else
  fail "snapshot created '$WORK/no-such-snapshot-dir' instead of refusing"
fi
if [[ "$(virsh domstate "$VM")" == "running" ]]; then
  pass "a rejected trailing-slash path leaves a running VM untouched"
else
  fail "VM state changed despite the trailing-slash path being rejected: $(virsh domstate "$VM")"
fi
virsh destroy "$VM" &>/dev/null || true

# --- 12c. snapshot and reset expand a quoted '~' in their path argument --------
# The shell expands a bare '~' itself but not one the caller quoted, so both
# route their argument through expand_home, as 'archive' already did.
FAKE_HOME="$WORK/fakehome"
mkdir -p "$FAKE_HOME/snaps"
define_domain
# SC2088: the quoting is the point — an unexpanded '~' reaching the subcommand
# is exactly what expand_home has to handle, so $HOME here would test nothing.
# shellcheck disable=SC2088
HOME="$FAKE_HOME" run_migrant snapshot '~/snaps'
TILDE_SNAP=$(find "$FAKE_HOME/snaps" -maxdepth 1 -type f \
  -name "${VM}-snapshot-*.qcow2" | head -1)
if (( STATUS == 0 )) && [[ -n "$TILDE_SNAP" ]]; then
  pass "snapshot expands a quoted '~' in its path argument"
else
  fail "snapshot did not expand '~': status=$STATUS output=$OUT"
fi
# shellcheck disable=SC2088  # quoted deliberately, as above
HOME="$FAKE_HOME" run_migrant reset '~/snaps/no-such-file.qcow2'
if (( STATUS == 1 )) && grep -qF "$FAKE_HOME/snaps/no-such-file.qcow2" <<<"$OUT"; then
  pass "reset expands a quoted '~' in its path argument"
else
  fail "reset did not expand '~': status=$STATUS output=$OUT"
fi
rm -rf "$FAKE_HOME"
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH" "$SNAPSHOT_PATH"

# --- 13. reset rebuilds from a given path, ignoring the default snapshot -------
qemu-img create -f qcow2 "$SNAPSHOT_PATH" 10M > /dev/null
EXT_SNAP="$EXT_DIR/checkpoint.qcow2"
qemu-img create -f qcow2 "$EXT_SNAP" 10M > /dev/null

virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true

PATH="$WORK/fakebin:$PATH" run_migrant reset "$EXT_SNAP"

if grep -q "Using snapshot: $EXT_SNAP" <<<"$OUT"; then
  pass "reset with a given path reports using that snapshot"
else
  fail "reset custom path did not report using it: $OUT"
fi
if grep -q "fake virt-install invoked" <<<"$OUT"; then
  pass "reset with a given path reaches virt-install"
else
  fail "reset custom path did not reach virt-install: status=$STATUS output=$OUT"
fi
if [[ -f "$DISK_PATH" ]] && qemu-img info "$DISK_PATH" | grep -q "backing file: $EXT_SNAP"; then
  pass "reset with a given path rebuilds backed by that snapshot, not the default"
else
  fail "reset custom path backing file wrong: $(qemu-img info "$DISK_PATH" 2>&1 || true)"
fi
rm -f "$DISK_PATH"

# --- 14. reset refuses when the given path does not exist ----------------------
run_migrant reset "$WORK/no-such-snapshot.qcow2"
if (( STATUS == 1 )) && grep -q "no snapshot found" <<<"$OUT" \
    && grep -qF "$WORK/no-such-snapshot.qcow2" <<<"$OUT"; then
  pass "reset refuses when the given snapshot path does not exist"
else
  fail "reset with missing custom path: status=$STATUS output=$OUT"
fi

# --- 15. 'up' does not flag a custom-snapshot VM as base-image drift -----------
# The base-image drift check on an existing domain used to tolerate only the
# Migrantfile's base image or the default snapshot's basename. A VM 'reset'
# from an arbitrarily named/located snapshot would falsely trip it on the next
# plain 'up' (e.g. after a halt) unless the actual basename used at creation is
# recorded and consulted instead of guessing.
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
qemu-img create -f qcow2 -b "$EXT_SNAP" -F qcow2 "$DISK_PATH" 1G > /dev/null
chmod 666 "$DISK_PATH"
basename "$EXT_SNAP" > .migrant-base-image
cat > dom.xml <<EOF
<domain type='kvm'>
  <name>$VM</name>
  <memory unit='KiB'>524288</memory>
  <currentMemory unit='KiB'>524288</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$DISK_PATH'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <console type='pty'/>
  </devices>
</domain>
EOF
virsh define dom.xml > /dev/null

# Not run_migrant's default timeout 25: this VM has no network interface, so
# 'up' can never succeed — it just spins in wait_for_ip (120s, no override)
# until something kills it. The pass/fail signal below is already decided
# within the first fraction of a second, so a short timeout is plenty; it
# only needs to outlast virsh/shell startup on a slow box, not a real boot.
run_migrant --timeout 8 up

if grep -q "was built from" <<<"$OUT"; then
  fail "custom-snapshot VM falsely flagged as base-image drift: $OUT"
elif grep -q "exists but is not running. Starting" <<<"$OUT"; then
  pass "'up' does not flag drift for a VM built from a custom-named snapshot"
else
  fail "'up' did not reach the start path: status=$STATUS output=$OUT"
fi
virsh destroy "$VM" &>/dev/null || true
rm -f .migrant-base-image "$DISK_PATH"

# --- 16. the real cross-host restore command: no local domain, a relative
#         snapshot path typed from inside the VM directory, and a
#         caller-supplied _MIGRANT_RESET_MACS, all together ------------------
# This is the exact shape 'migrant-archive's restore instructions use:
#   cd <vm-dir>
#   _MIGRANT_RESET_MACS="$(cat ../mac-address.txt)" migrant reset ../<vm>-snapshot.qcow2
# Two things distinguish it from scenarios 8b and 13, which each cover half
# of this: the snapshot path is relative, and it's typed from a CWD that
# differs from IMAGES_DIR — the case where a relative path is easy to get
# subtly wrong (qcow2 resolves a relative backing-file path against the
# *overlay's* directory, i.e. IMAGES_DIR, not the CWD it was typed from).
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$SNAPSHOT_PATH"

LAYOUT_DIR="$WORK/layout"
VM_SUBDIR="$LAYOUT_DIR/$VM"
mkdir -p "$VM_SUBDIR"
cp Migrantfile cloud-init.yml "$VM_SUBDIR/"
REL_SNAP_TARGET="$LAYOUT_DIR/${VM}-snapshot.qcow2"
qemu-img create -f qcow2 "$REL_SNAP_TARGET" 10M > /dev/null

cd "$VM_SUBDIR"
PATH="$WORK/fakebin:$PATH" _MIGRANT_RESET_MACS="52:54:00:c0:ff:ee" run_migrant reset "../$(basename "$REL_SNAP_TARGET")"
cd "$WORK"

if grep -qF "Using snapshot: $REL_SNAP_TARGET" <<<"$OUT"; then
  pass "reset resolves a relative snapshot path against the caller's CWD, not IMAGES_DIR"
else
  fail "reset did not resolve the relative snapshot path correctly: $OUT"
fi
if [[ -f "$DISK_PATH" ]] && qemu-img info "$DISK_PATH" | grep -qF "backing file: $REL_SNAP_TARGET"; then
  pass "disk built from a relative snapshot path is backed by the correct absolute file"
else
  fail "relative-path reset backing file wrong: $(qemu-img info "$DISK_PATH" 2>&1 || true)"
fi
if grep -qF -- "--network network=migrant,mac=52:54:00:c0:ff:ee" "$WORK/virt-install.args" 2>/dev/null; then
  pass "the full cross-host restore command honors _MIGRANT_RESET_MACS with a relative path and no local domain"
else
  fail "MAC not honored in the full restore-command scenario: $(cat "$WORK/virt-install.args" 2>/dev/null || echo missing)"
fi
rm -f "$DISK_PATH" "$WORK/virt-install.args"

# --- 17. reset with a custom path when a local domain already exists -----------
# The other officially documented use of a custom path (README.md): a
# checkpoint on a live domain, same host —
#   migrant snapshot ~/vm-checkpoints/
#   migrant reset ~/vm-checkpoints/<file>
# Untested until now: scenario 7 covers domain-exists + the *default* path,
# scenario 13 covers a custom path but destroys the domain first. This
# combines domain-exists with a (relative) custom path, and — since a
# caller-supplied _MIGRANT_RESET_MACS is also set here, to a value that
# differs from the domain's real MAC — proves the existing domain's real MAC
# still wins the priority that scenario 8b/16 only checked in the absence of
# any domain. Also confirms reset updates .migrant-base-image from a real
# run (scenario 15 fabricates that file by hand rather than exercising the
# code path that writes it).
cat > dom-checkpoint.xml <<EOF
<domain type='kvm'>
  <name>$VM</name>
  <memory unit='KiB'>524288</memory>
  <currentMemory unit='KiB'>524288</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <devices>
    <interface type='ethernet'>
      <mac address='52:54:00:11:22:33'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'/>
  </devices>
</domain>
EOF
virsh define dom-checkpoint.xml > /dev/null
virsh start "$VM" > /dev/null

VM_SUBDIR="$WORK/layout/$VM"
mkdir -p "$VM_SUBDIR"
cp Migrantfile cloud-init.yml "$VM_SUBDIR/"
CHECKPOINT_SNAP="$WORK/layout/${VM}-checkpoint.qcow2"
qemu-img create -f qcow2 "$CHECKPOINT_SNAP" 10M > /dev/null

cd "$VM_SUBDIR"
PATH="$WORK/fakebin:$PATH" _MIGRANT_RESET_MACS="52:54:00:ba:ad:00" \
  run_migrant reset "../$(basename "$CHECKPOINT_SNAP")"
cd "$WORK"

if grep -qF "Using snapshot: $CHECKPOINT_SNAP" <<<"$OUT"; then
  pass "reset with an existing domain resolves a relative custom path against the caller's CWD"
else
  fail "reset (domain exists) did not resolve the relative snapshot path correctly: $OUT"
fi
if [[ -f "$DISK_PATH" ]] && qemu-img info "$DISK_PATH" | grep -qF "backing file: $CHECKPOINT_SNAP"; then
  pass "disk is backed by the checkpoint, not the default snapshot"
else
  fail "checkpoint reset backing file wrong: $(qemu-img info "$DISK_PATH" 2>&1 || true)"
fi
if grep -qF -- "--network network=migrant,mac=52:54:00:11:22:33" "$WORK/virt-install.args" 2>/dev/null; then
  pass "reset with a custom path still preserves the existing domain's real MAC over a caller-supplied one"
else
  fail "existing-domain MAC not preserved alongside a custom path: $(cat "$WORK/virt-install.args" 2>/dev/null || echo missing)"
fi
if [[ -f "$VM_SUBDIR/.migrant-base-image" ]] && grep -qF "$(basename "$CHECKPOINT_SNAP")" "$VM_SUBDIR/.migrant-base-image"; then
  pass "reset records the checkpoint's basename in .migrant-base-image"
else
  fail ".migrant-base-image not updated to the checkpoint: $(cat "$VM_SUBDIR/.migrant-base-image" 2>/dev/null || echo missing)"
fi
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH" "$WORK/virt-install.args"

# Scenarios 18-24 start the domain and then archive it, and cmd_archive routes
# through cmd_snapshot's graceful-shutdown branch. Shadow virsh again (same
# wrapper scenario 3 used) so 'shutdown' maps to an immediate 'destroy': these
# domains have no real guest OS to answer the ACPI request, so a real
# 'virsh shutdown' would just block until run_migrant's outer timeout fires.
cat > fakebin/virsh <<'WRAP'
#!/usr/bin/env bash
if [[ "$1" == "shutdown" ]]; then
  exec /usr/bin/virsh destroy "$2"
fi
exec /usr/bin/virsh "$@"
WRAP
chmod +x fakebin/virsh

# --- 18. archive bundles the VM directory, a fresh snapshot, and a
#         MAC-address file into one tarball -------------------------------------
ARCHIVE_VM_DIR="$WORK/archive-vm"
mkdir -p "$ARCHIVE_VM_DIR"
cp Migrantfile cloud-init.yml "$ARCHIVE_VM_DIR/"

cd "$ARCHIVE_VM_DIR"
define_domain_with_mac "52:54:00:a2:c4:11"

ARCHIVE_OUT="$WORK/archives"
mkdir -p "$ARCHIVE_OUT"
PATH="$WORK/fakebin:$PATH" run_migrant archive "$ARCHIVE_OUT"
cd "$WORK"

if (( STATUS == 0 )) && grep -q "Archive ready:" <<<"$OUT"; then
  pass "archive succeeds and reports the output path"
else
  fail "archive failed: status=$STATUS output=$OUT"
fi

ARCHIVE_TARBALL=$(find "$ARCHIVE_OUT" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
if [[ -n "$ARCHIVE_TARBALL" ]]; then
  pass "archive writes a timestamped tarball into the given directory"
else
  fail "no archive tarball found in $ARCHIVE_OUT"
fi

ARCHIVE_LIST=$(tar -tf "$ARCHIVE_TARBALL")
if grep -q "^archive-vm/Migrantfile$" <<<"$ARCHIVE_LIST" \
    && grep -q "^${VM}-snapshot.qcow2$" <<<"$ARCHIVE_LIST" \
    && grep -q "^${VM}-mac-addresses.txt$" <<<"$ARCHIVE_LIST"; then
  pass "archive tarball contains the VM directory, snapshot, and MAC-address file"
else
  fail "archive tarball missing expected members: $ARCHIVE_LIST"
fi

ARCHIVE_EXTRACT="$WORK/archive-extract-18"
mkdir -p "$ARCHIVE_EXTRACT"
tar --sparse -xf "$ARCHIVE_TARBALL" -C "$ARCHIVE_EXTRACT"
if extracted_matches_marker "$ARCHIVE_EXTRACT/${VM}-snapshot.qcow2"; then
  pass "archive's embedded snapshot matches the VM disk content"
else
  fail "archive's embedded snapshot content mismatch"
fi

if [[ "$(cat "$ARCHIVE_EXTRACT/${VM}-mac-addresses.txt")" == "52:54:00:a2:c4:11" ]]; then
  pass "archive's MAC-address file contains the domain's MAC"
else
  fail "archive MAC-address file wrong: $(cat "$ARCHIVE_EXTRACT/${VM}-mac-addresses.txt" 2>/dev/null || echo missing)"
fi

virsh destroy "$VM" &>/dev/null || true
rm -rf "$ARCHIVE_EXTRACT"

# --- 19. archive captures every NIC's MAC address, not just the first ----------
cd "$ARCHIVE_VM_DIR"
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
qemu-img convert -f raw -O qcow2 "$WORK/marker.bin" "$DISK_PATH"
chmod 666 "$DISK_PATH"
cat > dom-archive-multinic.xml <<EOF
<domain type='kvm'>
  <name>$VM</name>
  <memory unit='KiB'>524288</memory>
  <currentMemory unit='KiB'>524288</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$DISK_PATH'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='ethernet'>
      <mac address='52:54:00:a2:c4:21'/>
      <model type='virtio'/>
    </interface>
    <interface type='ethernet'>
      <mac address='52:54:00:a2:c4:22'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'/>
  </devices>
</domain>
EOF
virsh define dom-archive-multinic.xml > /dev/null
virsh start "$VM" > /dev/null

rm -f "$ARCHIVE_OUT/${VM}"-*.tar.zst
PATH="$WORK/fakebin:$PATH" run_migrant archive "$ARCHIVE_OUT"
cd "$WORK"

ARCHIVE_TARBALL_19=$(find "$ARCHIVE_OUT" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
ARCHIVE_EXTRACT_19="$WORK/archive-extract-19"
mkdir -p "$ARCHIVE_EXTRACT_19"
tar --sparse -xf "$ARCHIVE_TARBALL_19" -C "$ARCHIVE_EXTRACT_19"
MACS_19=$(cat "$ARCHIVE_EXTRACT_19/${VM}-mac-addresses.txt")
if grep -qF "52:54:00:a2:c4:21" <<<"$MACS_19" && grep -qF "52:54:00:a2:c4:22" <<<"$MACS_19"; then
  pass "archive captures every NIC's MAC address"
else
  fail "archive did not capture both MACs: $MACS_19"
fi
virsh destroy "$VM" &>/dev/null || true
rm -rf "$ARCHIVE_EXTRACT_19" "$ARCHIVE_OUT/${VM}"-*.tar.zst

# --- 20. archive includes a relative-path shared folder automatically ----------
cd "$ARCHIVE_VM_DIR"
cat >> Migrantfile <<'EOF'
SHARED_FOLDERS=("workspace.img:workspace")
EOF
head -c 4096 /dev/urandom > workspace.img
define_domain_with_mac "52:54:00:a2:c4:31"

PATH="$WORK/fakebin:$PATH" run_migrant archive "$ARCHIVE_OUT"
cd "$WORK"

ARCHIVE_TARBALL_20=$(find "$ARCHIVE_OUT" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
if [[ -z "$ARCHIVE_TARBALL_20" ]]; then
  fail "archive did not include the relative-path shared folder: no tarball found. status=$STATUS output=$OUT"
else
  # Capture first, then grep the variable: piping tar's live output into
  # 'grep -q' races grep's early exit-on-match against tar still writing
  # later entries — under pipefail, tar's resulting SIGPIPE can fail the
  # whole pipeline even though grep already found its match.
  ARCHIVE_MEMBERS_20=$(tar -tf "$ARCHIVE_TARBALL_20")
  if grep -qF "archive-vm/workspace.img" <<<"$ARCHIVE_MEMBERS_20"; then
    pass "archive includes a relative-path shared folder"
  else
    fail "archive did not include the relative-path shared folder: tarball members: $ARCHIVE_MEMBERS_20 | status=$STATUS output=$OUT"
  fi
fi
virsh destroy "$VM" &>/dev/null || true
rm -f "$ARCHIVE_OUT/${VM}"-*.tar.zst

# --- 21. archive warns on and excludes an absolute-path shared folder ----------
cd "$ARCHIVE_VM_DIR"
EXTERNAL_SHARE_DIR="$WORK/external-share"
mkdir -p "$EXTERNAL_SHARE_DIR"
head -c 4096 /dev/urandom > "$EXTERNAL_SHARE_DIR/data.img"
cat > Migrantfile <<EOF
VM_NAME="$VM"
OS_VARIANT="generic"
RAM_MB=512
VCPUS=1
DISK_GB=1
IMAGE_URL="https://example.invalid/x.qcow2"
SHARED_FOLDERS=("$EXTERNAL_SHARE_DIR/data.img:data")
SHARED_FOLDER_ISOLATION=false
NETWORK_ISOLATION=false
NETWORKS=(
  "network=migrant"
)
EOF
define_domain_with_mac "52:54:00:a2:c4:41"

PATH="$WORK/fakebin:$PATH" run_migrant archive "$ARCHIVE_OUT"
cd "$WORK"

if grep -qF "shared folder '$EXTERNAL_SHARE_DIR/data.img' is outside the VM directory" <<<"$OUT"; then
  pass "archive warns about an absolute-path shared folder"
else
  fail "archive did not warn about the absolute-path shared folder: $OUT"
fi
ARCHIVE_TARBALL_21=$(find "$ARCHIVE_OUT" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
ARCHIVE_MEMBERS_21=$(tar -tf "$ARCHIVE_TARBALL_21")
if grep -q "data.img" <<<"$ARCHIVE_MEMBERS_21"; then
  fail "archive included the absolute-path shared folder despite the warning"
else
  pass "archive excludes the absolute-path shared folder"
fi
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$ARCHIVE_OUT/${VM}"-*.tar.zst
rm -rf "$ARCHIVE_VM_DIR" "$EXTERNAL_SHARE_DIR"

# --- 22. restore round-trips an archive: extracts, places it at [dest], and
#         rebuilds the VM with the archived MAC, with no local domain ----------
RESTORE_SRC_DIR="$WORK/restore-src-vm"
mkdir -p "$RESTORE_SRC_DIR"
cp Migrantfile cloud-init.yml "$RESTORE_SRC_DIR/"
cd "$RESTORE_SRC_DIR"
define_domain_with_mac "52:54:00:a2:c4:51"
RESTORE_ARCHIVE_DIR="$WORK/restore-archives"
mkdir -p "$RESTORE_ARCHIVE_DIR"
PATH="$WORK/fakebin:$PATH" run_migrant archive "$RESTORE_ARCHIVE_DIR"
cd "$WORK"
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH"

RESTORE_TARBALL=$(find "$RESTORE_ARCHIVE_DIR" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
RESTORE_DEST="$WORK/restored-vm"

PATH="$WORK/fakebin:$PATH" run_migrant restore "$RESTORE_TARBALL" "$RESTORE_DEST"

if [[ -f "$RESTORE_DEST/Migrantfile" ]]; then
  pass "restore extracts the VM directory to the given destination"
else
  fail "restore did not place the VM directory: status=$STATUS output=$OUT"
fi
if grep -qF "Using snapshot:" <<<"$OUT"; then
  pass "restore re-invokes reset against the extracted snapshot"
else
  fail "restore did not reach reset: $OUT"
fi
# The run's exit status is an artifact of the shadowed virt-install (it exits
# 1), so assert how far the restore actually got instead of tolerating a range.
if grep -q "fake virt-install invoked" <<<"$OUT"; then
  pass "restore drives the rebuild all the way to virt-install"
else
  fail "restore did not reach virt-install: status=$STATUS output=$OUT"
fi
# The snapshot lands in IMAGES_DIR's default slot, not in [dest]: it is the
# disk's backing file for the life of the VM, so it belongs where a local
# 'migrant snapshot' would have put it — reachable by qemu regardless of the
# caller's home permissions, and visible to status/storage/reset/destroy.
if [[ -f "$DISK_PATH" ]] && qemu-img info "$DISK_PATH" | grep -qF "backing file: $SNAPSHOT_PATH"; then
  pass "restored disk is backed by the snapshot at the default IMAGES_DIR slot"
else
  fail "restored disk backing file wrong: $(qemu-img info "$DISK_PATH" 2>&1 || true)"
fi
if [[ -f "$SNAPSHOT_PATH" ]]; then
  pass "restore places the archived snapshot at the default slot"
else
  fail "restore did not place a snapshot at $SNAPSHOT_PATH"
fi
if [[ ! -e "$RESTORE_DEST/${VM}-snapshot.qcow2" ]]; then
  pass "restore leaves no snapshot in the VM directory"
else
  fail "restore left a snapshot in the VM directory"
fi
if grep -qF -- "--network network=migrant,mac=52:54:00:a2:c4:51" "$WORK/virt-install.args" 2>/dev/null; then
  pass "restore preserves the archived domain's MAC address"
else
  fail "restore did not preserve the MAC: $(cat "$WORK/virt-install.args" 2>/dev/null || echo missing)"
fi

virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH" "$SNAPSHOT_PATH" "$WORK/virt-install.args"
rm -rf "$RESTORE_SRC_DIR" "$RESTORE_ARCHIVE_DIR" "$RESTORE_DEST"

# --- 23. restore refuses when run from inside an already-existing VM
#         directory, without extracting anything (the motivating case for
#         this whole design: [dest] defaults to CWD, not a parent to nest a
#         new directory under) ---------------------------------------------------
RESTORE_SRC_DIR_23="$WORK/restore-src-vm-23"
mkdir -p "$RESTORE_SRC_DIR_23"
cp Migrantfile cloud-init.yml "$RESTORE_SRC_DIR_23/"
cd "$RESTORE_SRC_DIR_23"
define_domain_with_mac "52:54:00:a2:c4:61"
RESTORE_ARCHIVE_DIR_23="$WORK/restore-archives-23"
mkdir -p "$RESTORE_ARCHIVE_DIR_23"
PATH="$WORK/fakebin:$PATH" run_migrant archive "$RESTORE_ARCHIVE_DIR_23"
cd "$WORK"
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH"

RESTORE_TARBALL_23=$(find "$RESTORE_ARCHIVE_DIR_23" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
EXISTING_VM_DIR="$WORK/existing-vm-dir"
mkdir -p "$EXISTING_VM_DIR"
cp Migrantfile "$EXISTING_VM_DIR/"

cd "$EXISTING_VM_DIR"
run_migrant restore "$RESTORE_TARBALL_23"
cd "$WORK"

if (( STATUS != 0 )) && grep -qF "already contains files" <<<"$OUT"; then
  pass "restore refuses when run from inside an existing VM directory"
else
  fail "restore did not refuse: status=$STATUS output=$OUT"
fi
if [[ ! -e "$EXISTING_VM_DIR/${VM}-snapshot.qcow2" ]]; then
  pass "restore extracted nothing before refusing"
else
  fail "restore extracted files despite refusing"
fi
rm -rf "$RESTORE_SRC_DIR_23" "$RESTORE_ARCHIVE_DIR_23" "$EXISTING_VM_DIR"

# --- 24. restore into an empty, pre-existing directory succeeds (emptiness,
#         not existence, is what's checked) -------------------------------------
RESTORE_SRC_DIR_24="$WORK/restore-src-vm-24"
mkdir -p "$RESTORE_SRC_DIR_24"
cp Migrantfile cloud-init.yml "$RESTORE_SRC_DIR_24/"
cd "$RESTORE_SRC_DIR_24"
define_domain_with_mac "52:54:00:a2:c4:71"
RESTORE_ARCHIVE_DIR_24="$WORK/restore-archives-24"
mkdir -p "$RESTORE_ARCHIVE_DIR_24"
PATH="$WORK/fakebin:$PATH" run_migrant archive "$RESTORE_ARCHIVE_DIR_24"
cd "$WORK"
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH"

RESTORE_TARBALL_24=$(find "$RESTORE_ARCHIVE_DIR_24" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
EMPTY_DEST="$WORK/empty-dest-24"
mkdir -p "$EMPTY_DEST"

PATH="$WORK/fakebin:$PATH" run_migrant restore "$RESTORE_TARBALL_24" "$EMPTY_DEST"

if [[ -f "$EMPTY_DEST/Migrantfile" ]]; then
  pass "restore succeeds into an empty, pre-existing directory"
else
  fail "restore did not extract into the empty directory: status=$STATUS output=$OUT"
fi
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH" "$SNAPSHOT_PATH" "$WORK/virt-install.args"
rm -rf "$RESTORE_SRC_DIR_24" "$RESTORE_ARCHIVE_DIR_24" "$EMPTY_DEST"
rm -f fakebin/virsh

# --- 25. restore errors cleanly on a tarball missing its snapshot file ---------
BAD_ARCHIVE_DIR="$WORK/bad-archive-25"
mkdir -p "$BAD_ARCHIVE_DIR/badvm"
cp Migrantfile "$BAD_ARCHIVE_DIR/badvm/"
touch "$BAD_ARCHIVE_DIR/${VM}-mac-addresses.txt"
BAD_TARBALL_25="$WORK/bad-25.tar"
tar -cf "$BAD_TARBALL_25" -C "$BAD_ARCHIVE_DIR" badvm "${VM}-mac-addresses.txt"
BAD_DEST_25="$WORK/bad-dest-25"

run_migrant restore "$BAD_TARBALL_25" "$BAD_DEST_25"

if (( STATUS != 0 )) && grep -qF "missing '${VM}-snapshot.qcow2'" <<<"$OUT"; then
  pass "restore errors cleanly on a tarball missing its snapshot file"
else
  fail "restore did not report the missing snapshot: status=$STATUS output=$OUT"
fi
if [[ ! -e "$BAD_DEST_25" ]] || [[ -z "$(ls -A "$BAD_DEST_25" 2>/dev/null)" ]]; then
  pass "restore left [dest] untouched after a missing-snapshot error"
else
  fail "restore left partial state in $BAD_DEST_25"
fi
rm -rf "$BAD_ARCHIVE_DIR" "$BAD_TARBALL_25" "$BAD_DEST_25"

# --- 26. restore errors cleanly on a tarball missing its MAC-address file ------
BAD_ARCHIVE_DIR_26="$WORK/bad-archive-26"
mkdir -p "$BAD_ARCHIVE_DIR_26/badvm"
cp Migrantfile "$BAD_ARCHIVE_DIR_26/badvm/"
qemu-img create -f qcow2 "$BAD_ARCHIVE_DIR_26/${VM}-snapshot.qcow2" 1M > /dev/null
BAD_TARBALL_26="$WORK/bad-26.tar"
tar -cf "$BAD_TARBALL_26" -C "$BAD_ARCHIVE_DIR_26" badvm "${VM}-snapshot.qcow2"
BAD_DEST_26="$WORK/bad-dest-26"

run_migrant restore "$BAD_TARBALL_26" "$BAD_DEST_26"

if (( STATUS != 0 )) && grep -qF "missing '${VM}-mac-addresses.txt'" <<<"$OUT"; then
  pass "restore errors cleanly on a tarball missing its MAC-address file"
else
  fail "restore did not report the missing MAC-address file: status=$STATUS output=$OUT"
fi
if [[ ! -e "$BAD_DEST_26" ]] || [[ -z "$(ls -A "$BAD_DEST_26" 2>/dev/null)" ]]; then
  pass "restore left [dest] untouched after a missing-MAC-file error"
else
  fail "restore left partial state in $BAD_DEST_26"
fi
rm -rf "$BAD_ARCHIVE_DIR_26" "$BAD_TARBALL_26" "$BAD_DEST_26"

# --- 27. archive accepts a relative <dest> -------------------------------------
# Regression: scratch_dir is created under dest_dir and reaches tar as a second
# -C, which GNU tar resolves against the *first* -C rather than the CWD. Left
# relative, tar went looking for the scratch dir under the VM directory's
# parent and died — after the halt and the multi-GB snapshot had already run.
# Every other archive scenario passes an absolute path, so none of them catch
# this.
REL_VM_DIR="$WORK/rel/vmdir"
mkdir -p "$REL_VM_DIR" "$WORK/rel/backups"
cp Migrantfile cloud-init.yml "$REL_VM_DIR/"
cd "$REL_VM_DIR"
# Archived from a shut-off domain, so cmd_snapshot never takes its
# graceful-shutdown branch and no virsh shadow is needed here.
define_domain_with_mac "52:54:00:a2:c4:81"
virsh destroy "$VM" > /dev/null
run_migrant archive ../backups

REL_TARBALL=$(find "$WORK/rel/backups" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
if (( STATUS == 0 )) && [[ -n "$REL_TARBALL" ]]; then
  pass "archive accepts a relative <dest>"
else
  fail "archive with a relative <dest> failed: status=$STATUS output=$OUT"
fi
if [[ -n "$REL_TARBALL" ]]; then
  REL_MEMBERS=$(tar -tf "$REL_TARBALL")
  if grep -q "^vmdir/Migrantfile$" <<<"$REL_MEMBERS" \
      && grep -q "^${VM}-snapshot.qcow2$" <<<"$REL_MEMBERS" \
      && grep -q "^${VM}-mac-addresses.txt$" <<<"$REL_MEMBERS"; then
    pass "a relative-<dest> archive has the same members as an absolute one"
  else
    fail "relative-<dest> archive members wrong: $REL_MEMBERS"
  fi
fi
if [[ -z "$(find "$WORK/rel/backups" -maxdepth 1 -type d -name 'tmp.*' -print -quit)" ]]; then
  pass "archive cleans up its scratch directory"
else
  fail "archive left a scratch directory in $WORK/rel/backups"
fi

# A trailing slash names a directory; a non-existent one must not silently
# become a regular file of that name. Still run from inside REL_VM_DIR, so the
# destination is outside the VM directory and this exercises the trailing-slash
# check rather than the archive-into-itself guard.
run_migrant archive "$WORK/rel/nonexistent/"
if (( STATUS == 73 )) && grep -qF "directory does not exist" <<<"$OUT"; then
  pass "archive rejects a trailing-slash <dest> that is not a directory"
else
  fail "archive did not reject a non-existent directory dest: status=$STATUS output=$OUT"
fi
if [[ ! -e "$WORK/rel/nonexistent" ]]; then
  pass "archive created no file for the rejected trailing-slash <dest>"
else
  fail "archive created '$WORK/rel/nonexistent' instead of refusing"
fi
cd "$WORK"

virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH"
rm -rf "$WORK/rel"

# --- 28. restore checks the managed SSH key before it moves anything ----------
# The archive carries no private key by design, and cloud-init does not re-run
# on a restore — the guest's authorized_keys is fixed in the snapshot — so a
# destination host without the matching key can never reach the restored VM,
# and no key regenerated afterwards can repair it. cmd_up's own
# check_managed_key_match would catch the missing key only after [dest] had
# been populated, and would advise 'destroy && up', discarding the restore.
KEY_VM_DIR="$WORK/key-src-vm"
mkdir -p "$KEY_VM_DIR"
cp Migrantfile "$KEY_VM_DIR/"
SRC_HOME="$WORK/src-home"
mkdir -p "$SRC_HOME/.ssh"
ssh-keygen -q -t ed25519 -N '' -C migrant -f "$SRC_HOME/.ssh/migrant"
SRC_KEY_MATERIAL=$(awk '{print $2}' "$SRC_HOME/.ssh/migrant.pub")
cat > "$KEY_VM_DIR/cloud-init.yml" <<EOF
users:
  - name: migrant
    ssh_authorized_keys:
      - ssh-ed25519 $SRC_KEY_MATERIAL migrant
EOF
cd "$KEY_VM_DIR"
define_domain_with_mac "52:54:00:a2:c4:91"
virsh destroy "$VM" > /dev/null
KEY_ARCHIVE_DIR="$WORK/key-archives"
mkdir -p "$KEY_ARCHIVE_DIR"
HOME="$SRC_HOME" run_migrant archive "$KEY_ARCHIVE_DIR"
cd "$WORK"
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH"

KEY_TARBALL=$(find "$KEY_ARCHIVE_DIR" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)

EMPTY_HOME="$WORK/empty-home"
mkdir -p "$EMPTY_HOME/.ssh"
KEY_DEST="$WORK/key-restore-dest"
HOME="$EMPTY_HOME" run_migrant restore "$KEY_TARBALL" "$KEY_DEST"
if (( STATUS == 66 )) && grep -qF "was not found on this host" <<<"$OUT"; then
  pass "restore refuses when the destination host lacks the managed SSH key"
else
  fail "restore did not refuse on a missing managed key: status=$STATUS output=$OUT"
fi
if [[ ! -e "$KEY_DEST/Migrantfile" ]]; then
  pass "restore moved nothing into [dest] before refusing on a missing key"
else
  fail "restore populated [dest] despite refusing"
fi

MISMATCH_HOME="$WORK/mismatch-home"
mkdir -p "$MISMATCH_HOME/.ssh"
ssh-keygen -q -t ed25519 -N '' -C migrant -f "$MISMATCH_HOME/.ssh/migrant"
KEY_DEST_2="$WORK/key-restore-dest-2"
HOME="$MISMATCH_HOME" run_migrant restore "$KEY_TARBALL" "$KEY_DEST_2"
if (( STATUS == 78 )) && grep -qF "does not match the managed key" <<<"$OUT"; then
  pass "restore refuses when the destination host's managed key does not match"
else
  fail "restore did not refuse on a mismatched managed key: status=$STATUS output=$OUT"
fi
if [[ ! -e "$KEY_DEST_2/Migrantfile" ]]; then
  pass "restore moved nothing into [dest] before refusing on a key mismatch"
else
  fail "restore populated [dest] despite refusing"
fi

# With the matching key present the preflight gets out of the way entirely.
# virt-install is still shadowed (it exits 1), so assert on reaching the reset
# leg rather than on the exit status.
KEY_DEST_3="$WORK/key-restore-dest-3"
PATH="$WORK/fakebin:$PATH" HOME="$SRC_HOME" run_migrant restore "$KEY_TARBALL" "$KEY_DEST_3"
if grep -qF "Restoring '$VM'" <<<"$OUT"; then
  pass "restore proceeds when the destination host has the matching key"
else
  fail "restore did not proceed with the matching key: status=$STATUS output=$OUT"
fi

virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH" "$SNAPSHOT_PATH" "$WORK/virt-install.args"
rm -rf "$KEY_VM_DIR" "$KEY_ARCHIVE_DIR" "$SRC_HOME" "$EMPTY_HOME" "$MISMATCH_HOME" \
       "$KEY_DEST" "$KEY_DEST_2" "$KEY_DEST_3"

# --- 29. restore refuses when a domain of the archived name already exists,
#         and leaves that domain untouched ---------------------------------
# 'reset' may assume the domain it undefines is the one its own Migrantfile
# describes; 'restore' takes the name from a foreign tarball, so a collision
# on the destination host would delete an unrelated VM's disk.
COLLIDE_SRC="$WORK/collide-src-vm"
mkdir -p "$COLLIDE_SRC"
cp Migrantfile cloud-init.yml "$COLLIDE_SRC/"
cd "$COLLIDE_SRC"
define_domain_with_mac "52:54:00:a2:c4:a1"
virsh destroy "$VM" > /dev/null
COLLIDE_ARCHIVES="$WORK/collide-archives"
mkdir -p "$COLLIDE_ARCHIVES"
run_migrant archive "$COLLIDE_ARCHIVES"
cd "$WORK"
COLLIDE_TARBALL=$(find "$COLLIDE_ARCHIVES" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)

# The domain defined for the archive step is still there — it stands in for an
# unrelated VM on the destination host that happens to share the name.
COLLIDE_DEST="$WORK/collide-dest"
run_migrant restore "$COLLIDE_TARBALL" "$COLLIDE_DEST"

if (( STATUS == 1 )) && grep -qF "already exists on this host" <<<"$OUT"; then
  pass "restore refuses when a domain of the archived name already exists"
else
  fail "restore did not refuse on a domain-name collision: status=$STATUS output=$OUT"
fi
if virsh dominfo "$VM" &>/dev/null; then
  pass "restore left the colliding domain defined"
else
  fail "restore undefined the colliding domain"
fi
if [[ -f "$DISK_PATH" ]]; then
  pass "restore left the colliding domain's disk in place"
else
  fail "restore deleted the colliding domain's disk"
fi
if [[ ! -e "$COLLIDE_DEST/Migrantfile" ]]; then
  pass "restore moved nothing into [dest] before refusing on a collision"
else
  fail "restore populated [dest] despite refusing"
fi

# --force opts into the replacement the bare command refuses. The old domain is
# torn down by restore itself, before the reset leg, so the archived MACs win
# over the ones the colliding domain would otherwise have supplied.
COLLIDE_DEST_2="$WORK/collide-dest-2"
PATH="$WORK/fakebin:$PATH" run_migrant restore --force "$COLLIDE_TARBALL" "$COLLIDE_DEST_2"

if grep -qF "Replacing existing VM '$VM'" <<<"$OUT"; then
  pass "restore --force reports replacing the colliding VM"
else
  fail "restore --force did not report the replacement: status=$STATUS output=$OUT"
fi
if grep -qF "Restoring '$VM'" <<<"$OUT"; then
  pass "restore --force proceeds past the collision into the reset leg"
else
  fail "restore --force did not reach reset: status=$STATUS output=$OUT"
fi
if [[ -f "$COLLIDE_DEST_2/Migrantfile" ]]; then
  pass "restore --force places the VM directory at [dest]"
else
  fail "restore --force did not place the VM directory: status=$STATUS output=$OUT"
fi
# The colliding domain carried 52:54:00:a2:c4:a1 and so does the archive, so
# assert on the one thing that distinguishes teardown-first from teardown-late:
# reset must have found no local domain to take MACs from.
if grep -qF -- "--network network=migrant,mac=52:54:00:a2:c4:a1" "$WORK/virt-install.args" 2>/dev/null; then
  pass "restore --force rebuilds with the archived MAC address"
else
  fail "restore --force lost the archived MAC: $(cat "$WORK/virt-install.args" 2>/dev/null || echo missing)"
fi

virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH" "$SNAPSHOT_PATH" "$WORK/virt-install.args"
rm -rf "$COLLIDE_SRC" "$COLLIDE_ARCHIVES" "$COLLIDE_DEST" "$COLLIDE_DEST_2"

# --- 32. restore argument parsing --------------------------------------------
ARGS_DEST="$WORK/args-dest"
run_migrant restore --bogus "$WORK/nope.tar.zst" "$ARGS_DEST"
if (( STATUS == 64 )) && grep -qF "unknown option '--bogus'" <<<"$OUT"; then
  pass "restore rejects an unknown option with exit 64"
else
  fail "restore did not reject an unknown option: status=$STATUS output=$OUT"
fi
run_migrant restore a.tar.zst b c
if (( STATUS == 64 )) && grep -qF "at most a tarball and a destination" <<<"$OUT"; then
  pass "restore rejects extra positional arguments with exit 64"
else
  fail "restore did not reject extra positionals: status=$STATUS output=$OUT"
fi
run_migrant restore --force
if (( STATUS == 64 )) && grep -qF "requires a tarball path" <<<"$OUT"; then
  pass "restore with only --force still reports the missing tarball"
else
  fail "restore did not report a missing tarball: status=$STATUS output=$OUT"
fi
# <tarball> gets the same expand_home treatment as [dest] and as the path
# arguments to snapshot/reset/archive; see the note on SC2088 above.
# shellcheck disable=SC2088
HOME="$WORK/fakehome-restore" run_migrant restore '~/no-such-archive.tar.zst'
if (( STATUS == 66 )) \
    && grep -qF "$WORK/fakehome-restore/no-such-archive.tar.zst" <<<"$OUT"; then
  pass "restore expands a quoted '~' in its tarball argument"
else
  fail "restore did not expand '~' in <tarball>: status=$STATUS output=$OUT"
fi
rm -rf "$ARGS_DEST"

# --- 33. restore refuses when IMAGES_DIR is missing or unwritable -------------
# The rebuild has to put a disk and a snapshot there, so a host that never ran
# 'migrant setup' should fail up front — the way 'up' would — rather than
# partway through, with [dest] already populated.
NOSETUP_SRC="$WORK/nosetup-src-vm"
mkdir -p "$NOSETUP_SRC"
cp Migrantfile cloud-init.yml "$NOSETUP_SRC/"
cd "$NOSETUP_SRC"
define_domain_with_mac "52:54:00:a2:c4:d1"
virsh destroy "$VM" > /dev/null
NOSETUP_ARCHIVES="$WORK/nosetup-archives"
mkdir -p "$NOSETUP_ARCHIVES"
run_migrant archive "$NOSETUP_ARCHIVES"
cd "$WORK"
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH"
NOSETUP_TARBALL=$(find "$NOSETUP_ARCHIVES" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p
' | head -1)

# run_migrant pins LIBVIRT_IMAGES_DIR, so drive migrant directly to point it
# at an images directory that cannot be written.
RO_IMAGES="$WORK/ro-images"
mkdir -p "$RO_IMAGES"
chmod 555 "$RO_IMAGES"
NOSETUP_DEST="$WORK/nosetup-dest"
set +e
OUT=$(LIBVIRT_IMAGES_DIR="$RO_IMAGES" timeout 25 "$MIGRANT" restore "$NOSETUP_TARBALL" "$NOSETUP_DEST" 2>&1)
STATUS=$?
set -e
if (( STATUS == 73 )) && grep -qF "Run 'migrant setup' on this host first" <<<"$OUT"; then
  pass "restore refuses an unwritable IMAGES_DIR and points at 'migrant setup'"
else
  fail "restore did not refuse an unwritable IMAGES_DIR: status=$STATUS output=$OUT"
fi
if [[ ! -e "$NOSETUP_DEST" ]] || [[ -z "$(ls -A "$NOSETUP_DEST" 2>/dev/null)" ]]; then
  pass "restore created nothing at [dest] before refusing on an unwritable IMAGES_DIR"
else
  fail "restore populated [dest] despite refusing"
fi
chmod 755 "$RO_IMAGES"
rm -rf "$NOSETUP_SRC" "$NOSETUP_ARCHIVES" "$RO_IMAGES" "$NOSETUP_DEST"

# --- 30. a VM directory reached through a symlink -----------------------------
# VM_DIR is logical when it comes from the CWD (pwd keeps symlinks) but
# physical when it comes from MIGRANT_DIR (realpath). Comparing a resolved
# path against a raw VM_DIR therefore misses the archive-into-itself guard
# entirely, and falsely reports every included relative share as excluded.
SYM_REAL="$WORK/sym-real/vmdir"
mkdir -p "$SYM_REAL"
ln -s sym-real "$WORK/sym-link"
SYM_VM_DIR="$WORK/sym-link/vmdir"
cp cloud-init.yml "$SYM_REAL/"
cat > "$SYM_REAL/Migrantfile" <<EOF
VM_NAME="$VM"
OS_VARIANT="generic"
RAM_MB=512
VCPUS=1
DISK_GB=1
IMAGE_URL="https://example.invalid/x.qcow2"
SHARED_FOLDERS=("workspace.img:workspace")
SHARED_FOLDER_ISOLATION=false
NETWORK_ISOLATION=false
NETWORKS=(
  "network=migrant"
)
EOF
head -c 4096 /dev/urandom > "$SYM_REAL/workspace.img"
cd "$SYM_VM_DIR"
define_domain_with_mac "52:54:00:a2:c4:b1"
virsh destroy "$VM" > /dev/null

run_migrant archive "$SYM_VM_DIR/inside"
if (( STATUS == 64 )) && grep -qF "inside the VM directory" <<<"$OUT"; then
  pass "archive refuses a destination inside a symlinked VM directory"
else
  fail "archive did not refuse a dest inside a symlinked VM dir: status=$STATUS output=$OUT"
fi

SYM_OUT="$WORK/sym-archives"
mkdir -p "$SYM_OUT"
run_migrant archive "$SYM_OUT"
cd "$WORK"
if (( STATUS == 0 )) && ! grep -qF "is outside the VM directory" <<<"$OUT"; then
  pass "a relative share in a symlinked VM directory is not reported as excluded"
else
  fail "archive falsely warned about a relative share under a symlink: status=$STATUS output=$OUT"
fi
SYM_TARBALL=$(find "$SYM_OUT" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
if [[ -n "$SYM_TARBALL" ]]; then
  # Capture before grepping — see scenario 20 on the pipefail/SIGPIPE race.
  SYM_MEMBERS=$(tar -tf "$SYM_TARBALL")
  if grep -qF "vmdir/workspace.img" <<<"$SYM_MEMBERS"; then
    pass "the relative share is actually in the symlinked directory's archive"
  else
    fail "relative share missing from a symlinked VM directory's archive: $SYM_MEMBERS"
  fi
else
  fail "no tarball produced from a symlinked VM directory"
fi
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH"
rm -rf "$WORK/sym-real" "$WORK/sym-link" "$SYM_OUT"

# --- 31. archive into a destination path containing an apostrophe -------------
# The EXIT trap that removes the scratch directory embeds this path. Wrapped in
# bare single quotes it would be unparseable, so the cleanup would never run
# and the scratch snapshot — potentially many GB — would survive the archive.
APOS_DIR="$WORK/bob's backups"
mkdir -p "$APOS_DIR"
APOS_VM_DIR="$WORK/apos-vm"
mkdir -p "$APOS_VM_DIR"
cp Migrantfile cloud-init.yml "$APOS_VM_DIR/"
cd "$APOS_VM_DIR"
define_domain_with_mac "52:54:00:a2:c4:c1"
virsh destroy "$VM" > /dev/null
run_migrant archive "$APOS_DIR"
cd "$WORK"
APOS_TARBALL=$(find "$APOS_DIR" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
if (( STATUS == 0 )) && [[ -n "$APOS_TARBALL" ]]; then
  pass "archive succeeds into a path containing an apostrophe"
else
  fail "archive failed on an apostrophe in the destination: status=$STATUS output=$OUT"
fi
if [[ -z "$(find "$APOS_DIR" -maxdepth 1 -type d -name 'tmp.*' -print -quit)" ]]; then
  pass "archive cleans up its scratch directory despite the apostrophe"
else
  fail "archive left a scratch directory in $APOS_DIR"
fi
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH"
rm -rf "$APOS_VM_DIR" "$APOS_DIR"

# --- 34. archive writes the tarball 0600 --------------------------------------
# It holds the guest's whole disk and, for a WireGuard VM, wireguard.conf's
# private key; the default umask would leave it world-readable.
PERM_VM_DIR="$WORK/perm-vm"
mkdir -p "$PERM_VM_DIR"
cp Migrantfile cloud-init.yml "$PERM_VM_DIR/"
echo "PrivateKey = notarealkey" > "$PERM_VM_DIR/wireguard.conf"
cd "$PERM_VM_DIR"
define_domain_with_mac "52:54:00:a2:c4:e1"
virsh destroy "$VM" > /dev/null
PERM_OUT="$WORK/perm-archives"
mkdir -p "$PERM_OUT"
run_migrant archive "$PERM_OUT"
cd "$WORK"
PERM_TARBALL=$(find "$PERM_OUT" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
if [[ -n "$PERM_TARBALL" ]] && [[ "$(stat -c '%a' "$PERM_TARBALL")" == "600" ]]; then
  pass "archive writes the tarball with mode 600"
else
  fail "archive tarball mode wrong: $(stat -c '%a' "$PERM_TARBALL" 2>/dev/null || echo missing)"
fi
# Overwriting an existing world-readable file must also end up 0600 — a bare
# umask would not fix that case, since tar's O_TRUNC leaves the mode alone.
chmod 644 "$PERM_TARBALL"
cd "$PERM_VM_DIR"
run_migrant archive "$PERM_TARBALL"
cd "$WORK"
if [[ "$(stat -c '%a' "$PERM_TARBALL")" == "600" ]]; then
  pass "archive resets mode to 600 when overwriting an existing tarball"
else
  fail "overwritten tarball mode wrong: $(stat -c '%a' "$PERM_TARBALL")"
fi
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH"
rm -rf "$PERM_VM_DIR" "$PERM_OUT"

# --- 35. archive tolerates a VM with no NICs ----------------------------------
# NETWORKS may be empty or unset; an empty MAC list is only an error when the
# Migrantfile actually declares networks.
NONIC_VM_DIR="$WORK/nonic-vm"
mkdir -p "$NONIC_VM_DIR"
cp cloud-init.yml "$NONIC_VM_DIR/"
cat > "$NONIC_VM_DIR/Migrantfile" <<EOF
VM_NAME="$VM"
OS_VARIANT="generic"
RAM_MB=512
VCPUS=1
DISK_GB=1
IMAGE_URL="https://example.invalid/x.qcow2"
NETWORKS=()
EOF
cd "$NONIC_VM_DIR"
# define_domain (not ..._with_mac): a domain with a disk and no NICs at all.
define_domain
NONIC_OUT="$WORK/nonic-archives"
mkdir -p "$NONIC_OUT"
run_migrant archive "$NONIC_OUT"
cd "$WORK"
NONIC_TARBALL=$(find "$NONIC_OUT" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)
if (( STATUS == 0 )) && [[ -n "$NONIC_TARBALL" ]]; then
  pass "archive succeeds for a VM with no NICs"
else
  fail "archive refused a NIC-less VM: status=$STATUS output=$OUT"
fi
if [[ -n "$NONIC_TARBALL" ]]; then
  NONIC_EXTRACT="$WORK/nonic-extract"
  mkdir -p "$NONIC_EXTRACT"
  tar --sparse -xf "$NONIC_TARBALL" -C "$NONIC_EXTRACT"
  if [[ -f "$NONIC_EXTRACT/${VM}-mac-addresses.txt" ]] \
      && [[ ! -s "$NONIC_EXTRACT/${VM}-mac-addresses.txt" ]]; then
    pass "a NIC-less VM's archive carries an empty MAC-address file"
  else
    fail "NIC-less MAC file wrong: $(wc -c < "$NONIC_EXTRACT/${VM}-mac-addresses.txt" 2>/dev/null || echo missing) bytes"
  fi
  rm -rf "$NONIC_EXTRACT"
fi
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH"
rm -rf "$NONIC_VM_DIR" "$NONIC_OUT"

# --- 36. restore honours MIGRANT_DIR ------------------------------------------
# It was the only subcommand that ignored it, contrary to usage(). The target
# need not exist yet, so MIGRANT_DIR resolution must not hard-fail on it.
MD_SRC="$WORK/md-src-vm"
mkdir -p "$MD_SRC"
cp Migrantfile cloud-init.yml "$MD_SRC/"
cd "$MD_SRC"
define_domain_with_mac "52:54:00:a2:c4:f1"
virsh destroy "$VM" > /dev/null
MD_ARCHIVES="$WORK/md-archives"
mkdir -p "$MD_ARCHIVES"
run_migrant archive "$MD_ARCHIVES"
cd "$WORK"
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH"
MD_TARBALL=$(find "$MD_ARCHIVES" -maxdepth 1 -type f -name "${VM}-*.tar.zst" -printf '%p\n' | head -1)

MD_DEST="$WORK/md-dest/not-yet-created"
PATH="$WORK/fakebin:$PATH" MIGRANT_DIR="$MD_DEST" run_migrant restore "$MD_TARBALL"
if grep -qF "Restoring '$VM' into '$MD_DEST'" <<<"$OUT"; then
  pass "restore uses MIGRANT_DIR as [dest] when none is given"
else
  fail "restore ignored MIGRANT_DIR: status=$STATUS output=$OUT"
fi
if [[ -f "$MD_DEST/Migrantfile" ]]; then
  pass "restore creates a MIGRANT_DIR that does not exist yet"
else
  fail "restore did not populate $MD_DEST"
fi
# An explicit [dest] still wins over MIGRANT_DIR.
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH" "$SNAPSHOT_PATH" "$WORK/virt-install.args"
MD_EXPLICIT="$WORK/md-explicit"
PATH="$WORK/fakebin:$PATH" MIGRANT_DIR="$WORK/md-ignored" run_migrant restore "$MD_TARBALL" "$MD_EXPLICIT"
if [[ -f "$MD_EXPLICIT/Migrantfile" ]] && [[ ! -e "$WORK/md-ignored" ]]; then
  pass "an explicit [dest] takes precedence over MIGRANT_DIR"
else
  fail "explicit [dest] did not win over MIGRANT_DIR: status=$STATUS output=$OUT"
fi
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH" "$SNAPSHOT_PATH" "$WORK/virt-install.args"
rm -rf "$MD_SRC" "$MD_ARCHIVES" "$WORK/md-dest" "$MD_EXPLICIT"

# --- 37. snapshot into the slot the VM is built on commits, rather than failing
# A VM rebuilt by 'reset' — or by 'restore', which ends in one — sits on top of
# its snapshot as a copy-on-write backing file. A second bare 'migrant
# snapshot' therefore asks qemu-img to overwrite the very image it is reading
# through, which it refuses with 'Failed to get "write" lock', after the VM has
# already been halted for nothing. The slot has to be committed to instead, and
# the commit has to carry down writes made since the rebuild.
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH" "$SNAPSHOT_PATH" "$WORK/virt-install.args"

define_domain
run_migrant snapshot
PATH="$WORK/fakebin:$PATH" run_migrant reset
if [[ -f "$DISK_PATH" ]] \
    && qemu-img info "$DISK_PATH" | grep -qF "backing file: $SNAPSHOT_PATH"; then
  pass "reset leaves the disk as an overlay on the default slot"
else
  fail "reset did not produce an overlay on the default slot: $(qemu-img info "$DISK_PATH" 2>&1 || true)"
fi

# Stand in for guest writes after the rebuild. 'convert -n' writes into the
# existing overlay instead of replacing it, so the backing chain survives and
# there is a real delta for the commit to carry down.
head -c 65536 /dev/urandom > "$WORK/marker2.bin"
qemu-img convert -n -f raw -O qcow2 "$WORK/marker2.bin" "$DISK_PATH"
chmod 666 "$DISK_PATH"

# The rebuild ran under the fake virt-install and so defined no domain. Stand a
# real one up on the overlay it created, leaving things where a real 'up' would.
cat > "$WORK/dom-commit.xml" <<EOF
<domain type='kvm'>
  <name>$VM</name>
  <memory unit='KiB'>524288</memory>
  <currentMemory unit='KiB'>524288</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$DISK_PATH'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <console type='pty'/>
  </devices>
</domain>
EOF
virsh define "$WORK/dom-commit.xml" > /dev/null

run_migrant snapshot
if (( STATUS == 0 )); then
  pass "snapshot into the slot the VM is built on succeeds"
else
  fail "snapshot onto its own backing file failed: status=$STATUS output=$OUT"
fi
if grep -qF "Updating snapshot in place" <<<"$OUT"; then
  pass "snapshot commits in place rather than converting"
else
  fail "snapshot did not take the commit path: status=$STATUS output=$OUT"
fi
if extracted_matches_marker "$SNAPSHOT_PATH" "$WORK/marker2.bin"; then
  pass "the committed slot holds the writes made since the rebuild"
else
  fail "the committed slot lost the post-rebuild writes"
fi
if [[ "$(qemu-img info "$SNAPSHOT_PATH" | grep -c '^backing file:')" == 0 ]]; then
  pass "the committed slot is still flattened, valid as a future reset source"
else
  fail "the committed slot gained a backing file of its own"
fi
if extracted_matches_marker "$DISK_PATH" "$WORK/marker2.bin"; then
  pass "the VM's disk still reads correctly after the commit"
else
  fail "the VM's disk no longer reads correctly after the commit"
fi

# The committed slot must still drive a rebuild, so the checkpoint loop closes.
virsh destroy "$VM" &>/dev/null || true
PATH="$WORK/fakebin:$PATH" run_migrant reset
if grep -q "fake virt-install invoked" <<<"$OUT" \
    && qemu-img info "$DISK_PATH" | grep -qF "backing file: $SNAPSHOT_PATH"; then
  pass "reset rebuilds from the committed slot"
else
  fail "reset could not rebuild from the committed slot: status=$STATUS output=$OUT"
fi

# A VM on a plain base image is untouched by all this: it still converts, and
# the shared base image must not be written to.
virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH" "$SNAPSHOT_PATH" "$WORK/virt-install.args"
BASE_IMG="$IMAGES_DIR/commit-base.qcow2"
qemu-img convert -f raw -O qcow2 "$WORK/marker.bin" "$BASE_IMG"
qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$DISK_PATH" 10M > /dev/null
chmod 666 "$DISK_PATH"
sed "s|<source file='.*'/>|<source file='$DISK_PATH'/>|" "$WORK/dom-commit.xml" \
  > "$WORK/dom-base.xml"
virsh define "$WORK/dom-base.xml" > /dev/null
run_migrant snapshot
if (( STATUS == 0 )) && grep -qF "Creating snapshot" <<<"$OUT" \
    && ! grep -qF "Updating snapshot in place" <<<"$OUT"; then
  pass "a base-image VM still takes the convert path"
else
  fail "a base-image VM took the wrong path: status=$STATUS output=$OUT"
fi
if extracted_matches_marker "$BASE_IMG" && \
    [[ "$(qemu-img info "$BASE_IMG" | grep -c '^backing file:')" == 0 ]]; then
  pass "the shared base image is left untouched by the snapshot"
else
  fail "the shared base image was modified by the snapshot"
fi

virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
rm -f "$DISK_PATH" "$SNAPSHOT_PATH" "$BASE_IMG" "$WORK/virt-install.args" \
  "$WORK/marker2.bin" "$WORK/dom-commit.xml" "$WORK/dom-base.xml"

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
