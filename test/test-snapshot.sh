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
run_migrant() {
  set +e
  LIBVIRT_IMAGES_DIR="$IMAGES_DIR" timeout 25 "$MIGRANT" "$@" > out.log 2>&1
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

extracted_matches_marker() {
  qemu-img convert -O raw "$1" extracted.raw
  cmp -s marker.bin extracted.raw
}

# Domain: a real disk backed by the marker content, no boot media. QEMU has no
# bootable device and just idles in the guest BIOS, but the process stays
# "running" — the same trick test-resources.sh uses for a diskless domain.
define_domain() {
  virsh destroy "$VM" &>/dev/null || true
  virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true
  qemu-img convert -f raw -O qcow2 marker.bin "$DISK_PATH"
  chmod 666 "$DISK_PATH"
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

set +e
PATH="$WORK/fakebin:$PATH" LIBVIRT_IMAGES_DIR="$IMAGES_DIR" timeout 25 "$MIGRANT" snapshot > out.log 2>&1
STATUS=$?
set -e
OUT=$(cat out.log)

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

set +e
PATH="$WORK/fakebin:$PATH" LIBVIRT_IMAGES_DIR="$IMAGES_DIR" timeout 25 "$MIGRANT" reset > out.log 2>&1
STATUS=$?
set -e
OUT=$(cat out.log)

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

set +e
PATH="$WORK/fakebin:$PATH" LIBVIRT_IMAGES_DIR="$IMAGES_DIR" timeout 25 "$MIGRANT" reset > out.log 2>&1
STATUS=$?
set -e
OUT=$(cat out.log)

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
set +e
PATH="$WORK/fakebin:$PATH" LIBVIRT_IMAGES_DIR="$IMAGES_DIR" _MIGRANT_RESET_MACS="52:54:00:de:ad:be" \
  timeout 25 "$MIGRANT" reset > out.log 2>&1
STATUS=$?
set -e
OUT=$(cat out.log)

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

# --- 13. reset rebuilds from a given path, ignoring the default snapshot -------
qemu-img create -f qcow2 "$SNAPSHOT_PATH" 10M > /dev/null
EXT_SNAP="$EXT_DIR/checkpoint.qcow2"
qemu-img create -f qcow2 "$EXT_SNAP" 10M > /dev/null

virsh destroy "$VM" &>/dev/null || true
virsh undefine "$VM" --remove-all-storage --nvram &>/dev/null || true

set +e
PATH="$WORK/fakebin:$PATH" LIBVIRT_IMAGES_DIR="$IMAGES_DIR" timeout 25 "$MIGRANT" reset "$EXT_SNAP" > out.log 2>&1
STATUS=$?
set -e
OUT=$(cat out.log)

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

run_migrant up
if grep -q "was built from" <<<"$OUT"; then
  fail "custom-snapshot VM falsely flagged as base-image drift: $OUT"
elif grep -q "exists but is not running. Starting" <<<"$OUT"; then
  pass "'up' does not flag drift for a VM built from a custom-named snapshot"
else
  fail "'up' did not reach the start path: status=$STATUS output=$OUT"
fi
virsh destroy "$VM" &>/dev/null || true
rm -f .migrant-base-image "$DISK_PATH"

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
