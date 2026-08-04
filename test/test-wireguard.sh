#!/usr/bin/env bash
set -euo pipefail
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Integration test for WireGuard mode. The claim is that all of a VM's traffic
# leaves through the tunnel and the guest cannot escape it, which is enforced
# entirely host-side: an fwmark on every tap, a policy rule, a routing table
# holding only the tunnel default, and DNS rewritten into it.
#
# The peer is a namespace rather than a commercial VPN: whoever reviews this has
# to be able to run it, a failure has to mean migrant rather than a provider,
# and no key worth keeping is ever committed. Keys are generated per run.
#
#   netns wgpeer
#     veth  10.98.0.2/24  <-> host 10.98.0.1/24   the "internet" the tunnel crosses
#     wg0   192.0.2.1/32, ListenPort 51820        the far end of the tunnel
#
# The tunnel's inner address sits outside every range isolation rejects. Routing
# through the tunnel does not bypass the FORWARD filter, so an address chosen
# inside 10.0.0.0/8 would be rejected before it was ever encrypted -- failing
# against a tunnel that works.
#
# Run from a VM directory that has a working Migrantfile + cloud-init.yml:
#   cd examples/arch && ../../test/test-wireguard.sh
#
# Prerequisites: migrant setup, wireguard-tools, and sudo.
# No VM with this name may exist -- the test creates and destroys one.
# The peer resolves DNS for the guest, so the run needs working DNS itself.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"

[[ -f Migrantfile ]] || { echo "[FAIL] run from a VM directory" >&2; exit 1; }
command -v wg >/dev/null || { echo "[FAIL] wireguard-tools not installed" >&2; exit 1; }
# shellcheck source=/dev/null
source Migrantfile

NS=wgpeer
VETH_HOST=wgtest0
VETH_NS=wgtest1
HOST_IP=10.98.0.1
PEER_IP=10.98.0.2          # outer transport, and the allow-lan-host target
TUNNEL_PEER=192.0.2.1      # far end of the tunnel
TUNNEL_VM=192.0.2.2        # the VM's address inside the tunnel
LISTEN_PORT=51820
TUN_SVC=9100
LAN_SVC=9101

