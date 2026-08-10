#!/usr/bin/env bash
set -euo pipefail
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Integration test for RAM_MB/VCPUS reconciliation on 'migrant up'.
# Run from anywhere:
#   test/test-reconcile.sh
#
# Unlike the other integration tests, this one does not need a real VM
# directory or a base image: reconciliation runs before 'virsh start', so a
# diskless domain defined straight from XML exercises every code path. The
# domain is defined and undefined by the test.
#
# Prerequisites:
#   - libvirt reachable at qemu:///system
#   - No domain named "migrant-reconcile-test" exists

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"
VM="migrant-reconcile-test"

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

write_migrantfile() {
  cat > Migrantfile <<EOF
VM_NAME="$VM"
OS_VARIANT="archlinux"
RAM_MB=$1
VCPUS=$2
DISK_GB=40
IMAGE_URL="https://example.invalid/x.qcow2"
SHARED_FOLDERS=()
SHARED_FOLDER_ISOLATION=false
NETWORK_ISOLATION=false
NETWORKS=()
EOF
}

define_domain() {
  cat > dom.xml <<EOF
<domain type='kvm'>
  <name>$VM</name>
  <memory unit='KiB'>$(( $1 * 1024 ))</memory>
  <currentMemory unit='KiB'>$(( $1 * 1024 ))</currentMemory>
  <vcpu placement='static'>$2</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <devices><console type='pty'/></devices>
</domain>
EOF
  virsh define dom.xml > /dev/null
}

# The domain has no OS, so 'up' blocks in wait_for_ip after starting it.
# Reconciliation happens well before that, so a timeout is the natural bound.
# Sets UP_OUT and UP_STATUS rather than echoing: capturing the output with $(...)
# would run this in a subshell and lose the status.
UP_OUT=""
UP_STATUS=0
run_up() {
  set +e
  timeout 25 "$MIGRANT" up > up.out 2>&1
  UP_STATUS=$?
  set -e
  UP_OUT=$(cat up.out)
}

mem_kib() {
  local xml max cur
  xml=$(LC_ALL=C virsh dumpxml --inactive "$VM")
  max=$(LC_ALL=C awk -F'[<>]' '/<memory /{print $3; exit}' <<<"$xml")
  cur=$(LC_ALL=C awk -F'[<>]' '/<currentMemory /{print $3; exit}' <<<"$xml")
  [[ -z "$cur" ]] && cur="$max"
  echo "$max $cur"
}
vcpus() {
  printf '%s %s' \
    "$(virsh vcpucount "$VM" --config --maximum)" \
    "$(virsh vcpucount "$VM" --config --active)"
}
# Specific fields only: 'virsh define' normalizes XML and materializes
# defaults, so whole-document comparison is meaningless.
assert_state() {
  local want_kib="$1" want_vcpus="$2" label="$3"
  local got_mem got_cpu
  got_mem=$(mem_kib); got_cpu=$(vcpus)
  if [[ "$got_mem" == "$want_kib $want_kib" && "$got_cpu" == "$want_vcpus $want_vcpus" ]]; then
    pass "$label"
  else
    fail "$label (memory='$got_mem' want='$want_kib $want_kib', vcpus='$got_cpu' want='$want_vcpus $want_vcpus')"
  fi
}

# --- 1. grow -----------------------------------------------------------------
define_domain 1024 1
write_migrantfile 2048 2
run_up; out="$UP_OUT"
if grep -q 'Reconciling resources: RAM 1024 -> 2048 MB, vCPUs 1 -> 2\.' <<<"$out"; then
  pass "grow announces both changes"
else
  fail "grow announcement missing: $out"
fi
assert_state 2097152 2 "grow applied to persistent definition"

# --- 2. warn while running ---------------------------------------------------
write_migrantfile 4096 3
run_up; out="$UP_OUT"
if grep -q '\[WARNING\] Migrantfile resources differ' <<<"$out"; then
  pass "running VM warns"
else
  fail "running VM did not warn: $out"
fi
assert_state 2097152 2 "running VM definition untouched"

# 'up' must still succeed on the warn path so 'migrant up && ...' keeps working.
write_migrantfile 4096 3
if timeout 25 "$MIGRANT" up >/dev/null 2>&1; then
  pass "warn path exits 0"
else
  fail "warn path exited non-zero"
fi

