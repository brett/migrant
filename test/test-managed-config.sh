#!/usr/bin/env bash
set -euo pipefail
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Integration test for managed config and HOST_ACCESS.
# Run from a VM directory that has a working Migrantfile + cloud-init.yml:
#   cd examples/arch && ../../test/test-managed-config.sh
#
# Prerequisites:
#   - migrant setup has been run (with the updated hooks)
#   - The base image is cached (or will be downloaded)
#   - No VM named "$VM_NAME" or "$VM_NAME-rl2" exists; the test creates and
#     destroys both (the second only for the route_localnet refcount)
#   - NETWORK_ISOLATION not explicitly set to false in the Migrantfile (default is on)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"

if [[ ! -f Migrantfile ]]; then
  echo "[FAIL] No Migrantfile in $(pwd). Run from a VM directory." >&2
  exit 1
fi

# shellcheck source=/dev/null
source Migrantfile

if [[ "${NETWORK_ISOLATION:-true}" == "false" ]]; then
  echo "[FAIL] NETWORK_ISOLATION must not be disabled in the Migrantfile for this test." >&2
  exit 1
fi

MANAGED_DIR="/etc/migrant/${VM_NAME}"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

# Set by Part 8, which builds a second VM in a temp directory.
SECOND_DIR=""

cleanup() {
  # Restore original Migrantfile
  if [[ -f Migrantfile.test-backup ]]; then
    mv Migrantfile.test-backup Migrantfile
  fi
  if [[ -n "$SECOND_DIR" && -d "$SECOND_DIR" ]]; then
    ( cd "$SECOND_DIR" && "$MIGRANT" destroy ) &>/dev/null || true
    rm -rf "$SECOND_DIR"
  fi
}
trap cleanup EXIT

# Back up the Migrantfile so we can modify it for tests.
cp Migrantfile Migrantfile.test-backup

echo "=== Managed config test ==="
echo "VM: $VM_NAME"
echo "Managed dir: $MANAGED_DIR"
echo ""

# Ensure no VM exists from a previous run.
if virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "Cleaning up leftover VM '$VM_NAME'..."
  "$MIGRANT" destroy 2>/dev/null || true
fi

# ============================================================
# Part 1: sync_managed_config validation (no VM needed)
# ============================================================

echo "--- test: HOST_ACCESS validation ---"

# Test invalid directive
cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
HOST_ACCESS=("bogus-directive foo")
EOF

validation_output="/tmp/migrant-mc-test-$$.validation"
"$MIGRANT" up >"$validation_output" 2>&1 || true
if grep -q "unrecognized HOST_ACCESS directive" "$validation_output"; then
  pass "invalid directive rejected"
else
  fail "invalid directive was not rejected"
  cat "$validation_output"
  "$MIGRANT" destroy 2>/dev/null || true
fi
rm -f "$validation_output"

# Test invalid port numbers in allow-host-port
for invalid_port in 0 65536; do
  cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
HOST_ACCESS=("allow-host-port tcp/${invalid_port}")
EOF
  validation_output="/tmp/migrant-mc-test-$$.validation"
  "$MIGRANT" up >"$validation_output" 2>&1 || true
  if grep -q "port number between 1 and 65535" "$validation_output"; then
    pass "allow-host-port tcp/${invalid_port} rejected"
  else
    fail "allow-host-port tcp/${invalid_port} was not rejected"
    cat "$validation_output"
    "$MIGRANT" destroy 2>/dev/null || true
  fi
  rm -f "$validation_output"
done

# Test invalid IP in allow-lan-host
cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
HOST_ACCESS=("allow-lan-host not-an-ip")
EOF

validation_output="/tmp/migrant-mc-test-$$.validation"
"$MIGRANT" up >"$validation_output" 2>&1 || true
if grep -q "requires a numeric IPv4 address" "$validation_output"; then
  pass "non-numeric allow-lan-host IP rejected"
