#!/usr/bin/env bash
set -euo pipefail

# Integration test for build_ssh_opts and cmd_provision recognizing the
# __MIGRANT_PUBKEY__ placeholder the same way they recognize a literal
# 'migrant'-tagged key. Run from anywhere:
#   test/test-managed-key-ssh-opts.sh
#
# virsh, ssh, and ansible-playbook are all shadowed on PATH: virsh reports a
# fake domain as running with a fake IP, and ssh/ansible-playbook just print
# their argv instead of connecting or provisioning. This proves what
# build_ssh_opts and cmd_provision put on the command line without booting a
# VM or touching the network.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"
VM="migrant-ssh-opts-test"

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
cat > fakebin/ansible-playbook <<'WRAP'
#!/usr/bin/env bash
printf '%s\n' "$@"
WRAP
chmod +x fakebin/virsh fakebin/ssh fakebin/ansible-playbook

write_migrantfile() {
  cat > Migrantfile <<EOF
VM_NAME="$VM"
SSH_KEY_PATH="$1"
EOF
}

run_ssh() {
  set +e
  PATH="$WORK/fakebin:$PATH" "$MIGRANT" ssh > ssh.out 2>ssh.err
  SSH_STATUS=$?
  set -e
  SSH_OUT=$(cat ssh.out)
  SSH_ERR=$(cat ssh.err)
}

run_provision() {
  set +e
  PATH="$WORK/fakebin:$PATH" "$MIGRANT" provision > provision.out 2>provision.err
  PROVISION_STATUS=$?
  set -e
  PROVISION_OUT=$(cat provision.out)
  PROVISION_ERR=$(cat provision.err)
}

# --- 1. placeholder-based cloud-init.yml still forces the managed key -------
cat > cloud-init.yml <<'EOF'
users:
  - name: migrant
    ssh_authorized_keys:
      - __MIGRANT_PUBKEY__
EOF
ssh-keygen -t ed25519 -f "$WORK/real-key" -N "" -C "migrant" >/dev/null
write_migrantfile "$WORK/real-key"
run_ssh
if grep -qF -- "-i" <<<"$SSH_OUT" && grep -qF "$WORK/real-key" <<<"$SSH_OUT"; then
  pass "placeholder cloud-init.yml forces -i \$MANAGED_KEY_PATH"
else
  fail "placeholder cloud-init.yml did not force the managed key: status=$SSH_STATUS out=$SSH_OUT err=$SSH_ERR"
fi
if grep -qF "IdentitiesOnly=yes" <<<"$SSH_OUT"; then
  pass "placeholder cloud-init.yml sets IdentitiesOnly=yes"
else
  fail "placeholder cloud-init.yml did not set IdentitiesOnly=yes: $SSH_OUT"
fi

# --- 2. missing managed key errors instead of silently using agent keys -----
write_migrantfile "$WORK/no-such-key"
run_ssh
if (( SSH_STATUS == 66 )) && grep -q 'not found' <<<"$SSH_ERR"; then
  pass "missing managed key errors rather than falling back to agent keys"
else
  fail "missing managed key: status=$SSH_STATUS out=$SSH_OUT err=$SSH_ERR"
fi

# --- 3. a literal migrant-tagged key still works as before (regression) -----
cat > cloud-init.yml <<EOF
users:
  - name: migrant
    ssh_authorized_keys:
      - $(cat "$WORK/real-key.pub")
EOF
write_migrantfile "$WORK/real-key"
run_ssh
if grep -qF -- "-i" <<<"$SSH_OUT" && grep -qF "$WORK/real-key" <<<"$SSH_OUT"; then
  pass "a literal migrant-tagged key still forces -i \$MANAGED_KEY_PATH"
else
  fail "literal key regression: status=$SSH_STATUS out=$SSH_OUT err=$SSH_ERR"
fi

# --- 4. a non-managed key (no 'migrant' comment) leaves the agent in charge -
cat > cloud-init.yml <<'EOF'
users:
  - name: migrant
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY someone@elsewhere
EOF
write_migrantfile "$WORK/real-key"
run_ssh
if ! grep -qF -- "-i" <<<"$SSH_OUT"; then
  pass "a non-managed key leaves SSH to use the agent/default identities"
else
  fail "non-managed key unexpectedly forced -i: $SSH_OUT"
fi

# --- 5. provisioning picks up the managed key for a placeholder VM too -----
echo "- hosts: all" > playbook.yml
cat > cloud-init.yml <<'EOF'
users:
  - name: migrant
    ssh_authorized_keys:
      - __MIGRANT_PUBKEY__
EOF
write_migrantfile "$WORK/real-key"
run_provision
if grep -qF -- "--private-key" <<<"$PROVISION_OUT" && grep -qF "$WORK/real-key" <<<"$PROVISION_OUT"; then
  pass "provision passes --private-key for a placeholder-based VM"
else
  fail "provision (placeholder): status=$PROVISION_STATUS out=$PROVISION_OUT err=$PROVISION_ERR"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
