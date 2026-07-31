#!/usr/bin/env bash
set -euo pipefail
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Integration test for the forward-port HOST_ACCESS directive. The promise is a
# port mapping: the guest reaches <ip>:<remote-port> by addressing the bridge
# gateway on <guest-port>, and by no other route.
#
# Run from a VM directory that has a working Migrantfile + cloud-init.yml:
#   cd examples/arch && ../../test/test-forward-port.sh
#
# Prerequisites:
#   - migrant setup has been run (with the updated hooks)
#   - sudo, for the target namespace and for reading rules
#   - No VM with this name currently exists (the test creates and destroys one)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"

[[ -f Migrantfile ]] || { echo "[FAIL] run from a VM directory" >&2; exit 1; }
# shellcheck source=/dev/null
source Migrantfile

NS=fptest
VETH_HOST=fptest0
VETH_NS=fptest1
HOST_IP=10.99.0.1
TARGET_IP=10.99.0.2
DECOY_IP=10.99.0.3          # routed, nothing listening
TARGET_PORT=11434
GUEST_PORT=18080            # deliberately different from the remote port
GATEWAY=192.168.200.1
STATE="/run/migrant/${VM_NAME}.state"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  set +e
  sudo ip netns pids "$NS" 2>/dev/null | xargs -r sudo kill 2>/dev/null
  sudo ip netns del "$NS" 2>/dev/null
  sudo ip link del "$VETH_HOST" 2>/dev/null
  virsh dominfo "$VM_NAME" &>/dev/null && "$MIGRANT" destroy 2>/dev/null
  if [[ -f Migrantfile.test-backup ]]; then
    mv Migrantfile.test-backup Migrantfile
  fi
}
trap cleanup EXIT

cp Migrantfile Migrantfile.test-backup

echo "=== forward-port test ==="
echo "VM: $VM_NAME   mapping: ${GATEWAY}:${GUEST_PORT} -> ${TARGET_IP}:${TARGET_PORT}"
echo ""

if virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "Cleaning up leftover VM '$VM_NAME'..."
  "$MIGRANT" destroy 2>/dev/null || true
fi

# --- a genuinely routed target ---
# Not a host address: DNAT to an address the host owns is delivered locally, so
# it never traverses FORWARD and would test nothing. 10.99.0.0/24 is inside a
# range isolation rejects, so the direct probe proves the mapping is the only
# way in.
sudo ip netns del "$NS" 2>/dev/null || true
sudo ip link del "$VETH_HOST" 2>/dev/null || true
sudo ip netns add "$NS"
sudo ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
sudo ip link set "$VETH_NS" netns "$NS"
sudo ip addr add "$HOST_IP/24" dev "$VETH_HOST"
sudo ip link set "$VETH_HOST" up
sudo ip netns exec "$NS" ip link set lo up
sudo ip netns exec "$NS" ip addr add "$TARGET_IP/24" dev "$VETH_NS"
sudo ip netns exec "$NS" ip link set "$VETH_NS" up
sudo ip netns exec "$NS" ip route add default via "$HOST_IP"
sudo ip netns exec "$NS" python3 -c "
import socketserver
class H(socketserver.StreamRequestHandler):
    def handle(self): self.wfile.write(b'hello from the namespace\n')
socketserver.TCPServer(('', $TARGET_PORT), H).serve_forever()
" &
sleep 1
sudo ip netns exec "$NS" ss -lnt 2>/dev/null | grep -q ":$TARGET_PORT" \
  || { echo "[FAIL] target listener did not start" >&2; exit 1; }

cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
HOST_ACCESS=("forward-port tcp/${GUEST_PORT} ${TARGET_IP}:${TARGET_PORT}")
EOF

"$MIGRANT" up