else
  fail "non-numeric allow-lan-host IP was not rejected"
  cat "$validation_output"
  "$MIGRANT" destroy 2>/dev/null || true
fi
rm -f "$validation_output"

# Restore clean Migrantfile for remaining tests
cp Migrantfile.test-backup Migrantfile

# ============================================================
# Part 2: managed config file creation (needs VM)
# ============================================================

echo "--- test: managed config files on up ---"
"$MIGRANT" up

if [[ -f "$MANAGED_DIR/network-isolation" ]]; then
  pass "network-isolation flag file created"
else
  fail "network-isolation flag file not found"
fi

if [[ ! -f "$MANAGED_DIR/host-access" ]]; then
  pass "host-access file absent when HOST_ACCESS is empty"
else
  fail "host-access file exists but HOST_ACCESS is empty"
fi

# Check that vm description is identity-only
local_desc=$(virsh desc "$VM_NAME" 2>/dev/null || true)
if echo "$local_desc" | grep -q "managed-by=migrant"; then
  pass "VM description contains managed-by identity"
else
  fail "VM description missing managed-by identity"
  echo "  virsh desc: '$local_desc'"
fi

if echo "$local_desc" | grep -q "network-isolation=true"; then
  fail "VM description still contains network-isolation flag (should be in managed config only)"
else
  pass "VM description does not contain behavioral flags"
fi

"$MIGRANT" halt

# ============================================================
# Part 3: HOST_ACCESS with allow-host-port
# ============================================================

echo "--- test: allow-host-port ---"
cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
HOST_ACCESS=("allow-host-port tcp/8080")
EOF

"$MIGRANT" up

if [[ -f "$MANAGED_DIR/host-access" ]]; then
  pass "host-access file created"
else
  fail "host-access file not found"
fi

if grep -q "allow-host-port tcp/8080" "$MANAGED_DIR/host-access" 2>/dev/null; then
  pass "host-access contains allow-host-port directive"
else
  fail "host-access content incorrect"
  cat "$MANAGED_DIR/host-access" 2>/dev/null || true
fi

# Check iptables — the per-VM INPUT chain should have an ACCEPT for port 8080
# before the REJECT.
chain="MIGRANT_$(printf '%s' "$VM_NAME" | md5sum | head -c8)"
if sudo iptables -L "$chain" -n 2>/dev/null | grep -q "ACCEPT.*tcp dpt:8080"; then
  pass "iptables ACCEPT rule for tcp/8080 in per-VM chain"
else
  fail "iptables ACCEPT rule for tcp/8080 not found"
  sudo iptables -L "$chain" -n 2>/dev/null || true
fi

# Verify the ACCEPT comes before the REJECT in the chain
if sudo iptables -L "$chain" -n --line-numbers 2>/dev/null \
    | awk '/ACCEPT.*tcp dpt:8080/ {accept=NR} /REJECT/ {reject=NR} END {exit (accept < reject) ? 0 : 1}'; then
  pass "ACCEPT rule is before REJECT rule in chain"
else
  fail "ACCEPT rule is not before REJECT rule"
fi

# The DNAT must carry -d 192.168.200.1/32. Unscoped it rewrites the guest's
# connections to every address on this port and delivers them to the host.
tap=$(awk -F= '/^tap=/{print $2; exit}' "/run/migrant/${VM_NAME}.state" 2>/dev/null || true)
dnat_rules=$(sudo iptables -t nat -S PREROUTING 2>/dev/null \
  | grep -- "--physdev-in ${tap:-__none__} " | grep -- "--dport 8080") || dnat_rules=""

if [[ -z "$dnat_rules" ]]; then
  fail "no DNAT rule for tcp/8080 on tap ${tap:-unknown}"