# --- 3. shrink ---------------------------------------------------------------
virsh destroy "$VM" >/dev/null 2>&1 || true
write_migrantfile 1024 1
run_up; out="$UP_OUT"
if grep -q 'shrink; Migrantfile is authoritative' <<<"$out"; then
  pass "shrink is called out explicitly"
else
  fail "shrink not announced: $out"
fi
assert_state 1048576 1 "shrink applied to persistent definition"

# --- 4. no drift is silent ---------------------------------------------------
# Absence of output is only meaningful if 'up' actually got past reconciliation,
# so this also requires the start-path message an early failure would not print.
virsh destroy "$VM" >/dev/null 2>&1 || true
run_up; out="$UP_OUT"
if ! grep -q 'exists but is not running' <<<"$out"; then
  fail "no-drift run never reached the start path: $out"
elif grep -qE 'Reconciling resources|Migrantfile resources differ' <<<"$out"; then
  fail "no-drift run produced reconcile output: $out"
else
  pass "no-drift run is silent and still reached the start path"
fi

# --- 5. validation -----------------------------------------------------------
virsh destroy "$VM" >/dev/null 2>&1 || true
# Both the diagnostic and the documented exit status matter: printing the error
# but returning success would still be a bug.
for bad in 16GB 8x 0 -1 99999999; do
  write_migrantfile "$bad" 2
  run_up; out="$UP_OUT"
  if grep -q "\[ERROR\] invalid RAM_MB: '$bad'" <<<"$out" && (( UP_STATUS == 78 )); then
    pass "rejects RAM_MB=$bad with exit 78"
  else
    fail "RAM_MB=$bad: status=$UP_STATUS output=$out"
  fi
done
for bad in 2x 0 99999; do
  write_migrantfile 1024 "$bad"
  run_up; out="$UP_OUT"
  if grep -q "\[ERROR\] invalid VCPUS: '$bad'" <<<"$out" && (( UP_STATUS == 78 )); then
    pass "rejects VCPUS=$bad with exit 78"
  else
    fail "VCPUS=$bad: status=$UP_STATUS output=$out"
  fi
done

# A leading zero is decimal, not octal, and not an error.
virsh destroy "$VM" >/dev/null 2>&1 || true
write_migrantfile 08 1
run_up; out="$UP_OUT"
if grep -q 'value too great for base' <<<"$out"; then
  fail "leading-zero RAM_MB hit octal arithmetic"
elif grep -q 'RAM 1024 -> 8 MB' <<<"$out"; then
  pass "RAM_MB=08 is read as decimal 8"
else
  fail "RAM_MB=08 produced unexpected output: $out"
fi
assert_state 8192 1 "RAM_MB=08 applied 8 MB to the definition"

# --- 6. rollback on partial failure ------------------------------------------
# Shadow virsh on PATH and fail one mutation mid-sequence. The wrapper
# delegates through an absolute path so it never recurses into itself.
virsh destroy "$VM" >/dev/null 2>&1 || true
mkdir -p fakebin
cat > fakebin/virsh <<'WRAP'
#!/usr/bin/env bash
_is_setvcpus=false
_is_maximum=false
for a in "$@"; do
  [[ "$a" == "setvcpus" ]] && _is_setvcpus=true
  [[ "$a" == "--maximum" ]] && _is_maximum=true
done
if [[ "$_is_setvcpus" == true && "$_is_maximum" == true ]]; then
  echo "error: injected failure" >&2
  exit 9
fi
exec /usr/bin/virsh "$@"
WRAP
chmod +x fakebin/virsh

before_mem=$(mem_kib); before_cpu=$(vcpus)
write_migrantfile 2048 2
set +e
PATH="$PWD/fakebin:$PATH" timeout 25 "$MIGRANT" up > up.log 2>&1
rc=$?
set -e
if (( rc == 9 )); then
  pass "up exits with the injected status"
else
  fail "up exited $rc, expected 9"
fi
if [[ "$(mem_kib)" == "$before_mem" && "$(vcpus)" == "$before_cpu" ]]; then
  pass "rollback restored the original definition"
else
  fail "rollback left memory='$(mem_kib)' vcpus='$(vcpus)', expected '$before_mem' / '$before_cpu'"
fi
if [[ "$(virsh domstate "$VM")" == "shut off" ]]; then
  pass "VM did not start after failed reconcile"