HASH=$(printf '%s' "$VM_NAME" | md5sum | head -c7)
WG_IFACE="mg-wg-${HASH}"
WG_TABLE=$(( 16#$HASH ))
STATE="/run/migrant/${VM_NAME}.state"
MANAGED="/etc/migrant/${VM_NAME}"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  set +e
  if [[ -n "${WG_TEST_KEEP:-}" ]]; then
    echo ""
    echo "WG_TEST_KEEP set — leaving the VM, the peer namespace and wireguard.conf in place."
    echo "  guest console:  virsh console $VM_NAME     (login migrant / migrant)"
    echo "  peer:           sudo ip netns exec $NS wg show"
    echo "  clean up with:  $MIGRANT destroy; sudo ip netns del $NS; sudo ip link del $VETH_HOST"
    [[ -f Migrantfile.test-backup ]] && mv Migrantfile.test-backup Migrantfile
    return 0
  fi
  virsh dominfo "$VM_NAME" &>/dev/null && "$MIGRANT" destroy 2>/dev/null
  sudo ip netns pids "$NS" 2>/dev/null | xargs -r sudo kill 2>/dev/null
  sudo ip netns del "$NS" 2>/dev/null
  sudo iptables -t nat -D POSTROUTING -s "${PEER_IP}/32" ! -o "$VETH_HOST" -j MASQUERADE 2>/dev/null
  sudo ip link del "$VETH_HOST" 2>/dev/null
  rm -f wireguard.conf
  if [[ -f Migrantfile.test-backup ]]; then mv Migrantfile.test-backup Migrantfile; fi
}
trap cleanup EXIT

cp Migrantfile Migrantfile.test-backup

echo "=== WireGuard test ==="
echo "VM: $VM_NAME   iface: $WG_IFACE   table: $WG_TABLE"
echo ""

virsh dominfo "$VM_NAME" &>/dev/null && "$MIGRANT" destroy 2>/dev/null || true
[[ -e wireguard.conf ]] && { echo "[FAIL] a wireguard.conf already exists here; refusing to overwrite" >&2; exit 1; }

# --- the peer ---
VM_KEY=$(wg genkey); VM_PUB=$(printf '%s' "$VM_KEY" | wg pubkey)
PEER_KEY=$(wg genkey); PEER_PUB=$(printf '%s' "$PEER_KEY" | wg pubkey)

sudo ip netns del "$NS" 2>/dev/null || true
sudo ip link del "$VETH_HOST" 2>/dev/null || true
sudo ip netns add "$NS"
sudo ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
sudo ip link set "$VETH_NS" netns "$NS"
sudo ip addr add "$HOST_IP/24" dev "$VETH_HOST"
sudo ip link set "$VETH_HOST" up
sudo ip netns exec "$NS" ip link set lo up
sudo ip netns exec "$NS" ip addr add "$PEER_IP/24" dev "$VETH_NS"
sudo ip netns exec "$NS" ip link set "$VETH_NS" up

peer_conf=$(mktemp); chmod 600 "$peer_conf"
cat > "$peer_conf" <<EOF
[Interface]
PrivateKey = $PEER_KEY
ListenPort = $LISTEN_PORT
[Peer]
PublicKey = $VM_PUB
AllowedIPs = ${TUNNEL_VM}/32
EOF
sudo ip netns exec "$NS" ip link add wg0 type wireguard
sudo ip netns exec "$NS" wg setconf wg0 "$peer_conf"
rm -f "$peer_conf"
sudo ip netns exec "$NS" ip addr add "${TUNNEL_PEER}/32" dev wg0
sudo ip netns exec "$NS" ip link set wg0 up
sudo ip netns exec "$NS" ip route add "${TUNNEL_VM}/32" dev wg0

# A tunnel to nowhere is not a tunnel: the guest needs a route out.
sudo ip netns exec "$NS" sysctl -qw net.ipv4.ip_forward=1
sudo ip netns exec "$NS" ip route add default via "$HOST_IP"
sudo ip netns exec "$NS" iptables -t nat -A POSTROUTING -s "${TUNNEL_VM}/32" -o "$VETH_NS" -j MASQUERADE
sudo sysctl -qw net.ipv4.ip_forward=1
sudo iptables -t nat -C POSTROUTING -s "${PEER_IP}/32" ! -o "$VETH_HOST" -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -I POSTROUTING -s "${PEER_IP}/32" ! -o "$VETH_HOST" -j MASQUERADE

# The guest's DNS is DNATed into the tunnel, so the peer has to answer it for
# real. A resolver that refuses is worse than a slow one: timesyncd never
# resolves its NTP pool, time-sync.target is never reached, and sshd is ordered
# behind it, so the VM looks unreachable while the tunnel is fine.
UPSTREAM=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
case "$UPSTREAM" in 127.*|"") UPSTREAM=1.1.1.1 ;; esac
for proto in udp tcp; do
  sudo ip netns exec "$NS" iptables -t nat -A PREROUTING \
    -d "$TUNNEL_PEER" -p "$proto" --dport 53 -j DNAT --to-destination "${UPSTREAM}:53"
done
echo "peer forwards DNS to $UPSTREAM"

# One listener inside the tunnel, one on the transport address for the
# exclusion test. Each reports the source address it saw, so a single probe
# proves both that the connection arrived and where it appeared to come from.
sudo ip netns exec "$NS" python3 -c "
import socketserver, threading
class H(socketserver.StreamRequestHandler):
    def handle(self): self.wfile.write(('peer=%s\n' % self.client_address[0]).encode())
class S(socketserver.ThreadingTCPServer): allow_reuse_address = True
for addr, port in (('$TUNNEL_PEER', $TUN_SVC), ('$PEER_IP', $LAN_SVC)):
    threading.Thread(target=S((addr, port), H).serve_forever, daemon=True).start()
import time
while True: time.sleep(3600)
" &
sleep 1
sudo ip netns exec "$NS" ss -lnt 2>/dev/null | grep -q ":$TUN_SVC" \
  || { echo "[FAIL] tunnel-side listener did not start" >&2; exit 1; }

write_conf() {   # write_conf <private-key> [dns]
  cat > wireguard.conf <<EOF
[Interface]
PrivateKey = $1
Address = ${TUNNEL_VM}/32
DNS = ${2:-$TUNNEL_PEER}
[Peer]
PublicKey = $PEER_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = ${PEER_IP}:${LISTEN_PORT}
EOF
  chmod 600 wireguard.conf
}

probe() {   # probe <host> <port> -> the peer= line, BLOCKED, or UNREACHABLE
  local out
  out=$("$MIGRANT" ssh -- "timeout 5 bash -c 'exec 3<>/dev/tcp/$1/$2; head -1 <&3' 2>/dev/null || echo BLOCKED" 2>/dev/null \
    | tr -d '\r' | tail -1) || out=""
  echo "${out:-UNREACHABLE}"
}