else
  unscoped=$(grep -vc -- "-d 192.168.200.1/32" <<<"$dnat_rules") || unscoped=0
  if (( unscoped == 0 )); then
    pass "allow-host-port DNAT is scoped to the bridge gateway"
  else
    fail "$unscoped DNAT rule(s) for tcp/8080 not scoped to 192.168.200.1"
    echo "$dnat_rules"
  fi
fi

# route_localnet is shared by every VM on the bridge, so it is reference
# counted; .prev holds what the host had before the first reference.
rlnet_prev=$(sudo cat /run/migrant/route-localnet/.prev 2>/dev/null || true)
rlnet_now=$(sudo sysctl -n net.ipv4.conf.virbr-migrant.route_localnet 2>/dev/null || true)
if [[ "$rlnet_now" == 1 ]]; then
  pass "route_localnet is set while an allow-host-port VM runs"
else
  fail "route_localnet is '$rlnet_now', expected 1"
fi

# Check cmd_status shows host-access
status_output=$("$MIGRANT" status 2>/dev/null) || true
if echo "$status_output" | grep -q "allow-host-port tcp/8080"; then
  pass "cmd_status displays host-access directive"
else
  fail "cmd_status does not show host-access directive"
  echo "$status_output"
fi

"$MIGRANT" halt

# Verify the per-VM INPUT chain is removed after halt
chain="MIGRANT_$(printf '%s' "$VM_NAME" | md5sum | head -c8)"
if sudo iptables -L "$chain" -n &>/dev/null; then
  fail "per-VM INPUT chain still exists after halt"
else
  pass "per-VM INPUT chain removed after halt"
fi

if [[ -n "$tap" ]] && sudo iptables -t nat -S PREROUTING 2>/dev/null \
    | grep -q -- "--physdev-in $tap "; then
  fail "DNAT for tcp/8080 not cleaned up after halt"
else
  pass "DNAT cleaned up after halt"
fi

# The bridge goes with the network when the last VM stops, taking the sysctl
# with it; either way the host must not be left more permissive than it was.
rlnet_after=$(sudo sysctl -n net.ipv4.conf.virbr-migrant.route_localnet 2>/dev/null || echo "absent")
if [[ "$rlnet_after" == "absent" || "$rlnet_after" == "${rlnet_prev:-0}" ]]; then
  pass "route_localnet restored to '${rlnet_prev:-0}' after halt (now: $rlnet_after)"
else
  fail "route_localnet is '$rlnet_after', expected '${rlnet_prev:-0}'"
fi

if sudo test -e "/run/migrant/route-localnet/${VM_NAME}"; then
  fail "route_localnet reference for $VM_NAME survived halt"
else
  pass "route_localnet reference released"
fi

# ============================================================
# Part 4: HOST_ACCESS with allow-lan-host
# ============================================================

echo "--- test: allow-lan-host ---"
cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
HOST_ACCESS=("allow-lan-host 192.168.1.50")
EOF

"$MIGRANT" up

if grep -q "allow-lan-host 192.168.1.50" "$MANAGED_DIR/host-access" 2>/dev/null; then
  pass "host-access contains allow-lan-host directive"
else
  fail "host-access content incorrect for allow-lan-host"
fi

# Check iptables FORWARD chain — should have an ACCEPT for 192.168.1.50
# The allow-lan-host rule is inserted (-I) into FORWARD, so it appears
# before the RFC1918 REJECT rules.
iface=$(cat "/run/migrant/${VM_NAME}.iface" 2>/dev/null || true)
if [[ -n "$iface" ]] && sudo iptables -L FORWARD -n 2>/dev/null \
    | grep -q "ACCEPT.*192.168.1.50"; then
  pass "iptables FORWARD ACCEPT rule for 192.168.1.50"
else
  fail "iptables FORWARD ACCEPT rule for 192.168.1.50 not found"
fi

