#!/usr/bin/env bash
set -euo pipefail

# libvirt supports two connection URIs: qemu:///session (default, runs as the
# current user) and qemu:///system (runs as root via the system daemon).
# System-level privileges are required to manage virtual networks and bridge
# interfaces. Without this, virsh and virt-install commands will silently
# connect to the session daemon and fail with permission errors.
export LIBVIRT_DEFAULT_URI="qemu:///system"

SUBCOMMAND="${1:-}"
MANAGED_KEY_PATH="$HOME/.ssh/migrant"

# Resolve the VM directory: MIGRANT_DIR env var takes precedence over CWD.
# Tilde in MIGRANT_DIR is expanded manually because it is not expanded when
# the variable is set via an env var prefix (e.g. MIGRANT_DIR='~/foo' cmd).
if [[ -n "${MIGRANT_DIR:-}" ]]; then
  _migrant_dir="${MIGRANT_DIR/#~/$HOME}"
  VM_DIR="$(realpath "$_migrant_dir")"
else
  VM_DIR="$(pwd)"
fi

CONFIG_FILE="$VM_DIR/Migrantfile"
CLOUD_INIT_FILE="$VM_DIR/cloud-init.yml"
IMAGES_DIR="/var/lib/libvirt/images"

usage() {
  cat >&2 <<'EOF'
Usage: migrant.sh <command> [args]

Commands:
  setup               One-time host setup: configures libvirt networking and
                      installs firewall hooks
  up                  Create the VM if it does not exist, or start it if stopped;
                      runs Ansible provisioning (if playbook.yml exists) on first
                      create; waits until the VM is fully ready
  halt                Gracefully shut down the VM
  destroy             Stop and permanently delete the VM, its disk, and any snapshots
  provision           Run the Ansible playbook (playbook.yml) against the running VM
  snapshot            Shut down the VM and save a snapshot of its disk;
                      VM stays down afterward
  reset               Destroy the VM and rebuild it from the last snapshot
  status              Show the VM's current state and snapshot availability
  ssh [-- cmd...]     SSH into the VM as the configured user; optionally run a
                      remote command (e.g. migrant.sh ssh -- sudo cloud-init status)
  console             Open a serial console session (exit with Ctrl+])
  ip                  Print the VM's IP address
  pubkey              Print the managed SSH public key (requires MANAGED_SSH_KEY=true)
  storage             List IMAGES_DIR contents grouped by base images and VMs,
                      with file sizes; works without a Migrantfile

Each command reads Migrantfile and cloud-init.yml from the current directory,
or from the directory specified by the MIGRANT_DIR environment variable.
EOF
  exit "${1:-1}"
}

require_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: No Migrantfile found in $VM_DIR" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  if [[ -z "${VM_NAME:-}" ]]; then
    echo "Error: 'VM_NAME' is not set in Migrantfile" >&2
    exit 1
  fi
  DISK_PATH="$IMAGES_DIR/${VM_NAME}.qcow2"
  SEED_ISO="$IMAGES_DIR/${VM_NAME}-seed.iso"
  SNAPSHOT_PATH="$IMAGES_DIR/${VM_NAME}-snapshot.qcow2"
}

require_vm() {
  if ! virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "VM '$VM_NAME' has not been created. Run 'migrant.sh up' to create it." >&2
    exit 1
  fi
}

require_running() {
  require_vm
  local state
  state=$(virsh domstate "$VM_NAME")
  if [[ "$state" != "running" ]]; then
    echo "VM '$VM_NAME' is not running (state: $state). Run 'migrant.sh up' first." >&2
    exit 1
  fi
}

check_kvm() {
  if [[ ! -e /dev/kvm ]]; then
    echo "Warning: /dev/kvm not found. KVM acceleration is unavailable — check that" >&2
    echo "virtualization extensions (VT-x/AMD-V) are enabled in your BIOS/UEFI." >&2
  fi
}

get_vm_ip() {
  virsh domifaddr "$VM_NAME" | awk '/ipv4/ { split($4, a, "/"); print a[1]; exit }'
}

get_vm_ip_or_die() {
  local ip
  ip=$(get_vm_ip)
  if [[ -z "$ip" ]]; then
    echo "No IP address found for '$VM_NAME'. The VM may still be booting." >&2
    exit 1
  fi
  echo "$ip"
}

wait_for_ip() {
  echo "Waiting for '$VM_NAME' to obtain an IP address..." >&2
  local ip
  local deadline=$(( SECONDS + 120 ))
  while true; do
    ip=$(get_vm_ip)
    [[ -n "$ip" ]] && break
    if ! virsh domstate "$VM_NAME" 2>/dev/null | grep -q "^running"; then
      echo "Error: VM '$VM_NAME' is no longer running." >&2
      exit 1
    fi
    if (( SECONDS >= deadline )); then
      echo "Error: timed out waiting for '$VM_NAME' to obtain an IP address." >&2
      exit 1
    fi
    sleep 2
  done
  echo "VM '$VM_NAME' is up at $ip." >&2
}