# ============================================================
# Part 1: the tunnel, on a two-NIC VM
# ============================================================
echo "--- test: tunnel established and carrying traffic ---"
write_conf "$VM_KEY"
# WG_TEST_NICS=1 narrows this to WireGuard alone, for isolating a failure.
nics=""
for (( i = 0; i < ${WG_TEST_NICS:-2}; i++ )); do nics+='  "network=migrant"'$'\n'; done
cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
NETWORKS=(
${nics%$'\n'}
)
HOST_ACCESS=("allow-lan-host ${PEER_IP}")
EOF

# Leave the VM up on failure so the console can be read; the trap still cleans
# up on exit.
"$MIGRANT" up || echo "[WARN] up failed — continuing so host-side state can be checked"

mapfile -t taps < <(awk -F= '/^tap=/{print $2}' "$STATE" 2>/dev/null || true)

if ip link show "$WG_IFACE" &>/dev/null; then
  pass "$WG_IFACE exists"
else
  fail "$WG_IFACE was not created"
fi
if ip link show "$WG_IFACE" 2>/dev/null | grep -q 'mtu 1420'; then
  pass "MTU is 1420"
else
  fail "MTU is $(ip link show "$WG_IFACE" 2>/dev/null | grep -o 'mtu [0-9]*')"
fi
if ip -4 addr show "$WG_IFACE" 2>/dev/null | grep -q "$TUNNEL_VM"; then
  pass "tunnel address $TUNNEL_VM is configured"
else
  fail "tunnel address missing"
fi
if ip rule show 2>/dev/null | grep -q "fwmark 0x$(printf '%x' "$WG_TABLE")"; then
  pass "policy rule for fwmark 0x$(printf '%x' "$WG_TABLE") exists"
else
  fail "no policy rule for the fwmark"
fi
if ip route show table "$WG_TABLE" 2>/dev/null | grep -q "default dev $WG_IFACE"; then
  pass "table $WG_TABLE routes default via the tunnel"
else
  fail "table $WG_TABLE has no tunnel default"
fi
if [[ -f "/run/migrant/${VM_NAME}.wgmark" ]] && [[ ! -f "/run/migrant/${VM_NAME}.wgbadkey" ]]; then
  pass "wgmark written, wgbadkey absent"
else
  fail "sentinels wrong: wgmark=$([[ -f /run/migrant/${VM_NAME}.wgmark ]] && echo y || echo n) wgbadkey=$([[ -f /run/migrant/${VM_NAME}.wgbadkey ]] && echo y || echo n)"
fi

# The mark and the DNS interception are per tap, so check every one.
for tap in "${taps[@]+"${taps[@]}"}"; do
  # iptables renders MARK as --set-xmark with a mask, whatever was written.
  if sudo iptables -t mangle -S PREROUTING 2>/dev/null | grep -- "--physdev-in $tap " \
      | grep -- '-j MARK' | grep -q -- "0x$(printf '%x' "$WG_TABLE")"; then
    pass "$tap is marked for the tunnel"
  else
    fail "$tap carries no fwmark rule"
    sudo iptables -t mangle -S PREROUTING 2>/dev/null | grep -- "--physdev-in $tap " || true
  fi
  n=0
  for proto in udp tcp; do
    sudo iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--physdev-in $tap " \
      | grep -- "-p $proto" | grep -q -- "--to-destination $TUNNEL_PEER" && (( n++ )) || true
  done
  if (( n == 2 )); then
    pass "$tap has DNS DNAT for both udp and tcp"
  else
    fail "$tap has $n/2 DNS DNAT rules"
  fi
done
if sudo iptables -S FORWARD 2>/dev/null | grep -q -- "-d ${TUNNEL_PEER}/32.*-j ACCEPT"; then
  pass "the DNS address has a FORWARD ACCEPT"
else
  fail "no FORWARD ACCEPT for the DNS address"
fi

# --- the claim: traffic actually crosses the tunnel ---
got=$(probe "$TUNNEL_PEER" "$TUN_SVC")
if [[ "$got" == "peer=$TUNNEL_VM" ]]; then
  pass "the peer saw the connection arrive from $TUNNEL_VM — it crossed the tunnel"
else
  fail "peer reported '${got:-nothing}', wanted peer=$TUNNEL_VM"
fi

# --- the exclusion routes around the tunnel ---
if ip route show table "$WG_TABLE" 2>/dev/null | grep -q "^${PEER_IP}.*dev $VETH_HOST"; then
  pass "allow-lan-host target is excluded from the tunnel"
else
  fail "no /32 exclusion for $PEER_IP in table $WG_TABLE"
fi
got=$(probe "$PEER_IP" "$LAN_SVC")
if [[ "$got" == "peer=$HOST_IP" ]]; then
  pass "the excluded target was reached off-tunnel, sourced from the host"