# Verify the ACCEPT comes before the RFC1918 REJECT in FORWARD. This ordering
# is critical: if the REJECT appears first, the ACCEPT is never evaluated.
if [[ -n "$iface" ]] && sudo iptables -L FORWARD -n --line-numbers 2>/dev/null \
    | awk -v iface="$iface" '
        $0 ~ iface && /192\.168\.1\.50/ && /ACCEPT/ { accept=$1 }
        $0 ~ iface && /192\.168\.0\.0/ && /REJECT/  { reject=$1 }
        END { exit (accept != "" && reject != "" && accept+0 < reject+0) ? 0 : 1 }
      '; then
  pass "allow-lan-host ACCEPT is before RFC1918 REJECT in FORWARD"
else
  fail "allow-lan-host ACCEPT is not before RFC1918 REJECT in FORWARD"
fi

# Verify the ACCEPT carries the correct conntrack state qualifier. iptables
# renders the states from a bitmask in its own order, so compare the set.
ctstate=$(sudo iptables -S FORWARD 2>/dev/null | grep -- "-d 192.168.1.50/32" \
  | grep -o 'ctstate [A-Z,]*' | head -1 | cut -d' ' -f2) || ctstate=""
if [[ -n "$iface" && "$(tr ',' '\n' <<<"$ctstate" | sort | paste -sd,)" \
      == "ESTABLISHED,NEW,RELATED" ]]; then
  pass "allow-lan-host ACCEPT has correct conntrack state"
else
  fail "allow-lan-host ACCEPT has ctstate '${ctstate:-none}', expected NEW+ESTABLISHED+RELATED"
fi

# Check cmd_status shows allow-lan-host
status_output=$("$MIGRANT" status 2>/dev/null) || true
if echo "$status_output" | grep -q "allow-lan-host 192.168.1.50"; then
  pass "cmd_status displays allow-lan-host directive"
else
  fail "cmd_status does not show allow-lan-host directive"
  echo "$status_output"
fi

"$MIGRANT" halt

# Verify allow-lan-host rule was cleaned up on halt
if [[ -n "$iface" ]] && sudo iptables -L FORWARD -n 2>/dev/null \
    | grep -q "ACCEPT.*192.168.1.50"; then
  fail "allow-lan-host FORWARD rule not cleaned up after halt"
else
  pass "allow-lan-host FORWARD rule cleaned up after halt"
fi

# ============================================================
# Part 5: config changes take effect without destroy
# ============================================================

echo "--- test: config change without destroy ---"
# Start with HOST_ACCESS, then remove it
cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
HOST_ACCESS=("allow-host-port tcp/9999")
EOF

"$MIGRANT" up

if [[ -f "$MANAGED_DIR/host-access" ]]; then
  pass "host-access file exists after up with HOST_ACCESS"
else
  fail "host-access file missing"
fi

"$MIGRANT" halt

# Remove HOST_ACCESS and restart — host-access file should be gone
cp Migrantfile.test-backup Migrantfile
"$MIGRANT" up

if [[ ! -f "$MANAGED_DIR/host-access" ]]; then
  pass "host-access file removed when HOST_ACCESS cleared (no destroy needed)"
else
  fail "host-access file still exists after removing HOST_ACCESS"
fi

"$MIGRANT" halt

# ============================================================
# Part 6: managed dir cleanup
# ============================================================

echo "--- test: managed dir lifecycle ---"

# With NETWORK_ISOLATION on by default, the dir should exist (for the flag file)
cp Migrantfile.test-backup Migrantfile
"$MIGRANT" up
"$MIGRANT" halt

if [[ -d "$MANAGED_DIR" ]]; then
  pass "managed dir exists with default NETWORK_ISOLATION"
else
  fail "managed dir missing with default NETWORK_ISOLATION"
fi

# Disable NI and restart — if no other features need the dir, it should be removed
cat > Migrantfile <<EOF
$(sed 's/^#NETWORK_ISOLATION=false/NETWORK_ISOLATION=false/' Migrantfile.test-backup)
EOF

