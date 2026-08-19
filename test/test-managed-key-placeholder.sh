#!/usr/bin/env bash
set -euo pipefail

# Integration test for the __MIGRANT_PUBKEY__ placeholder in cloud-init.yml:
# 'migrant up' substitutes it with the managed key's public half when
# building the cloud-init seed ISO. Run from anywhere:
#   test/test-managed-key-placeholder.sh
#
# virt-install is shadowed on PATH so the test never boots a real VM — it
# only needs to prove what landed in the seed ISO, which is built before
# virt-install runs. This makes the test deterministic and safe to run
# whether or not virt-install is actually installed.
#
# Prerequisites:
#   - qemu-img, xorriso, ssh-keygen on PATH
#   - LIBVIRT_IMAGES_DIR is redirected to a scratch dir, so nothing under the
#     real /var/lib/libvirt/images is touched

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(cd "$SCRIPT_DIR/.." && pwd)/migrant"
VM="migrant-placeholder-test"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

mkdir -p images fakebin libvirt-conf/hooks/qemu.d
IMAGES_DIR="$WORK/images"
CONF_DIR="$WORK/libvirt-conf"
# ensure_shared_folder_images only checks that this file exists (shared
# folder isolation is on by default); SHARED_FOLDERS is empty so nothing
# else in that function runs.
: > "$CONF_DIR/hooks/qemu.d/migrant-loop"

# virt-install is the first tool 'up' calls after the seed ISO is built.
# Failing it there, deterministically, is what stops the test short of
# actually creating a domain.
cat > fakebin/virt-install <<'WRAP'
#!/usr/bin/env bash
echo "fake virt-install invoked" >&2
exit 1
WRAP
chmod +x fakebin/virt-install

qemu-img create -f qcow2 base.qcow2 10M >/dev/null

write_migrantfile() {
  cat > Migrantfile <<EOF
VM_NAME="$VM"
OS_VARIANT="archlinux"
RAM_MB=512
VCPUS=1
DISK_GB=1
IMAGE_URL="file://$WORK/base.qcow2"
SHARED_FOLDERS=()
NETWORK_ISOLATION=false
NETWORKS=()
SSH_KEY_PATH="$1"
EOF
}

# Runs 'up' with virt-install shadowed out. Always non-zero (virt-install
# fails on purpose) — the assertions are about what happened before that.
run_up() {
  set +e
  PATH="$WORK/fakebin:$PATH" LIBVIRT_IMAGES_DIR="$IMAGES_DIR" LIBVIRT_CONF_DIR="$CONF_DIR" \
    timeout 25 "$MIGRANT" up > up.out 2>&1
  UP_STATUS=$?
  set -e
  UP_OUT=$(cat up.out)
}

extract_user_data() {
  rm -f extracted-user-data
  xorriso -indev "$IMAGES_DIR/${VM}-seed.iso" \
    -osirrox on -extract /user-data extracted-user-data >/dev/null 2>&1
  cat extracted-user-data
}

# --- 1. missing managed key: 'up' errors before building the seed ISO ---------
cat > cloud-init.yml <<'EOF'
users:
  - name: migrant
    ssh_authorized_keys:
      - __MIGRANT_PUBKEY__
EOF
write_migrantfile "$WORK/missing-key"
run_up
if (( UP_STATUS == 66 )) && grep -q '__MIGRANT_PUBKEY__' <<<"$UP_OUT" \
    && grep -q "Run 'migrant pubkey'" <<<"$UP_OUT"; then
  pass "missing managed key errors with exit 66 and points at 'migrant pubkey'"
else
  fail "missing managed key: status=$UP_STATUS output=$UP_OUT"
fi
if [[ -f "$IMAGES_DIR/${VM}-seed.iso" ]]; then
  fail "seed ISO was built despite the missing key"
else
  pass "no seed ISO built when the managed key is missing"
fi
rm -f "$IMAGES_DIR/${VM}.qcow2"

# --- 2. placeholder is substituted with the real key's public half ------------
ssh-keygen -t ed25519 -f "$WORK/real-key" -N "" -C "migrant" >/dev/null
write_migrantfile "$WORK/real-key"
run_up
if grep -q "fake virt-install invoked" <<<"$UP_OUT"; then
  pass "up reached virt-install (proves the seed ISO build path completed)"
else
  fail "up did not reach virt-install: status=$UP_STATUS output=$UP_OUT"
fi

data=$(extract_user_data)
want=$(cat "$WORK/real-key.pub")
if grep -qF "$want" <<<"$data"; then
  pass "seed ISO user-data contains the real public key"
else
  fail "seed ISO user-data missing the real key: $data"
fi
if grep -q '__MIGRANT_PUBKEY__' <<<"$data"; then
  fail "seed ISO user-data still contains the placeholder"
else
  pass "placeholder is gone from the seed ISO"
fi
rm -f "$IMAGES_DIR/${VM}.qcow2" "$IMAGES_DIR/${VM}-seed.iso"

# --- 3. a literal key (no placeholder) passes through unchanged ---------------
cat > cloud-init.yml <<'EOF'
users:
  - name: migrant
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY test@example
EOF
write_migrantfile "$WORK/real-key"
run_up
data=$(extract_user_data)
if diff -q cloud-init.yml <(cat <<<"$data") >/dev/null 2>&1 \
    || [[ "$data" == "$(cat cloud-init.yml)" ]]; then
  pass "a literal key in cloud-init.yml passes through unmodified"
else
  fail "literal-key cloud-init.yml was altered: $data"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