else
  fail "VM started despite failed reconcile"
fi

# --- 7. rollback failure is reported, not swallowed ---------------------------
# Fail a mutation *and* the 'virsh define' that would undo it.
cat > fakebin/virsh <<'WRAP'
#!/usr/bin/env bash
_is_setvcpus=false
_is_maximum=false
for a in "$@"; do
  [[ "$a" == "setvcpus" ]] && _is_setvcpus=true
  [[ "$a" == "--maximum" ]] && _is_maximum=true
  [[ "$a" == "define" ]] && { echo "error: injected define failure" >&2; exit 1; }
done
if [[ "$_is_setvcpus" == true && "$_is_maximum" == true ]]; then
  echo "error: injected failure" >&2
  exit 9
fi
exec /usr/bin/virsh "$@"
WRAP
chmod +x fakebin/virsh
write_migrantfile 4096 4
set +e
PATH="$PWD/fakebin:$PATH" timeout 25 "$MIGRANT" up > up.log 2>&1
set -e
if grep -q "\[ERROR\] rollback failed" up.log; then
  pass "a failed rollback is reported"
else
  fail "failed rollback was silent: $(cat up.log)"
fi

# --- 8. unreadable resources exit 70 -----------------------------------------
# dumpxml succeeds but yields no <memory>, so the parsed value is empty.
cat > fakebin/virsh <<'WRAP'
#!/usr/bin/env bash
for a in "$@"; do
  [[ "$a" == "dumpxml" ]] && { echo "<domain></domain>"; exit 0; }
done
exec /usr/bin/virsh "$@"
WRAP
chmod +x fakebin/virsh
write_migrantfile 2048 2
set +e
PATH="$PWD/fakebin:$PATH" timeout 25 "$MIGRANT" up > up.log 2>&1
rc=$?
set -e
if (( rc == 70 )) && grep -q 'could not read current resources' up.log; then
  pass "unparseable resources exit 70"
else
  fail "unreadable resources: status=$rc output=$(cat up.log)"
fi
rm -rf fakebin

# --- 9. a paused VM is warned about, never mutated ----------------------------
# cmd_up only special-cases "running", so a paused domain reaches
# reconcile_domain_resources; the "shut off" guard is what stops the mutation.
virsh destroy "$VM" >/dev/null 2>&1 || true
write_migrantfile 1024 1
run_up >/dev/null 2>&1 || true
virsh suspend "$VM" >/dev/null 2>&1 || true
if [[ "$(virsh domstate "$VM")" == "paused" ]]; then
  before_mem=$(mem_kib); before_cpu=$(vcpus)
  write_migrantfile 8192 4
  set +e
  timeout 25 "$MIGRANT" up > up.log 2>&1
  set -e
  if grep -q '\[WARNING\] Migrantfile resources differ' up.log; then
    pass "paused VM warns"
  else
    fail "paused VM did not warn: $(cat up.log)"
  fi
  if [[ "$(mem_kib)" == "$before_mem" && "$(vcpus)" == "$before_cpu" ]]; then
    pass "paused VM definition untouched"
  else
    fail "paused VM was mutated: '$(mem_kib)' / '$(vcpus)'"
  fi
else
  fail "could not pause the VM (state=$(virsh domstate "$VM"))"
fi
virsh destroy "$VM" >/dev/null 2>&1 || true

# --- 10. reset validates before it destroys anything --------------------------
# cmd_reset tears the VM down and only then calls cmd_up, so an invalid value
# must be rejected before teardown or a working VM is lost with no rebuild.
# LIBVIRT_IMAGES_DIR redirects the snapshot stub away from the real images dir.
mkdir -p images
: > "images/${VM}-snapshot.qcow2"
write_migrantfile 16GB 2
set +e
LIBVIRT_IMAGES_DIR="$PWD/images" timeout 25 "$MIGRANT" reset > reset.log 2>&1
rc=$?
set -e
if (( rc == 78 )) && grep -q "\[ERROR\] invalid RAM_MB" reset.log; then
  pass "reset rejects an invalid RAM_MB with exit 78"
else
  fail "reset: status=$rc output=$(cat reset.log)"
fi
if virsh dominfo "$VM" &>/dev/null; then
  pass "reset left the VM defined rather than destroying it"
else
  fail "reset destroyed the VM before validating"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
