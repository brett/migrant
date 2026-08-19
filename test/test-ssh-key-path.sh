#!/usr/bin/env bash
set -euo pipefail

# Integration test for the SSH_KEY_PATH Migrantfile variable and its
# precedence against the MIGRANT_KEY_PATH env var. Run from anywhere:
#   test/test-ssh-key-path.sh
#
# 'migrant pubkey' only needs a Migrantfile (VM_NAME) — no VM, base image, or
# libvirt domain — so this covers require_config's key-path resolution
# without booting anything.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# --- 1. SSH_KEY_PATH in the Migrantfile is used when MIGRANT_KEY_PATH is unset
cat > Migrantfile <<EOF
VM_NAME="ssh-key-path-test"
SSH_KEY_PATH="$WORK/vm-key"
EOF

out=$("$MIGRANT" pubkey 2>/dev/null)
if [[ -f "$WORK/vm-key" && -f "$WORK/vm-key.pub" ]]; then
  pass "SSH_KEY_PATH generates the key at the Migrantfile-specified path"
else
  fail "SSH_KEY_PATH did not generate the key at $WORK/vm-key: $out"
fi
if [[ "$out" == "$(cat "$WORK/vm-key.pub")" ]]; then
  pass "pubkey prints the SSH_KEY_PATH key's public half"
else
  fail "pubkey output did not match $WORK/vm-key.pub: $out"
fi

# --- 2. MIGRANT_KEY_PATH env var overrides SSH_KEY_PATH for one invocation ---
out=$(MIGRANT_KEY_PATH="$WORK/env-key" "$MIGRANT" pubkey 2>/dev/null)
if [[ -f "$WORK/env-key" && -f "$WORK/env-key.pub" ]]; then
  pass "MIGRANT_KEY_PATH generates the key at the env-specified path"
else
  fail "MIGRANT_KEY_PATH did not generate the key at $WORK/env-key: $out"
fi
if [[ "$out" == "$(cat "$WORK/env-key.pub")" && "$out" != "$(cat "$WORK/vm-key.pub")" ]]; then
  pass "MIGRANT_KEY_PATH wins over the Migrantfile's SSH_KEY_PATH"
else
  fail "env override did not take precedence: $out"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
