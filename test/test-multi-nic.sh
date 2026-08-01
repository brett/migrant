#!/usr/bin/env bash
set -euo pipefail
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Integration test for a VM with more than one NIC. Rules are scoped per tap,
# so a second NIC that receives none of them is a VM with no isolation on that
# interface -- and nothing reports it, which is why this needs a test rather
# than a reading.
#
# The shared chains are the other half: they are per VM, not per tap, so a loop
# that recreates them for every NIC would flush the first tap's work and leave
# duplicate ACCEPTs behind.
#
# Run from a VM directory that has a working Migrantfile + cloud-init.yml:
#   cd examples/arch && ../../test/test-multi-nic.sh
#
# Prerequisites:
#   - migrant setup has been run (with the updated hooks)
#   - sudo, for reading the rules
#   - No VM with this name currently exists (the test creates and destroys one)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"

[[ -f Migrantfile ]] || { echo "[FAIL] run from a VM directory" >&2; exit 1; }
# shellcheck source=/dev/null
source Migrantfile

STATE="/run/migrant/${VM_NAME}.state"
CHAIN="MIGRANT_$(printf '%s' "$VM_NAME" | md5sum | head -c8)"
HOST_PORT=8080

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  set +e
  virsh dominfo "$VM_NAME" &>/dev/null && "$MIGRANT" destroy 2>/dev/null
  if [[ -f Migrantfile.test-backup ]]; then
    mv Migrantfile.test-backup Migrantfile
  fi
}
trap cleanup EXIT

cp Migrantfile Migrantfile.test-backup

echo "=== multi-NIC test ==="
echo "VM: $VM_NAME"
echo ""

if virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "Cleaning up leftover VM '$VM_NAME'..."
  "$MIGRANT" destroy 2>/dev/null || true
fi

# Two NICs on the same network is enough: the rules key on the tap, not on
# which network is behind it, and it needs no second libvirt network.
cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
NETWORKS=(
  "network=migrant"
  "network=migrant"
)
HOST_ACCESS=("allow-host-port tcp/${HOST_PORT}")
EOF

"$MIGRANT" up

mapfile -t taps < <(awk -F= '/^tap=/{print $2}' "$STATE" 2>/dev/null || true)
mapfile -t macs < <(awk -F= '/^mac=/{print $2}' "$STATE" 2>/dev/null || true)

if (( ${#taps[@]} == 2 )); then
  pass "two taps recorded: ${taps[*]}"
else
  fail "recorded ${#taps[@]} tap(s), expected 2: ${taps[*]-none}"
  echo "  a single tap here means the hook still resolves only the first NIC"
fi
if (( ${#macs[@]} == 2 )); then
  pass "two MACs recorded"
else
  fail "recorded ${#macs[@]} MAC(s), expected 2"
fi

# --- every per-tap rule must exist for every tap ---
for tap in "${taps[@]+"${taps[@]}"}"; do
  if sudo iptables -S INPUT 2>/dev/null | grep -q -- "--physdev-in $tap .*-j $CHAIN"; then
    pass "$tap jumps to the per-VM INPUT chain"
  else
    fail "$tap has no jump to $CHAIN"
  fi

  # iptables prints -p before -m physdev, so match on fields, not on order.
  if sudo iptables -S INPUT 2>/dev/null | grep -- "--physdev-in $tap " \
      | grep -- '-p icmp' | grep -q -- '-j REJECT'; then
    pass "$tap has the ICMP reject"
  else
    fail "$tap has no ICMP reject"
    sudo iptables -S INPUT 2>/dev/null | grep -- "--physdev-in $tap " || true
  fi

  n=$(sudo iptables -S FORWARD 2>/dev/null | grep -c -- "--physdev-in $tap .*-j REJECT") || n=0
  if (( n == 5 )); then
    pass "$tap has all 5 FORWARD rejects"
  else
    fail "$tap has $n FORWARD rejects, expected 5"
  fi

  if sudo ip6tables -S FORWARD 2>/dev/null | grep -q -- "--physdev-in $tap .*-j DROP"; then
    pass "$tap drops IPv6 egress"
  else
    fail "$tap has no IPv6 FORWARD drop"
  fi

  if sudo iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- "--physdev-in $tap .*--dport $HOST_PORT"; then
    pass "$tap has the allow-host-port DNAT"
  else
    fail "$tap has no allow-host-port DNAT"
  fi
done

# --- the shared chain is per VM, not per tap ---
n=$(sudo iptables -S "$CHAIN" 2>/dev/null | grep -c -- "--dport $HOST_PORT") || n=0
if (( n == 1 )); then
  pass "the shared chain holds exactly one ACCEPT for tcp/$HOST_PORT"
else
  fail "the shared chain holds $n ACCEPTs for tcp/$HOST_PORT, expected 1"
  echo "  more than one means the chain is being filled once per tap"
fi
n=$(sudo iptables -S "$CHAIN" 2>/dev/null | grep -c 'ctstate NEW -j REJECT') || n=0
if (( n == 1 )); then
  pass "the shared chain holds exactly one NEW-REJECT"
else
  fail "the shared chain holds $n NEW-REJECTs, expected 1"
fi

# --- the guest is released on every NIC ---
blocked=0
for mac in "${macs[@]+"${macs[@]}"}"; do
  sudo nft list set bridge migrant blocked_macs 2>/dev/null | grep -q "$mac" && (( blocked++ )) || true
done
if (( blocked == 0 )); then
  pass "no MAC left blocked at the bridge"
else
  fail "$blocked MAC(s) still blocked — that NIC has no network"
fi

"$MIGRANT" halt

# --- teardown covers every tap ---
left=0
for tap in "${taps[@]+"${taps[@]}"}"; do
  n=$(sudo iptables -S 2>/dev/null | grep -c -- "--physdev-in $tap ") || n=0
  m=$(sudo ip6tables -S 2>/dev/null | grep -c -- "--physdev-in $tap ") || m=0
  o=$(sudo iptables -t nat -S 2>/dev/null | grep -c -- "--physdev-in $tap ") || o=0
  if (( n + m + o == 0 )); then
    pass "$tap has no rules left after halt"
  else
    fail "$tap has $((n + m + o)) rule(s) left after halt"
    left=1
  fi
done
if (( left == 0 )) && ! sudo iptables -S "$CHAIN" &>/dev/null; then
  pass "the per-VM chain is gone"
else
  fail "the per-VM chain survived halt"
fi

"$MIGRANT" destroy

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  exit 1
fi