wait_for_shutdown() {
  echo "Waiting for '$VM_NAME' to shut down..." >&2
  local deadline=$(( SECONDS + 60 ))
  while true; do
    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null) || break
    [[ "$state" == "shut off" ]] && break
    if (( SECONDS >= deadline )); then
      echo "Error: timed out waiting for '$VM_NAME' to shut down." >&2
      echo "  The VM may be unresponsive. Run 'virsh destroy $VM_NAME' to force-stop it." >&2
      exit 1
    fi
    sleep 2
  done
}


wait_for_ssh() {
  local user="$1" ip="$2"
  shift 2
  local ssh_opts=("$@")
  echo "Waiting for SSH on '$VM_NAME'..." >&2
  local deadline=$(( SECONDS + 60 ))
  while true; do
    if ssh "${ssh_opts[@]}" -o ConnectTimeout=3 -o BatchMode=yes \
        "${user}@${ip}" exit 2>/dev/null; then
      break
    fi
    if (( SECONDS >= deadline )); then
      echo "Error: timed out waiting for SSH on '$VM_NAME'." >&2
      exit 1
    fi
    sleep 2
  done
}

cmd_up() {
  if [[ ! -f "$CLOUD_INIT_FILE" ]]; then
    echo "Error: No cloud-init.yml found in $VM_DIR" >&2
    exit 1
  fi

  for var in VM_NAME RAM_MB VCPUS DISK_GB IMAGE_URL OS_VARIANT; do
    if [[ -z "${!var:-}" ]]; then
      echo "Error: '$var' is not set in Migrantfile" >&2
      exit 1
    fi
  done

  local base_image="${IMAGE_URL##*/}"

  if virsh dominfo "$VM_NAME" &>/dev/null; then
    local current_base
    current_base=$(qemu-img info "$DISK_PATH" 2>/dev/null \
        | grep '^backing file:' | cut -d' ' -f3- || true)
    current_base=$(basename "$current_base")
    if [[ -n "$current_base" \
        && "$current_base" != "$base_image" \
        && "$current_base" != "$(basename "$SNAPSHOT_PATH")" ]]; then
      echo "Error: VM '$VM_NAME' was built from '$current_base' but Migrantfile" >&2
      echo "  specifies '$base_image'. Run 'migrant.sh destroy' first." >&2
      exit 1
    fi

    local state
    state=$(virsh domstate "$VM_NAME")
    if [[ "$state" == "running" ]]; then
      echo "VM '$VM_NAME' is already running."
      return
    fi
    echo "VM '$VM_NAME' exists but is not running. Starting..."
    virsh start "$VM_NAME"
    wait_for_ip
    if vm_has_ssh; then
      local user ssh_opts ip
      resolve_ssh_conn user ssh_opts ip
      wait_for_ssh "$user" "$ip" "${ssh_opts[@]}"
    fi
    return
  fi

  check_kvm

  echo "VM '$VM_NAME' not found. Creating..."

  mkdir -p "$IMAGES_DIR"

  local from_snapshot=false
  local base_image_path
  if [[ -f "$SNAPSHOT_PATH" ]]; then
    echo "Using snapshot: $SNAPSHOT_PATH"
    base_image_path="$SNAPSHOT_PATH"
    from_snapshot=true
  else
    base_image_path="$IMAGES_DIR/$base_image"
    if [[ ! -f "$base_image_path" ]]; then
      echo "Downloading base image..."
      if ! curl --fail -L -o "$base_image_path" "$IMAGE_URL"; then
        echo "Error: Failed to download image. Check IMAGE_URL in Migrantfile." >&2
        rm -f "$base_image_path"
        exit 1
      fi
      if ! qemu-img info "$base_image_path" &>/dev/null; then
        echo "Error: Downloaded file is not a valid disk image. Check IMAGE_URL in Migrantfile." >&2
        rm -f "$base_image_path"
        exit 1
      fi
    fi
  fi

  qemu-img create -f qcow2 -b "$base_image_path" -F qcow2 "$DISK_PATH" "${DISK_GB}G"

  local cloud_init_dir=""
  cloud_init_dir=$(mktemp -d)
  # SC2064: double quotes are intentional — cloud_init_dir is local and
  # will be out of scope when EXIT fires, so we expand the path now.
  # shellcheck disable=SC2064
  trap "rm -rf '$cloud_init_dir'" EXIT

  cp "$CLOUD_INIT_FILE" "$cloud_init_dir/user-data"
  cat > "$cloud_init_dir/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

  xorriso -as mkisofs \
    -output "$SEED_ISO" \
    -volid "cidata" \
    -joliet \
    -rock \
    "$cloud_init_dir/user-data" \
    "$cloud_init_dir/meta-data"

  local extra_args=()
  local has_shared_folders=false

  for shared_folder in "${SHARED_FOLDERS[@]+"${SHARED_FOLDERS[@]}"}"; do
    local host_path="${shared_folder%%:*}"
    local guest_tag="${shared_folder##*:}"
    # Relative paths are resolved relative to the VM directory (where Migrantfile lives).
    [[ "$host_path" != /* ]] && host_path="$VM_DIR/$host_path"
    mkdir -p "$host_path"
    extra_args+=(--filesystem "source=$host_path,target=$guest_tag,driver.type=virtiofs")
    has_shared_folders=true
  done

  if [[ "$has_shared_folders" == true ]]; then
    extra_args+=(--memorybacking "source.type=memfd,access.mode=shared")
  fi

  local reset_macs=()
  read -r -a reset_macs <<< "${_MIGRANT_RESET_MACS:-}"
  local nic_index=0
  for nic in "${NETWORKS[@]+"${NETWORKS[@]}"}"; do
    local mac="${reset_macs[$nic_index]:-}"
    if [[ -n "$mac" ]]; then
      extra_args+=(--network "${nic},mac=${mac}")
    else
      extra_args+=(--network "$nic")
    fi
    (( nic_index++ )) || true
  done

  local vm_description="managed-by=migrant.sh"
  if [[ "${NETWORK_ISOLATION:-}" == "true" ]]; then
    vm_description="managed-by=migrant.sh,network-isolation=true"
  fi

  virt-install \
    --name "$VM_NAME" \
    --description "$vm_description" \
    --ram "$RAM_MB" \
    --vcpus "$VCPUS" \
    --os-variant "$OS_VARIANT" \
    --disk "path=$DISK_PATH,format=qcow2" \
    --disk "path=$SEED_ISO,device=cdrom" \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --import \
    --boot hd \
    "${extra_args[@]}"

  wait_for_ip

  if [[ "$from_snapshot" == false ]] && [[ -f "$VM_DIR/playbook.yml" ]]; then
    local user ssh_opts ip
    resolve_ssh_conn user ssh_opts ip

    wait_for_ssh "$user" "$ip" "${ssh_opts[@]}"

    echo "Waiting for cloud-init to finish..." >&2
    if ! ssh "${ssh_opts[@]}" "${user}@${ip}" sudo cloud-init status --wait; then
      echo "" >&2
      echo "Error: cloud-init failed on '$VM_NAME'." >&2
      echo "  Run 'migrant.sh ssh -- sudo cloud-init status' for details." >&2
      exit 1
    fi
    echo "cloud-init done." >&2

    cmd_provision
    echo "VM '$VM_NAME' is ready." >&2
  elif [[ "$from_snapshot" == false ]]; then
    echo "" >&2
    echo "Note: cloud-init is still provisioning in the background." >&2
    echo "  Monitor progress : migrant.sh ssh -- sudo tail -f /var/log/cloud-init-output.log" >&2
    echo "  Wait for finish  : migrant.sh ssh -- sudo cloud-init status --wait" >&2
  fi
}

install_hook() {
  local src="$1" dest="$2"
  sudo mkdir -p "$(dirname "$dest")"
  sudo cp "$src" "$dest"
  sudo chmod 755 "$dest"
}

cmd_setup() {
  local qemu_hook="/etc/libvirt/hooks/qemu.d/migrant"
  local network_hook="/etc/libvirt/hooks/network.d/migrant"

  # Temp files: expected hook content (for comparison) and network XML (if needed).
  # All three are created upfront so a single trap covers them.
  local expected_qemu_hook expected_network_hook net_xml
  expected_qemu_hook=$(mktemp)
  expected_network_hook=$(mktemp)
  net_xml=$(mktemp --suffix=.xml)
  # SC2064: expand now — these vars are local and will be out of scope on EXIT
  # shellcheck disable=SC2064
  trap "rm -f '$expected_qemu_hook' '$expected_network_hook' '$net_xml'" EXIT

  # --- KVM check ---
  check_kvm

  # --- libvirtd sockets ---
  echo ""
  local changed=false
  for unit in libvirtd.socket virtlogd.socket; do
    if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      sudo systemctl enable "$unit"
      echo "  Enabled $unit."
      changed=true
    fi
    if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
      sudo systemctl start "$unit"
      echo "  Started $unit."
      changed=true
    fi
  done
  if [[ "$changed" == false ]]; then
    echo "libvirtd.socket and virtlogd.socket already enabled and active."
  fi

  # --- libvirt group ---
  echo ""
  local current_user
  current_user=$(whoami)
  if groups "$current_user" | grep -qw libvirt; then
    echo "User '$current_user' is already in the libvirt group."
  else
    echo "Adding '$current_user' to the libvirt group..."
    sudo usermod -aG libvirt "$current_user"
    echo "  Done. Log out and back in (or run 'newgrp libvirt') for this to take effect."
  fi

  # --- firewall backend ---
  echo ""
  echo "Checking firewall backend..."
  local network_conf="/etc/libvirt/network.conf"
  local current_backend
  current_backend=$(grep -oP '(?<=^firewall_backend = ")[^"]+' "$network_conf" 2>/dev/null || echo "")
  if [[ -z "$current_backend" ]]; then
    current_backend="nftables"  # libvirt default
  fi

  # Detect which firewall system the host actually uses:
  # - Legacy iptables: has rules in iptables but not in nft
  # - nftables: nft list ruleset shows tables (ignore libvirt's own)
  local host_uses_legacy_iptables=false
  if sudo iptables -S 2>/dev/null | grep -qv '^-P .* ACCEPT$' \
      && ! sudo nft list ruleset 2>/dev/null | grep -q 'table'; then
    host_uses_legacy_iptables=true
  fi

  if $host_uses_legacy_iptables && [[ "$current_backend" != "iptables" ]]; then
    echo "  Detected legacy iptables firewall — setting firewall_backend=iptables."
    echo "  Elevated permissions required to modify $network_conf."
    sudo sed -i 's/#\?\s*firewall_backend\s*=\s*"[^"]*"/firewall_backend = "iptables"/' \
      "$network_conf" 2>/dev/null \
      || echo 'firewall_backend = "iptables"' | sudo tee -a "$network_conf" > /dev/null
    sudo systemctl restart libvirtd
    echo "  libvirtd restarted with iptables backend."
  else
    echo "  Firewall backend '$current_backend' — no change needed."
  fi

  # --- qemu hook (network isolation) ---
  echo ""
  cat > "$expected_qemu_hook" << 'MIGRANT_QEMU_EOF'
#!/bin/bash
# Managed by migrant.sh

VM_NAME="$1"
OPERATION="$2"
# iptables chain names are limited to 29 characters; hash the VM name so
# the chain name stays within that limit regardless of VM name length.
CHAIN="MIGRANT_$(printf '%s' "$VM_NAME" | md5sum | head -c8)"

# Check the domain description from the persistent XML file rather than via
# virsh: hooks are invoked synchronously while libvirtd holds the per-domain
# lock, so calling virsh against the same domain from within a hook deadlocks
# — the hook waits for libvirtd, which waits for the hook.
local_xml="/etc/libvirt/qemu/${VM_NAME}.xml"
grep -q "managed-by=migrant.sh" "$local_xml" 2>/dev/null || exit 0
grep -q "network-isolation=true" "$local_xml" 2>/dev/null || exit 0

apply_rules() {
  local vm="$1"

  # Locate the tap interface for this VM without calling virsh.
  # The kernel exposes the interface name in /proc/PID/fdinfo/N for each open
  # tun/tap file descriptor (as the "iff:" field). Find the QEMU process by
  # its -name flag, then scan its open fds for /dev/net/tun entries.
  local iface=""
  local qemu_pid
  qemu_pid=$(pgrep -af 'qemu' 2>/dev/null | grep -F "guest=${vm}," | awk 'NR==1{print $1}')
  if [[ -n "$qemu_pid" ]]; then
    for fd in /proc/"${qemu_pid}"/fd/*; do
      [[ "$(readlink "$fd" 2>/dev/null)" == "/dev/net/tun" ]] || continue
      local candidate
      candidate=$(awk '/^iff:/{print $2}' \
        "/proc/${qemu_pid}/fdinfo/$(basename "$fd")" 2>/dev/null)
      if [[ -n "$candidate" ]]; then
        iface="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$iface" ]]; then
    echo "migrant: no tap interface found for $vm" >&2
    return 1
  fi

  mkdir -p /run/migrant
  echo "$iface" > "/run/migrant/${vm}.iface"

  # Per-VM INPUT chain: block new connections from VM to host.
  # DNS and DHCP are already accepted by libvirt's LIBVIRT_INP chain
  # which runs before this one.
  iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
  iptables -A "$CHAIN" -m conntrack --ctstate NEW -j REJECT
  iptables -I INPUT -i "$iface" -j "$CHAIN"

  # Block VM-to-LAN (RFC1918 ranges except the libvirt subnet itself)
  iptables -I FORWARD -i "$iface" -d 10.0.0.0/8 -j REJECT
  iptables -I FORWARD -i "$iface" -d 172.16.0.0/12 -j REJECT
  iptables -I FORWARD -i "$iface" -d 192.168.0.0/16 -j REJECT
  iptables -I FORWARD -i "$iface" -d 192.168.122.0/24 -j ACCEPT
}

remove_rules() {
  local vm="$1"
  local iface
  iface=$(cat "/run/migrant/${vm}.iface" 2>/dev/null) || return 0
  [[ -z "$iface" ]] && return 0

  iptables -D INPUT -i "$iface" -j "$CHAIN" 2>/dev/null || true
  iptables -F "$CHAIN" 2>/dev/null || true
  iptables -X "$CHAIN" 2>/dev/null || true

  iptables -D FORWARD -i "$iface" -d 10.0.0.0/8 -j REJECT 2>/dev/null || true
  iptables -D FORWARD -i "$iface" -d 172.16.0.0/12 -j REJECT 2>/dev/null || true
  iptables -D FORWARD -i "$iface" -d 192.168.122.0/24 -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$iface" -d 192.168.0.0/16 -j REJECT 2>/dev/null || true

  rm -f "/run/migrant/${vm}.iface"
}

case "$OPERATION" in
  started) apply_rules "$VM_NAME" ;;
  release) remove_rules "$VM_NAME" ;;
esac
MIGRANT_QEMU_EOF
  if [[ -f "$qemu_hook" ]] && cmp -s "$expected_qemu_hook" "$qemu_hook"; then
    echo "VM firewall hook already up to date."
  else
    if [[ ! -f "$qemu_hook" ]]; then
      echo "Installing VM firewall hook ($qemu_hook)."
      echo "  When a migrant.sh-managed VM with NETWORK_ISOLATION=true starts,"
      echo "  iptables rules will be added to:"
      echo "    - block the VM from initiating new connections to the host"
      echo "    - block the VM from reaching other hosts on the local network"
      echo "  The rules are removed automatically when the VM stops."
    else
      echo "VM firewall hook is outdated, reinstalling ($qemu_hook)."
    fi
    echo "  Elevated permissions are required to write to /etc/libvirt/hooks/."
    install_hook "$expected_qemu_hook" "$qemu_hook"
    echo "  Installed."
  fi

  # --- network hook (rp_filter) ---
  echo ""
  local default_rp_filter
  default_rp_filter=$(cat /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null \
    || echo 0)

  if [[ "$default_rp_filter" -eq 0 ]]; then
    echo "net.ipv4.conf.default.rp_filter=0 — rp_filter hook not needed."
  else
    cat > "$expected_network_hook" << 'MIGRANT_NETWORK_EOF'
#!/bin/bash
# Managed by migrant.sh
# Libvirt network hook args: $1=network-name $2=operation $3=sub-operation $4=extra
if [[ "$1" == "default" && "$2" == "started" ]]; then
  sysctl -w "net.ipv4.conf.virbr0.rp_filter=0"
fi
MIGRANT_NETWORK_EOF
    if [[ -f "$network_hook" ]] && cmp -s "$expected_network_hook" "$network_hook"; then
      echo "rp_filter hook already up to date."
    else
      if [[ ! -f "$network_hook" ]]; then
        echo "Detected net.ipv4.conf.default.rp_filter=$default_rp_filter."
        echo "  New network interfaces will have reverse path filtering enabled."
        echo "  This causes the kernel to drop DHCP discover packets (source 0.0.0.0)"
        echo "  before dnsmasq can receive them — a known issue with linux-hardened."
        echo "  Installing network hook to set rp_filter=0 on the libvirt bridge."
      else
        echo "rp_filter hook is outdated, reinstalling ($network_hook)."
      fi
      echo "  Elevated permissions are required to write to /etc/libvirt/hooks/."
      install_hook "$expected_network_hook" "$network_hook"
      echo "  Installed."
    fi
  fi

  # --- default network ---
  echo ""
  if virsh net-info default &>/dev/null; then
    echo "Default libvirt network already exists."
    if ! virsh net-list | grep -qw "default"; then
      echo "  Starting default network..."
      virsh net-start default
    fi
    if ! virsh net-info default | grep -q "Autostart:.*yes"; then
      virsh net-autostart default
      echo "  Autostart enabled."
    fi
  else
    echo "Creating default libvirt network..."
    cat > "$net_xml" << 'NET_EOF'
<network>
  <name>default</name>
  <forward mode="nat"/>
  <bridge name="virbr0" stp="on" delay="0"/>
  <mac address="52:54:00:0a:cd:21"/>
  <ip address="192.168.122.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.122.2" end="192.168.122.254"/>
    </dhcp>
  </ip>
</network>
NET_EOF
    virsh net-define "$net_xml"
    virsh net-autostart default
    virsh net-start default
    echo "  Default network created and started."
  fi

  # --- images directory permissions ---
  echo ""
  if [[ ! -d "$IMAGES_DIR" ]]; then
    echo "Creating images directory $IMAGES_DIR..."
    sudo mkdir -p "$IMAGES_DIR"
  fi
  if [[ -w "$IMAGES_DIR" ]]; then
    echo "Images directory $IMAGES_DIR is already writable."
  else
    echo "Granting libvirt group write access to $IMAGES_DIR..."
    sudo chown root:libvirt "$IMAGES_DIR"
    sudo chmod g+rwx "$IMAGES_DIR"
    echo "  Done."
  fi

  echo ""
  echo "Setup complete."
}

teardown_vm() {
  # Forcibly stop, undefine, and delete VM disk files.
  # Pass "keep_snapshot" as $1 to preserve the snapshot image (used by reset).
  local keep_snapshot="${1:-}"
  virsh destroy "$VM_NAME" 2>/dev/null || true
  virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
  if [[ "$keep_snapshot" == "keep_snapshot" ]]; then
    rm -f "$DISK_PATH" "$SEED_ISO"
  else
    rm -f "$DISK_PATH" "$SEED_ISO" "$SNAPSHOT_PATH"
  fi
}

cmd_halt() {
  require_vm
  local state
  state=$(virsh domstate "$VM_NAME")
  if [[ "$state" != "running" ]]; then
    echo "VM '$VM_NAME' is not running (state: $state)."
    return
  fi
  virsh shutdown "$VM_NAME"
  echo "VM '$VM_NAME' is shutting down."
}

cmd_destroy() {
  if ! virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "VM '$VM_NAME' does not exist."
    return
  fi
  teardown_vm
  echo "VM '$VM_NAME' destroyed."
}

cmd_snapshot() {
  require_vm

  local state
  state=$(virsh domstate "$VM_NAME")
  if [[ "$state" == "running" ]]; then
    echo "Shutting down '$VM_NAME' for snapshot..."
    virsh shutdown "$VM_NAME"
    wait_for_shutdown
  elif [[ "$state" != "shut off" ]]; then
    echo "Error: VM '$VM_NAME' is in state '$state'. Halt it before snapshotting." >&2
    exit 1
  fi

  if [[ -f "$SNAPSHOT_PATH" ]]; then
    echo "Overwriting existing snapshot."
  fi

  echo "Creating snapshot (this may take a few minutes)..."
  qemu-img convert -f qcow2 -O qcow2 "$DISK_PATH" "$SNAPSHOT_PATH"
  echo "Snapshot saved: $SNAPSHOT_PATH"
  echo "Run 'migrant.sh reset' to rebuild the VM from this snapshot."
}

cmd_reset() {
  if [[ ! -f "$SNAPSHOT_PATH" ]]; then
    echo "Error: no snapshot found for '$VM_NAME'." >&2
    echo "  Run 'migrant.sh snapshot' to create one." >&2
    exit 1
  fi

  # Preserve MAC addresses so the rebuilt VM gets the same NICs as the
  # snapshot. cloud-init writes netplan rules that match by MAC address; a
  # new random MAC would cause those rules to match nothing and leave the VM
  # with no network.
  local macs=()
  while IFS= read -r mac; do
    [[ -n "$mac" ]] && macs+=("$mac")
  done < <(virsh domiflist "$VM_NAME" 2>/dev/null | awk 'NR>2 && $5 ~ /^([0-9a-f]{2}:){5}/ { print $5 }')

  teardown_vm keep_snapshot
  echo "VM '$VM_NAME' wiped. Rebuilding..."
  _MIGRANT_RESET_MACS="${macs[*]:-}" cmd_up
}

vm_has_ssh() {
  grep -q 'ssh_authorized_keys' "$CLOUD_INIT_FILE"
}

get_ssh_user() {
  local user
  user=$(awk '/^users:/{f=1} f && /- name:/{print $NF; exit}' "$CLOUD_INIT_FILE")
  if [[ -z "$user" ]]; then
    echo "Error: could not determine username from cloud-init.yml." >&2
    exit 1
  fi
  echo "$user"
}

# Populate the named array variable with SSH client options.
# Usage: build_ssh_opts ARRAY_NAME
build_ssh_opts() {
  # shellcheck disable=SC2178
  local -n _opts=$1
  # LogLevel=ERROR suppresses the "Permanently added ... to known hosts" warning
  # that SSH emits when UserKnownHostsFile=/dev/null absorbs the ephemeral key.
  _opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
  if [[ "${MANAGED_SSH_KEY:-}" == "true" ]]; then
    ensure_managed_key
    if ! vm_has_ssh; then
      echo "Warning: no ssh_authorized_keys found in cloud-init.yml." >&2
      echo "  Run 'migrant.sh pubkey' and add the output, then rebuild with" >&2
      echo "  'migrant.sh destroy && migrant.sh up'." >&2
    fi
    _opts+=(-i "$MANAGED_KEY_PATH" -o IdentitiesOnly=yes)
  else
    if ! vm_has_ssh; then
      echo "Error: no ssh_authorized_keys found in cloud-init.yml." >&2
      echo "Add your public key and rebuild the VM with 'migrant.sh destroy && migrant.sh up'." >&2
      exit 1
    fi
  fi
}

# Populate three caller variables with SSH connection details.
# Usage: resolve_ssh_conn user_var opts_var ip_var
resolve_ssh_conn() {
  local -n _rsc_user=$1 _rsc_ip=$3
  _rsc_user=$(get_ssh_user)
  build_ssh_opts "$2"
  _rsc_ip=$(get_vm_ip_or_die)
}

ensure_managed_key() {
  if [[ ! -f "$MANAGED_KEY_PATH" ]]; then
    echo "Generating managed SSH key at $MANAGED_KEY_PATH..." >&2
    ssh-keygen -t ed25519 -f "$MANAGED_KEY_PATH" -N "" -C "migrant" >/dev/null
    echo "  Add the public key to cloud-init.yml under ssh_authorized_keys:" >&2
    echo "    $(cat "${MANAGED_KEY_PATH}.pub")" >&2
  fi
}

cmd_pubkey() {
  if [[ "${MANAGED_SSH_KEY:-}" != "true" ]]; then
    echo "Error: MANAGED_SSH_KEY is not enabled in Migrantfile." >&2
    exit 1
  fi
  ensure_managed_key
  cat "${MANAGED_KEY_PATH}.pub"
}

cmd_console() {
  require_running
  virsh console "$VM_NAME"
}

cmd_ip() {
  require_running
  get_vm_ip_or_die
}

cmd_ssh() {
  require_running
  local user ssh_opts ip
  resolve_ssh_conn user ssh_opts ip
  # $@ intentionally expands on the client side — these are arguments to the
  # ssh command itself (e.g. a remote command to run), not strings to be passed
  # through to the remote shell for expansion.
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "${user}@${ip}" "$@"
}

cmd_provision() {
  require_running

  if ! command -v ansible-playbook &>/dev/null; then
    echo "Error: ansible-playbook not found. Install Ansible to use provisioning." >&2
    exit 1
  fi

  local playbook="$VM_DIR/playbook.yml"
  if [[ ! -f "$playbook" ]]; then
    echo "No playbook.yml found in $VM_DIR — nothing to provision." >&2
    return 0
  fi

  local user ssh_opts ip
  resolve_ssh_conn user ssh_opts ip

  local ansible_args=(-i "${ip}," -u "$user")
  ansible_args+=(--ssh-extra-args="${ssh_opts[*]}")
  if [[ "${MANAGED_SSH_KEY:-}" == "true" ]]; then
    ansible_args+=(--private-key "$MANAGED_KEY_PATH")
  fi

  echo "Running Ansible playbook..." >&2
  if ANSIBLE_HOST_KEY_CHECKING=false ansible-playbook "${ansible_args[@]}" "$playbook"; then
    echo "Ansible provisioning complete." >&2
  else
    echo "" >&2
    echo "Error: Ansible provisioning failed. The VM is still running." >&2
    echo "  Fix playbook.yml and run 'migrant.sh provision' to retry." >&2
    exit 1
  fi
}

cmd_status() {
  if ! virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "VM '$VM_NAME' has not been created. Run 'migrant.sh up' to create it."
  else
    local state
    state=$(virsh domstate "$VM_NAME")

    case "$state" in
      running)
        echo "VM '$VM_NAME' is running."
        ;;
      shut\ off)
        echo "VM '$VM_NAME' has been created but is not running. Run 'migrant.sh up' to start it."
        ;;
      paused)
        echo "VM '$VM_NAME' is paused."
        ;;
      crashed)
        echo "VM '$VM_NAME' has crashed. Run 'migrant.sh destroy' then 'migrant.sh up' to rebuild it."
        ;;
      *)
        echo "VM '$VM_NAME' is in an unknown state: $state"
        ;;
    esac
  fi

  if [[ -f "$SNAPSHOT_PATH" ]]; then
    echo "Snapshot: $SNAPSHOT_PATH"
  else
    echo "Snapshot: none"
  fi
}

# Print the human-readable disk usage of a single file.
image_file_size() {
  du -sh "$1" 2>/dev/null | cut -f1 || echo "?"
}

cmd_storage() {
  if [[ ! -d "$IMAGES_DIR" ]]; then
    echo "Directory: $IMAGES_DIR (not found)"
    return
  fi

  local total_size
  total_size=$(du -sh "$IMAGES_DIR" 2>/dev/null | cut -f1 || echo "?")
  echo "Directory: $IMAGES_DIR ($total_size)"

  # Collect basenames of all regular files in IMAGES_DIR, sorted
  local all_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && all_files+=("$f")
  done < <(find "$IMAGES_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort)

  # --- Discover migrant-managed VM names ---

  # libvirt_vm_set: VMs currently defined in libvirt with managed-by=migrant.sh.
  # migrant_vm_set: superset — also includes VMs found only via orphaned files.
  # virsh_queried: only annotate '(destroyed)' when we successfully asked libvirt,
  # to avoid falsely marking all VMs as destroyed when libvirtd is not running.
  local -A libvirt_vm_set=()
  local -A migrant_vm_set=()
  local virsh_queried=false

  if command -v virsh &>/dev/null; then
    local virsh_output
    if virsh_output=$(virsh list --all --name 2>/dev/null); then
      virsh_queried=true
      local vname
      while IFS= read -r vname; do
        [[ -z "$vname" ]] && continue
        if virsh desc "$vname" 2>/dev/null | grep -q "managed-by=migrant.sh"; then
          libvirt_vm_set["$vname"]=1
          migrant_vm_set["$vname"]=1
        fi
      done <<< "$virsh_output"
    fi
  fi

  # From seed ISOs: *-seed.iso naming is unique to migrant.sh; catches VMs
  # that no longer exist in libvirt (e.g. after 'destroy' with leftover files)
  local f
  for f in "${all_files[@]+"${all_files[@]}"}"; do
    if [[ "$f" == *-seed.iso ]]; then
      migrant_vm_set["${f%-seed.iso}"]=1
    fi
  done

  local migrant_vms=()
  if [[ ${#migrant_vm_set[@]} -gt 0 ]]; then
    while IFS= read -r vname; do
      [[ -n "$vname" ]] && migrant_vms+=("$vname")
    done < <(printf '%s\n' "${!migrant_vm_set[@]}" | sort)
  fi

  # Mark all VM-associated files as categorized
  local -A categorized=()
  local vm disk_file iso_file snap_file
  for vm in "${migrant_vms[@]+"${migrant_vms[@]}"}"; do
    disk_file="${vm}.qcow2"
    iso_file="${vm}-seed.iso"
    snap_file="${vm}-snapshot.qcow2"
    [[ -f "$IMAGES_DIR/$disk_file" ]] && categorized["$disk_file"]=1
    [[ -f "$IMAGES_DIR/$iso_file" ]]  && categorized["$iso_file"]=1
    [[ -f "$IMAGES_DIR/$snap_file" ]] && categorized["$snap_file"]=1
  done

  # Base images: .img files (downloaded cloud images) not belonging to a VM
  local base_images=()
  for f in "${all_files[@]+"${all_files[@]}"}"; do
    [[ -n "${categorized[$f]:-}" ]] && continue
    if [[ "$f" == *.img ]]; then
      base_images+=("$f")
      categorized["$f"]=1
    fi
  done

  # --- Output ---

  echo "Base Images:"
  if [[ ${#base_images[@]} -eq 0 ]]; then
    echo "    (none)"
  else
    for f in "${base_images[@]}"; do
      echo "    $f ($(image_file_size "$IMAGES_DIR/$f"))"
    done
  fi

  echo "VMs:"
  local vm_count=0
  for vm in "${migrant_vms[@]+"${migrant_vms[@]}"}"; do
    disk_file="${vm}.qcow2"
    iso_file="${vm}-seed.iso"
    snap_file="${vm}-snapshot.qcow2"

    # Collect existing files; skip if none present (e.g. VM stored elsewhere)
    local vm_files=()
    local has_disk=false has_iso=false has_snap=false
    [[ -f "$IMAGES_DIR/$disk_file" ]] && { vm_files+=("$IMAGES_DIR/$disk_file"); has_disk=true; }
    [[ -f "$IMAGES_DIR/$iso_file" ]]  && { vm_files+=("$IMAGES_DIR/$iso_file");  has_iso=true;  }
    [[ -f "$IMAGES_DIR/$snap_file" ]] && { vm_files+=("$IMAGES_DIR/$snap_file"); has_snap=true; }
    [[ ${#vm_files[@]} -eq 0 ]] && continue
    (( vm_count++ )) || true

    local vm_total
    vm_total=$(du -sch "${vm_files[@]}" 2>/dev/null | tail -1 | cut -f1 || echo "?")

    local label="$vm"
    if [[ "$virsh_queried" == true && -z "${libvirt_vm_set[$vm]:-}" ]]; then
      label="$vm (destroyed)"
    fi

    echo "    $label ($vm_total):"
    $has_disk && echo "        Disk:     $disk_file ($(image_file_size "$IMAGES_DIR/$disk_file"))"
    $has_iso  && echo "        Seed ISO: $iso_file ($(image_file_size "$IMAGES_DIR/$iso_file"))"
    $has_snap && echo "        Snapshot: $snap_file ($(image_file_size "$IMAGES_DIR/$snap_file"))"
  done
  if [[ $vm_count -eq 0 ]]; then
    echo "    (none)"
  fi

  # Other: files not matched by any category above
  local other_files=()
  for f in "${all_files[@]+"${all_files[@]}"}"; do
    [[ -z "${categorized[$f]:-}" ]] && other_files+=("$f")
  done
  if [[ ${#other_files[@]} -gt 0 ]]; then
    echo "Other:"
    for f in "${other_files[@]}"; do
      echo "    $f ($(image_file_size "$IMAGES_DIR/$f"))"
    done
  fi
}

case "$SUBCOMMAND" in
  setup)        cmd_setup ;;
  up)           require_config; cmd_up ;;
  halt)         require_config; cmd_halt ;;
  destroy)      require_config; cmd_destroy ;;
  console)      require_config; cmd_console ;;
  ssh)          require_config; cmd_ssh "${@:2}" ;;
  pubkey)       require_config; cmd_pubkey ;;
  ip)           require_config; cmd_ip ;;
  status)       require_config; cmd_status ;;
  snapshot)     require_config; cmd_snapshot ;;
  reset)        require_config; cmd_reset ;;
  provision)    require_config; cmd_provision ;;
  storage)      cmd_storage ;;
  -h|--help|help) usage 0 ;;
  *)              usage ;;
esac