probe() {   # probe <host> <port> -> CONNECTED | BLOCKED
  "$MIGRANT" ssh -- "timeout 3 bash -c 'exec 3<>/dev/tcp/$1/$2' >/dev/null 2>&1 && echo CONNECTED || echo BLOCKED" 2>/dev/null \
    | tr -d '\r' | tail -1
}
expect() {  # expect <want> <host> <port> <label>
  local got; got=$(probe "$2" "$3")
  if [[ "$got" == "$1" ]]; then pass "$4 -- $got"; else fail "$4 -- got ${got:-no answer}, wanted $1"; fi
}

# --- managed config ---
ha="/etc/migrant/${VM_NAME}/host-access"
if grep -qx "forward-port tcp/${GUEST_PORT} ${TARGET_IP}:${TARGET_PORT}" "$ha" 2>/dev/null; then
  pass "host-access holds the canonical directive"
else
  fail "host-access content wrong"; cat "$ha" 2>/dev/null || true
fi

# --- the teardown record ---
if grep -qx "version=2" "$STATE" 2>/dev/null; then
  pass "state record is version 2"
else
  fail "state version is '$(sed -n 's/^version=//p' "$STATE" 2>/dev/null)', expected 2"
fi
if grep -qx "forward_port=tcp/${GUEST_PORT} ${TARGET_IP}:${TARGET_PORT}" "$STATE" 2>/dev/null; then
  pass "state records the forward-port tuple"
else
  fail "state has no forward_port tuple"; cat "$STATE" 2>/dev/null || true
fi

# --- rules. iptables re-renders from a bitmask, so match on fields, not on the
# order they were written in.
tap=$(awk -F= '/^tap=/{print $2; exit}' "$STATE" 2>/dev/null || true)
dnat=$(sudo iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--physdev-in ${tap:-__none__} " | grep -- "--dport $GUEST_PORT") || dnat=""
if [[ -n "$dnat" ]] && grep -q -- "-d ${GATEWAY}/32" <<<"$dnat" \
    && grep -q -- "--to-destination ${TARGET_IP}:${TARGET_PORT}" <<<"$dnat"; then
  pass "DNAT is scoped to the gateway and points at the target"
else
  fail "DNAT wrong or missing"; echo "${dnat:-none}"
fi

acc=$(sudo iptables -S FORWARD 2>/dev/null | grep -- "--physdev-in ${tap:-__none__} " | grep -- "--ctorigdstport $GUEST_PORT") || acc=""
if [[ -n "$acc" ]] && grep -q -- "--ctorigdst $GATEWAY" <<<"$acc" \
    && grep -q -- "-d ${TARGET_IP}/32" <<<"$acc" \
    && ! grep -q 'RELATED' <<<"$acc"; then
  pass "FORWARD ACCEPT matches the conntrack original destination, without RELATED"
else
  fail "FORWARD ACCEPT wrong or missing"; echo "${acc:-none}"
fi

# --- behaviour: one port, one way in ---
expect CONNECTED "$GATEWAY" "$GUEST_PORT" "gateway:$GUEST_PORT reaches the target"
expect BLOCKED "$TARGET_IP" "$TARGET_PORT" "target:$TARGET_PORT direct, bypassing the gateway"
expect BLOCKED "$TARGET_IP" 22 "target:22, an unmapped port on the target"
expect BLOCKED "$DECOY_IP" "$GUEST_PORT" "$DECOY_IP:$GUEST_PORT, another address on the guest port"
expect BLOCKED "$GATEWAY" "$TARGET_PORT" "gateway:$TARGET_PORT, the remote port is not also open"

"$MIGRANT" halt

# --- teardown ---
if [[ -n "$tap" ]] && sudo iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- "--physdev-in $tap "; then
  fail "DNAT survived halt"
else
  pass "DNAT removed on halt"
fi
if [[ -n "$tap" ]] && sudo iptables -S FORWARD 2>/dev/null | grep -q -- "--ctorigdstport $GUEST_PORT"; then
  fail "FORWARD ACCEPT survived halt"
else
  pass "FORWARD ACCEPT removed on halt"
fi
if [[ -f "$STATE" ]]; then
  fail "state record survived halt"
else
  pass "state record removed on halt"
fi

"$MIGRANT" destroy

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  exit 1
fi