"$MIGRANT" up

if [[ ! -d "$MANAGED_DIR" ]]; then
  pass "managed dir removed when no features need it"
else
  # May still exist if WireGuard or other features are configured
  if [[ -z "$(ls -A "$MANAGED_DIR" 2>/dev/null)" ]]; then
    fail "managed dir exists but is empty"
  else
    pass "managed dir exists (other features configured)"
  fi
fi

# ============================================================
# Part 7: backward compatibility
# ============================================================

echo "--- test: backward compat ---"

# Restore NI and destroy+recreate to test that cmd_status works
cp Migrantfile.test-backup Migrantfile
"$MIGRANT" destroy 2>/dev/null || true
"$MIGRANT" up

status_output=$("$MIGRANT" status 2>/dev/null) || true
if echo "$status_output" | grep -q "isolation:.*enabled"; then
  pass "cmd_status shows isolation enabled from managed config"
else
  fail "cmd_status does not show isolation as enabled"
  echo "$status_output"
fi

# Final cleanup
"$MIGRANT" destroy

# ============================================================
# Part 8: route_localnet is released by the last VM, not the first
# ============================================================

echo "--- test: route_localnet refcount across two VMs ---"

# A second VM in a temp directory, minimal but for the directive under test.
# Without it a plain set-on-up/clear-on-halt implementation passes Part 3.
SECOND_DIR=$(mktemp -d)
SECOND_NAME="${VM_NAME}-rl2"
cp cloud-init.yml "$SECOND_DIR/cloud-init.yml"
cat > "$SECOND_DIR/Migrantfile" <<EOF
VM_NAME="${SECOND_NAME}"
OS_VARIANT="${OS_VARIANT}"
RAM_MB=2048
VCPUS=1
DISK_GB=${DISK_GB:-10}
IMAGE_URL="${IMAGE_URL}"
NETWORKS=("network=migrant")
HOST_ACCESS=("allow-host-port tcp/8081")
EOF

cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
HOST_ACCESS=("allow-host-port tcp/8080")
EOF

"$MIGRANT" up
rlnet_prev=$(sudo cat /run/migrant/route-localnet/.prev 2>/dev/null || true)
( cd "$SECOND_DIR" && "$MIGRANT" up )

# First VM out: the second still holds a reference, so nothing is restored.
"$MIGRANT" halt

rlnet_mid=$(sudo sysctl -n net.ipv4.conf.virbr-migrant.route_localnet 2>/dev/null || true)
if [[ "$rlnet_mid" == 1 ]]; then
  pass "route_localnet held while a second allow-host-port VM runs"
else
  fail "route_localnet is '$rlnet_mid' with a VM still using allow-host-port"
fi

if sudo test -e "/run/migrant/route-localnet/${SECOND_NAME}"; then
  pass "second VM still holds its reference"
else
  fail "second VM's route_localnet reference is missing"
fi

# Last VM out restores the host.
( cd "$SECOND_DIR" && "$MIGRANT" halt )

rlnet_end=$(sudo sysctl -n net.ipv4.conf.virbr-migrant.route_localnet 2>/dev/null || echo "absent")
if [[ "$rlnet_end" == "absent" || "$rlnet_end" == "${rlnet_prev:-0}" ]]; then
  pass "route_localnet restored once the last VM stopped (now: $rlnet_end)"
else
  fail "route_localnet is '$rlnet_end', expected '${rlnet_prev:-0}'"
fi

if sudo test -e /run/migrant/route-localnet/.prev; then
  fail "saved route_localnet value survived the last VM"
else
  pass "saved route_localnet value cleared"
fi

( cd "$SECOND_DIR" && "$MIGRANT" destroy )
rm -rf "$SECOND_DIR"
SECOND_DIR=""
"$MIGRANT" destroy

# ============================================================
# Summary
# ============================================================

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  exit 1
fi
