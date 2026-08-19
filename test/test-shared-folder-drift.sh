#!/usr/bin/env bash
set -euo pipefail
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Integration test for shared-folder path drift detection on 'migrant up' and
# 'migrant status'. Run from anywhere:
#   test/test-shared-folder-drift.sh
#
# Like test-resources.sh, this needs no real VM directory or base image: the
# check runs before 'virsh start' and reads only the domain's <filesystem>
# elements, so a diskless domain defined straight from XML exercises every
# code path. SHARED_FOLDER_ISOLATION=false for the 'up' cases so no loop image
# or mount is needed and no sudo is required; the status cases flip it on and
# fake the .img file's presence with 'touch', since cmd_status only checks
# that the file exists.
#
# Prerequisites:
#   - libvirt reachable at qemu:///system
#   - No domain named "migrant-drift-test" exists

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"
VM="migrant-drift-test"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

if virsh dominfo "$VM" &>/dev/null; then
  echo "[FAIL] domain '$VM' already exists; remove it first." >&2
  exit 1
fi

WORK=$(mktemp -d)
cleanup() {
  virsh destroy "$VM" &>/dev/null || true
  virsh undefine "$VM" &>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

cd "$WORK"

cat > cloud-init.yml <<'EOF'
users:
  - name: migrant
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY test@example
EOF

# Usage: write_migrantfile shared_folders_array_literal [isolation]
# shared_folders_array_literal is the literal contents between the parens of
# SHARED_FOLDERS=(...), e.g. '"workspace:workspace"'.
write_migrantfile() {
  cat > Migrantfile <<EOF
VM_NAME="$VM"
OS_VARIANT="archlinux"
RAM_MB=1024
VCPUS=1
IMAGE_URL="https://example.invalid/x.qcow2"
DISK_GB=40
SHARED_FOLDERS=(${1:-})
SHARED_FOLDER_ISOLATION=${2:-false}
NETWORK_ISOLATION=false
NETWORKS=()
EOF
}

# Usage: define_domain [source_dir [target_tag]]
# Omit source_dir to define a domain with no <filesystem> device at all.
define_domain() {
  virsh destroy "$VM" &>/dev/null || true
  virsh undefine "$VM" &>/dev/null || true
  local fs=""
  if [[ -n "${1:-}" ]]; then
    fs="<filesystem type='mount' accessmode='passthrough'><driver type='virtiofs'/><source dir='$1'/><target dir='${2:-workspace}'/></filesystem>"
  fi
  cat > dom.xml <<EOF
<domain type='kvm'>
  <name>$VM</name>
  <memory unit='KiB'>1048576</memory>
  <currentMemory unit='KiB'>1048576</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <memoryBacking><source type='memfd'/><access mode='shared'/></memoryBacking>
  <devices><console type='pty'/>$fs</devices>
</domain>
EOF
  virsh define dom.xml > /dev/null
}

# The domain has no OS, so 'up' blocks in wait_for_ip after starting it (when
# it gets that far at all). The drift check happens well before that, so a
# timeout is the natural bound. Sets UP_OUT/UP_STATUS rather than echoing:
# capturing with $(...) would run this in a subshell and lose the status.
UP_OUT=""
UP_STATUS=0
run_up() {
  set +e
  timeout 25 "$MIGRANT" up > up.out 2>&1
  UP_STATUS=$?
  set -e
  UP_OUT=$(cat up.out)
}

# --- 1. no SHARED_FOLDERS configured: nothing to check ------------------------
define_domain
write_migrantfile ''
run_up; out="$UP_OUT"
if grep -q 'exists but is not running' <<<"$out"; then
  pass "no shared folders: reaches the start path"
else
  fail "no shared folders blocked 'up': $out"
fi
if grep -q 'shared folder path drift' <<<"$out"; then
  fail "no shared folders produced a drift error anyway: $out"
else
  pass "no shared folders: no drift error"
fi

# --- 2. matching path: silent, VM starts ---------------------------------------
virsh destroy "$VM" >/dev/null 2>&1 || true
define_domain "$WORK/workspace" workspace
write_migrantfile '"workspace:workspace"'
run_up; out="$UP_OUT"
if grep -q 'shared folder path drift' <<<"$out"; then
  fail "matching path produced a drift error: $out"
else
  pass "matching path: no drift error"
fi
if grep -q 'exists but is not running' <<<"$out" && [[ "$(virsh domstate "$VM")" == "running" ]]; then
  pass "matching path: VM starts"
else
  fail "matching path blocked the start (state=$(virsh domstate "$VM")): $out"
fi

# --- 3. drifted path: hard error, VM not started, domain left defined ---------
virsh destroy "$VM" >/dev/null 2>&1 || true
OLD_DIR="$WORK/old-location/workspace"
mkdir -p "$OLD_DIR"
define_domain "$OLD_DIR" workspace
write_migrantfile '"workspace:workspace"'
run_up; out="$UP_OUT"
if (( UP_STATUS == 78 )); then
  pass "drifted path: exits 78"
else
  fail "drifted path: exit status was $UP_STATUS, output: $out"
fi
if grep -q "\[ERROR\] VM '$VM' shared folder path drift" <<<"$out" \
    && grep -q "'workspace' expects $WORK/workspace but the VM was built with $OLD_DIR" <<<"$out"; then
  pass "drifted path: names the entry and both paths"
else
  fail "drifted path: unexpected message: $out"
fi
if grep -q "Run 'migrant destroy' first" <<<"$out"; then
  pass "drifted path: names the remedy"
else
  fail "drifted path: no remedy given: $out"
fi
if grep -q 'exists but is not running. Starting' <<<"$out"; then
  fail "drifted path: reached the start path anyway: $out"
else
  pass "drifted path: never reached the start path"
fi
if [[ "$(virsh domstate "$VM")" != "running" ]]; then
  pass "drifted path: VM was not started"
else
  fail "drifted path: VM ended up running"
fi
if virsh dominfo "$VM" &>/dev/null; then
  pass "drifted path: domain left defined, not destroyed"
else
  fail "drifted path: domain was destroyed"
fi

# --- 4. drift is reported the same with SHARED_FOLDER_ISOLATION=false ---------
# The source path is baked into the domain either way; isolation only affects
# whether it is backed by a loop-mounted image.
virsh destroy "$VM" >/dev/null 2>&1 || true
define_domain "$OLD_DIR" workspace
write_migrantfile '"workspace:workspace"' false
run_up; out="$UP_OUT"
if (( UP_STATUS == 78 )) && grep -q 'shared folder path drift' <<<"$out"; then
  pass "drift is caught with SHARED_FOLDER_ISOLATION=false"
else
  fail "SHARED_FOLDER_ISOLATION=false: status=$UP_STATUS output=$out"
fi

# --- 5. only the entry that actually drifted is named --------------------------
virsh destroy "$VM" >/dev/null 2>&1 || true
mkdir -p "$WORK/data"
cat > dom.xml <<EOF
<domain type='kvm'>
  <name>$VM</name>
  <memory unit='KiB'>1048576</memory>
  <currentMemory unit='KiB'>1048576</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <memoryBacking><source type='memfd'/><access mode='shared'/></memoryBacking>
  <devices>
    <console type='pty'/>
    <filesystem type='mount' accessmode='passthrough'><driver type='virtiofs'/><source dir='$OLD_DIR'/><target dir='workspace'/></filesystem>
    <filesystem type='mount' accessmode='passthrough'><driver type='virtiofs'/><source dir='$WORK/data'/><target dir='data'/></filesystem>
  </devices>
</domain>
EOF
virsh undefine "$VM" &>/dev/null || true
virsh define dom.xml > /dev/null
write_migrantfile '"workspace:workspace" "data:data"'
run_up; out="$UP_OUT"
if grep -q "'workspace' expects" <<<"$out" && ! grep -q "'data' expects" <<<"$out"; then
  pass "only the drifted entry is named, the matching one is silent"
else
  fail "multi-entry drift report: $out"
fi

# --- 6. an unreadable domain degrades to no error, not a failure --------------
# Shadow virsh on PATH so dumpxml fails. The check is best-effort: a libvirt
# hiccup must not take down 'up' against an otherwise healthy VM.
virsh destroy "$VM" >/dev/null 2>&1 || true
define_domain "$OLD_DIR" workspace
write_migrantfile '"workspace:workspace"'
mkdir -p fakebin
cat > fakebin/virsh <<'WRAP'
#!/usr/bin/env bash
for a in "$@"; do
  [[ "$a" == "dumpxml" ]] && { echo "error: injected dumpxml failure" >&2; exit 1; }
done
exec /usr/bin/virsh "$@"
WRAP
chmod +x fakebin/virsh
set +e
PATH="$PWD/fakebin:$PATH" timeout 25 "$MIGRANT" up > up.log 2>&1
rc=$?
set -e
if grep -q 'exists but is not running' up.log; then
  pass "an unreadable domain still reaches the start path"
else
  fail "unreadable domain aborted 'up' (status=$rc): $(cat up.log)"
fi
if grep -q 'shared folder path drift' up.log; then
  fail "unreadable domain produced a drift error anyway: $(cat up.log)"
else
  pass "unreadable domain reports no drift"
fi
rm -rf fakebin

# --- 7. status carries the same drift ------------------------------------------
# 'up' is what you run after moving the directory; 'status' is where you look
# without running anything. Drift has to be visible in both. Isolation must be
# on for the 'loop:' row to appear at all; a plain 'touch' stands in for the
# real loop image since cmd_status only checks that the file exists.
virsh destroy "$VM" >/dev/null 2>&1 || true
define_domain "$WORK/workspace" workspace
write_migrantfile '"workspace:workspace"' true
touch "$WORK/workspace.img"
out=$("$MIGRANT" status 2>&1)
if grep -qE '^loop: +.*workspace\.img$' <<<"$out" && ! grep -q '\[ERROR\]' <<<"$out"; then
  pass "status: matching path has a plain loop: row"
else
  fail "status (no drift): $out"
fi

define_domain "$OLD_DIR" workspace
out=$("$MIGRANT" status 2>&1)
if grep -qE '^loop: +.*workspace\.img \[ERROR\]$' <<<"$out" \
    && grep -q "note: *VM was built with $OLD_DIR" <<<"$out"; then
  pass "status: drifted path is flagged with the built-with directory"
else
  fail "status (drift): $out"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
