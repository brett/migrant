#!/usr/bin/env bash
set -euo pipefail
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Integration test for RAM_MB/VCPUS drift warnings and validation on
# 'migrant up' and 'migrant reset'. Run from anywhere:
#   test/test-resources.sh
#
# Unlike the other integration tests, this one does not need a real VM
# directory or a base image: the drift check runs before 'virsh start', so a
# diskless domain defined straight from XML exercises every code path. The
# domain is defined and undefined by the test.
#
# Prerequisites:
#   - libvirt reachable at qemu:///system
#   - No domain named "migrant-resource-test" exists

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"
VM="migrant-resource-test"

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

# Usage: write_migrantfile RAM_MB VCPUS [DISK_GB]
# DISK_GB is settable so the reset preflight can be tested with it unset.
write_migrantfile() {
  cat > Migrantfile <<EOF
VM_NAME="$VM"
OS_VARIANT="archlinux"
RAM_MB=$1
VCPUS=$2
IMAGE_URL="https://example.invalid/x.qcow2"
SHARED_FOLDERS=()
SHARED_FOLDER_ISOLATION=false
NETWORK_ISOLATION=false
NETWORKS=()
EOF
  [[ "${3-40}" == "unset" ]] || echo "DISK_GB=${3-40}" >> Migrantfile
}

