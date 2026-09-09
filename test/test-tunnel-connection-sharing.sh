#!/usr/bin/env bash
set -euo pipefail

# Integration test for cmd_tunnel disabling SSH connection sharing. Run from
# anywhere:
#   test/test-tunnel-connection-sharing.sh
#
# virsh and ssh are shadowed on PATH: virsh reports a fake domain as running
# with a fake IP, and ssh prints its argv instead of connecting. The argv is
# what has to be asserted — a shared connection still prints the same banner,
# it just leaves the forwards behind a background master.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"
VM="migrant-tunnel-sharing-test"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

mkdir -p fakebin
cat > fakebin/virsh <<'WRAP'
#!/usr/bin/env bash
case "$1" in
  dominfo)   exit 0 ;;
  domstate)  echo "running" ;;
  domifaddr) echo " vnet0 52:54:00:00:00:00 ipv4 10.0.0.5/24" ;;
  *)         exec /usr/bin/virsh "$@" ;;
esac
WRAP
cat > fakebin/ssh <<'WRAP'
#!/usr/bin/env bash
printf '%s\n' "$@"
WRAP
chmod +x fakebin/virsh fakebin/ssh

cat > cloud-init.yml <<'EOF'
users:
  - name: migrant
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY someone@elsewhere
EOF

run_tunnel() {
  set +e
  PATH="$WORK/fakebin:$PATH" "$MIGRANT" tunnel "$@" > tunnel.out 2>tunnel.err
  TUNNEL_STATUS=$?
  set -e
  TUNNEL_OUT=$(cat tunnel.out)
  TUNNEL_ERR=$(cat tunnel.err)
}

# --- 1. explicit ports disable connection sharing ---------------------------
cat > Migrantfile <<EOF
VM_NAME="$VM"
EOF
run_tunnel 3000
if grep -qF "ControlPath=none" <<<"$TUNNEL_OUT"; then
  pass "explicit ports disable connection sharing"
else
  fail "explicit ports left sharing enabled: status=$TUNNEL_STATUS out=$TUNNEL_OUT err=$TUNNEL_ERR"
fi

# --- 2. the forwards themselves are unchanged (regression) ------------------
if grep -qxF -- "-L" <<<"$TUNNEL_OUT" && grep -qxF "3000:127.0.0.1:3000" <<<"$TUNNEL_OUT"; then
  pass "explicit ports still produce -L PORT:127.0.0.1:PORT"
else
  fail "forward missing or malformed: $TUNNEL_OUT"
fi

# --- 3. TUNNEL_PORTS takes the same path ------------------------------------
cat > Migrantfile <<EOF
VM_NAME="$VM"
TUNNEL_PORTS=(3000 5432)
EOF
run_tunnel
if grep -qF "ControlPath=none" <<<"$TUNNEL_OUT"; then
  pass "TUNNEL_PORTS disables connection sharing"
else
  fail "TUNNEL_PORTS left sharing enabled: status=$TUNNEL_STATUS out=$TUNNEL_OUT err=$TUNNEL_ERR"
fi
if grep -qxF "5432:127.0.0.1:5432" <<<"$TUNNEL_OUT"; then
  pass "TUNNEL_PORTS forwards every configured port"
else
  fail "TUNNEL_PORTS dropped a port: $TUNNEL_OUT"
fi

# --- 4. 'migrant ssh' keeps sharing, which is only a win there ---------------
run_ssh_out=$(PATH="$WORK/fakebin:$PATH" "$MIGRANT" ssh 2>/dev/null || true)
if ! grep -qF "ControlPath=none" <<<"$run_ssh_out"; then
  pass "'migrant ssh' still shares connections"
else
  fail "'migrant ssh' unexpectedly disabled sharing: $run_ssh_out"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