else
  fail "excluded target reported '${got:-nothing}', wanted peer=$HOST_IP"
fi

if [[ -n "${WG_TEST_KEEP:-}" ]]; then
  echo ""
  echo "WG_TEST_KEEP set — stopping here with the VM still running."
  exit 0
fi

# ============================================================
# Part 2: teardown undoes what was installed, not what is configured now
# ============================================================
echo "--- test: teardown from the record ---"
# Change the managed DNS while the VM runs. Teardown must still remove the rule
# it installed, from the .state record, rather than the address named here now.
echo "192.0.2.99" | sudo tee "$MANAGED/wireguard-dns" >/dev/null

"$MIGRANT" halt

if ip link show "$WG_IFACE" &>/dev/null; then
  fail "$WG_IFACE survived halt"
else
  pass "$WG_IFACE removed"
fi
if ip rule show 2>/dev/null | grep -q "fwmark 0x$(printf '%x' "$WG_TABLE")"; then
  fail "the policy rule survived halt"
else
  pass "policy rule removed"
fi
if [[ -n "$(ip route show table "$WG_TABLE" 2>/dev/null)" ]]; then
  fail "table $WG_TABLE still has routes"
else
  pass "routing table flushed"
fi
left=0
for tap in "${taps[@]+"${taps[@]}"}"; do
  n=$(sudo iptables -t mangle -S 2>/dev/null | grep -c -- "--physdev-in $tap ") || n=0
  m=$(sudo iptables -t nat -S 2>/dev/null | grep -c -- "--physdev-in $tap ") || m=0
  (( left += n + m )) || true   # 0 is a falsy arithmetic result, not an error
done
if (( left == 0 )); then
  pass "mark and DNS rules gone from every tap, including the one whose DNS was changed"
else
  fail "$left mark/DNS rule(s) left behind"
fi
if [[ -f "/run/migrant/${VM_NAME}.wgmark" || -f "/run/migrant/${VM_NAME}.wgbadkey" ]]; then
  fail "a WireGuard sentinel survived halt"
else
  pass "sentinels cleared"
fi

"$MIGRANT" destroy

# ============================================================
# Part 3: refusals and partial failure
# ============================================================
echo "--- test: refusals ---"
try_refused() {  # try_refused <label> <grep pattern>
  local out; out=$(timeout 90 "$MIGRANT" up 2>&1) || true
  if grep -q "$2" <<<"$out"; then
    pass "$1"
  else
    fail "$1 — not refused"; echo "$out" | tail -3
  fi
  virsh dominfo "$VM_NAME" &>/dev/null && "$MIGRANT" destroy 2>/dev/null >/dev/null || true
}

write_conf "$VM_KEY"
cat > Migrantfile <<EOF
$(cat Migrantfile.test-backup)
NETWORK_IPV6=nat
EOF
try_refused "NETWORK_IPV6=nat is refused alongside WireGuard" 'NETWORK_IPV6'

cp Migrantfile.test-backup Migrantfile
write_conf "$VM_KEY"
sed -i "s|^Endpoint = .*|Endpoint = wg.example.com:${LISTEN_PORT}|" wireguard.conf
try_refused "a non-numeric Endpoint is refused" 'numeric IP'

# A malformed key fails inside wg setconf, which runs under set -e after the
# interface was already created. What matters is that the VM does not start and
# nothing is left behind.
echo "--- test: a malformed PrivateKey leaves nothing behind ---"
write_conf "not-a-valid-wireguard-key"
if timeout 90 "$MIGRANT" up >/dev/null 2>&1; then
  fail "the VM started with an unusable key"
else
  pass "up refused with an unusable key"
fi
virsh dominfo "$VM_NAME" &>/dev/null && "$MIGRANT" destroy 2>/dev/null >/dev/null || true
orphans=0
ip link show "$WG_IFACE" &>/dev/null && (( orphans++ )) || true
ip rule show 2>/dev/null | grep -q "fwmark 0x$(printf '%x' "$WG_TABLE")" && (( orphans++ )) || true
[[ -n "$(ip route show table "$WG_TABLE" 2>/dev/null)" ]] && (( orphans++ )) || true
if (( orphans == 0 )); then
  pass "no interface, policy rule or routing table left behind"
else
  fail "$orphans piece(s) of WireGuard state orphaned by the failed start"
fi

write_conf "$VM_KEY"
if timeout 180 "$MIGRANT" up >/dev/null 2>&1; then
  pass "a corrected key starts cleanly afterwards"
else
  fail "a corrected key did not recover the VM"
fi
"$MIGRANT" destroy >/dev/null 2>&1 || true

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  exit 1
fi