# Undefine first: the XML carries no <uuid>, so redefining over a domain libvirt
# has already assigned one to fails on the name.
define_domain() {
  virsh destroy "$VM" &>/dev/null || true
  virsh undefine "$VM" &>/dev/null || true
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
# The drift check happens well before that, so a timeout is the natural bound.
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

# --- 1. a stopped VM warns and starts anyway, unmodified ----------------------
# The whole point of warn-only: 'up' reports the mismatch, leaves the domain
# definition exactly as it found it, and still starts the VM.
define_domain 1024 1
write_migrantfile 2048 2
run_up; out="$UP_OUT"
if grep -q 'RAM 2048 MB requested, 1024 MB defined, vCPUs 2 requested, 1 defined' <<<"$out"; then
  pass "stopped VM reports both resources"
else
  fail "stopped VM drift not reported: $out"
fi
if grep -q "Run 'migrant destroy && migrant up' to rebuild" <<<"$out"; then
  pass "warning names the rebuild commands"
else
  fail "warning gave no remedy: $out"
fi
# The start-path message alone proves nothing: it is printed before the hooks
# and 'virsh start'. Only the domain's state shows the VM actually came up.
if grep -q 'exists but is not running' <<<"$out" \
    && [[ "$(virsh domstate "$VM")" == "running" ]]; then
  pass "stopped VM still starts despite drift"
else
  fail "drift blocked the start (state=$(virsh domstate "$VM")): $out"
fi
assert_state 1048576 1 "stopped VM definition untouched"

# --- 2. warn while running ----------------------------------------------------
write_migrantfile 4096 3
run_up; out="$UP_OUT"
if grep -q '\[WARNING\] Migrantfile resources differ' <<<"$out"; then
  pass "running VM warns"
else
  fail "running VM did not warn: $out"
fi
assert_state 1048576 1 "running VM definition untouched"

# 'up' must still succeed on the warn path so 'migrant up && ...' keeps working.
if timeout 25 "$MIGRANT" up >/dev/null 2>&1; then
  pass "warn path exits 0"
else
  fail "warn path exited non-zero"
fi

# --- 3. the warning is symmetric ----------------------------------------------
# Nothing is applied, so asking for less is reported exactly like asking for
# more — no shrink wording, no claim about which value wins.
virsh destroy "$VM" >/dev/null 2>&1 || true
define_domain 4096 4
write_migrantfile 1024 1
run_up; out="$UP_OUT"
if grep -q 'RAM 1024 MB requested, 4096 MB defined, vCPUs 1 requested, 4 defined' <<<"$out"; then
  pass "a downward difference reads the same as an upward one"
else
  fail "downward difference mis-reported: $out"
fi
assert_state 4194304 4 "downward difference changes nothing"

# --- 4. no drift is silent ----------------------------------------------------
# Absence of output is only meaningful if 'up' actually got past the check,
# so this also requires the start-path message an early failure would not print.
virsh destroy "$VM" >/dev/null 2>&1 || true
write_migrantfile 4096 4
run_up; out="$UP_OUT"
if ! grep -q 'exists but is not running' <<<"$out"; then
  fail "no-drift run never reached the start path: $out"
elif grep -q 'Migrantfile resources differ' <<<"$out"; then
  fail "no-drift run produced a warning: $out"
else
  pass "no-drift run is silent and still reached the start path"
fi

# --- 5. drift in the current value is reported against the current value ------
# Drift is detected against maximum *or* current, but naming the maximum would
# render a real difference as "4096 MB requested, 4096 MB defined".
virsh destroy "$VM" >/dev/null 2>&1 || true
define_domain 4096 2
virsh setmem "$VM" 2097152KiB --config > /dev/null
write_migrantfile 4096 2
run_up; out="$UP_OUT"
if grep -q 'RAM 4096 MB requested, 2048 MB defined' <<<"$out"; then
  pass "warning names the current allocation, not the maximum"
else
  fail "expected 'RAM 4096 MB requested, 2048 MB defined': $out"
fi

# --- 6. validation ------------------------------------------------------------
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

# A leading zero is decimal, not octal, and not an error. The drift arithmetic
# is where an octal read would blow up, so this needs a domain that differs.
define_domain 1024 2
write_migrantfile 08 2
run_up; out="$UP_OUT"
if grep -q 'value too great for base' <<<"$out"; then
  fail "leading-zero RAM_MB hit octal arithmetic"
elif grep -q 'RAM 8 MB requested, 1024 MB defined' <<<"$out"; then
  pass "RAM_MB=08 is read as decimal 8"
else
  fail "RAM_MB=08 produced unexpected output: $out"
fi

# --- 7. an unreadable domain degrades to no warning, not a failure ------------
# Shadow virsh on PATH so dumpxml fails. The check is best-effort: a libvirt
# hiccup must not take down 'up' against an otherwise healthy VM.
virsh destroy "$VM" >/dev/null 2>&1 || true
mkdir -p fakebin
cat > fakebin/virsh <<'WRAP'
#!/usr/bin/env bash
for a in "$@"; do
  [[ "$a" == "dumpxml" ]] && { echo "error: injected dumpxml failure" >&2; exit 1; }
done
exec /usr/bin/virsh "$@"
WRAP
chmod +x fakebin/virsh
write_migrantfile 2048 2
set +e
PATH="$PWD/fakebin:$PATH" timeout 25 "$MIGRANT" up > up.log 2>&1
rc=$?
set -e
if grep -q 'exists but is not running' up.log; then
  pass "an unreadable domain still reaches the start path"
else
  fail "unreadable domain aborted 'up' (status=$rc): $(cat up.log)"
fi
if grep -q 'Migrantfile resources differ' up.log; then
  fail "unreadable domain produced a drift warning anyway: $(cat up.log)"
else
  pass "unreadable domain warns about nothing"
fi

# Empty output parses to nothing, and must degrade the same way.
cat > fakebin/virsh <<'WRAP'
#!/usr/bin/env bash
for a in "$@"; do
  [[ "$a" == "dumpxml" ]] && { echo "<domain></domain>"; exit 0; }
done
exec /usr/bin/virsh "$@"
WRAP
chmod +x fakebin/virsh
virsh destroy "$VM" >/dev/null 2>&1 || true
set +e
PATH="$PWD/fakebin:$PATH" timeout 25 "$MIGRANT" up > up.log 2>&1
set -e
if grep -q 'exists but is not running' up.log \
    && ! grep -q 'Migrantfile resources differ' up.log; then
  pass "unparseable resources degrade to no warning"
else
  fail "unparseable resources: $(cat up.log)"
fi
rm -rf fakebin

# --- 8. a paused VM is resumed and warned about, never mutated ----------------
# A paused domain is already active. 'virsh start' is the wrong verb here and
# errors outright, so 'up' resumes it instead.
virsh destroy "$VM" >/dev/null 2>&1 || true
define_domain 1024 1
write_migrantfile 1024 1
run_up >/dev/null 2>&1 || true
virsh suspend "$VM" >/dev/null 2>&1 || true
if [[ "$(virsh domstate "$VM")" == "paused" ]]; then
  before_mem=$(mem_kib); before_cpu=$(vcpus)
  write_migrantfile 8192 4
  set +e
  timeout 25 "$MIGRANT" up > up.log 2>&1
  rc=$?
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
  if (( rc == 0 )) && grep -q "is paused. Resuming" up.log; then
    pass "paused VM is resumed rather than started"
  else
    fail "paused VM not resumed (status=$rc): $(cat up.log)"
  fi
  if [[ "$(virsh domstate "$VM")" == "running" ]]; then
    pass "paused VM is running afterward"
  else
    fail "paused VM left in state '$(virsh domstate "$VM")'"
  fi
else
  fail "could not pause the VM (state=$(virsh domstate "$VM"))"
fi
virsh destroy "$VM" >/dev/null 2>&1 || true

# --- 9. reset validates the whole Migrantfile before it destroys anything -----
# cmd_reset tears the VM down and only then calls cmd_up, so a config error must
# be caught before teardown: afterwards the VM is gone, and so are the MAC
# addresses cmd_reset collected to hand the rebuild.
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
  fail "reset (invalid RAM_MB): status=$rc output=$(cat reset.log)"
fi
if virsh dominfo "$VM" &>/dev/null; then
  pass "reset left the VM defined rather than destroying it"
else
  fail "reset destroyed the VM before validating RAM_MB"
fi

# A missing required var is the same class of bug: it used to be caught only
# inside cmd_up, which reset does not reach until the VM is already gone.
write_migrantfile 1024 2 unset
set +e
LIBVIRT_IMAGES_DIR="$PWD/images" timeout 25 "$MIGRANT" reset > reset.log 2>&1
rc=$?
set -e
if (( rc == 78 )) && grep -q "\[ERROR\] 'DISK_GB' is not set" reset.log; then
  pass "reset rejects an unset DISK_GB with exit 78"
else
  fail "reset (unset DISK_GB): status=$rc output=$(cat reset.log)"
fi
if virsh dominfo "$VM" &>/dev/null; then
  pass "reset left the VM defined rather than destroying it"
else
  fail "reset destroyed the VM before validating DISK_GB"
fi

# The same guard has to cover a missing cloud-init.yml.
write_migrantfile 1024 2
mv cloud-init.yml cloud-init.yml.bak
set +e
LIBVIRT_IMAGES_DIR="$PWD/images" timeout 25 "$MIGRANT" reset > reset.log 2>&1
rc=$?
set -e
mv cloud-init.yml.bak cloud-init.yml
if (( rc == 78 )) && grep -q "No cloud-init.yml found" reset.log; then
  pass "reset rejects a missing cloud-init.yml with exit 78"
else
  fail "reset (missing cloud-init.yml): status=$rc output=$(cat reset.log)"
fi
if virsh dominfo "$VM" &>/dev/null; then
  pass "reset left the VM defined rather than destroying it"
else
  fail "reset destroyed the VM before checking cloud-init.yml"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
