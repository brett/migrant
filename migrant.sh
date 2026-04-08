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
ZSH_SITE_FUNCTIONS="/usr/share/zsh/site-functions"

usage() {
  cat >&2 <<'EOF'
Usage: migrant.sh <command> [args]

Commands:
  setup               One-time host setup: configures libvirt networking and
                      installs firewall hooks
  up                  Create the VM if it does not exist, or start it if stopped;
                      runs Ansible provisioning (if playbook.yml exists) on first
                      create; waits until the VM is fully ready; connects
                      automatically if AUTOCONNECT is set in the Migrantfile
  halt                Gracefully shut down the VM
  destroy             Stop and permanently delete the VM, its disk, and any snapshots
  provision           Run the Ansible playbook (playbook.yml) against the running VM
  snapshot            Shut down the VM and save a snapshot of its disk;
                      VM stays down afterward
  reset               Destroy the VM and rebuild it from the last snapshot
  status              Show the VM's current state and snapshot availability
  mount               Mount the shared folder loop image for host-side access;
                      creates the image if it does not exist
  unmount             Unmount the shared folder loop image
  ssh [-- cmd...]     SSH into the VM as the configured user; optionally run a
                      remote command (e.g. migrant.sh ssh -- sudo cloud-init status)
  console             Open a serial console session (exit with Ctrl+])
  ip                  Print the VM's IP address
  pubkey              Generate the managed SSH key if needed and print its public key
  storage             List IMAGES_DIR contents grouped by base images and VMs,
                      with file sizes; works without a Migrantfile

Each command reads Migrantfile and cloud-init.yml from the current directory,
or from the directory specified by the MIGRANT_DIR environment variable.
EOF
  exit "${1:-64}"
}

require_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: No Migrantfile found in $VM_DIR" >&2
    exit 78
  fi
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  if [[ -z "${VM_NAME:-}" ]]; then
    echo "Error: 'VM_NAME' is not set in Migrantfile" >&2
    exit 78
  fi
  DISK_PATH="$IMAGES_DIR/${VM_NAME}.qcow2"
  SEED_ISO="$IMAGES_DIR/${VM_NAME}-seed.iso"
  SNAPSHOT_PATH="$IMAGES_DIR/${VM_NAME}-snapshot.qcow2"

  LIBVIRT_NETWORKS=()
  for _nic in "${NETWORKS[@]+"${NETWORKS[@]}"}"; do
    if [[ "$_nic" =~ (^|,)network=([^,]+) ]]; then
      LIBVIRT_NETWORKS+=("${BASH_REMATCH[2]}")
    fi
  done
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
  local timeout=120
  echo "Waiting up to ${timeout}s for '$VM_NAME' to obtain an IP address..." >&2
  local ip
  local deadline=$(( SECONDS + timeout ))
  while true; do
    ip=$(get_vm_ip)
    [[ -n "$ip" ]] && break
    if ! virsh domstate "$VM_NAME" 2>/dev/null | grep -q "^running"; then
      echo "Error: VM '$VM_NAME' is no longer running." >&2
      exit 1
    fi
    if (( SECONDS >= deadline )); then
      echo "Error: timed out waiting for '$VM_NAME' to obtain an IP address." >&2
      exit 75
    fi
    sleep 1
  done
  echo "VM '$VM_NAME' is up at $ip." >&2
}

shared_folder_isolation_enabled() {
  [[ "${SHARED_FOLDER_ISOLATION:-true}" != "false" ]]
}

shared_folder_host_path() {
  local p="${1%%:*}"          # strip :guest_tag suffix, leaving only the host path
  [[ "$p" != /* ]] && p="$VM_DIR/$p"  # resolve relative paths against the VM directory
  echo "$p"
}

wait_for_shutdown() {
  local timeout=60
  echo "Waiting up to ${timeout}s for '$VM_NAME' to shut down..." >&2
  local deadline=$(( SECONDS + timeout ))
  while true; do
    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null) || break
    [[ "$state" == "shut off" ]] && break
    if (( SECONDS >= deadline )); then
      echo "Error: timed out waiting for '$VM_NAME' to shut down." >&2
      echo "  The VM may be unresponsive. Run 'virsh destroy $VM_NAME' to force-stop it." >&2
      exit 75
    fi
    sleep 2
  done

  # If shared folder isolation is enabled, wait for the QEMU hook to unmount
  # the loop images (it does so on the "release" event, just after VM stop).
  if shared_folder_isolation_enabled; then
    local unmount_deadline=$(( SECONDS + 10 ))
    for shared_folder in "${SHARED_FOLDERS[@]+"${SHARED_FOLDERS[@]}"}"; do
      local host_path
      host_path=$(shared_folder_host_path "$shared_folder")
      while mountpoint -q "$host_path" 2>/dev/null; do
        if (( SECONDS >= unmount_deadline )); then
          echo "Error: timed out waiting for '$host_path' to unmount." >&2
          exit 75
        fi
        sleep 1
      done
    done
  fi
}


wait_for_ssh() {
  local user="$1" ip="$2"
  shift 2
  local ssh_opts=("$@")
  local timeout=60
  echo "Waiting up to ${timeout}s for SSH on '$VM_NAME'..." >&2
  local deadline=$(( SECONDS + timeout ))
  while true; do
    if ssh "${ssh_opts[@]}" -o ConnectTimeout=2 -o BatchMode=yes \
        "${user}@${ip}" exit 2>/dev/null; then
      break
    fi
    if (( SECONDS >= deadline )); then
      echo "Error: timed out waiting for SSH on '$VM_NAME'." >&2
      exit 75
    fi
    sleep 1
  done
}

verify_shared_folder_mounts() {
  shared_folder_isolation_enabled || return 0
  [[ -z "${SHARED_FOLDERS[*]+"${SHARED_FOLDERS[*]}"}" ]] && return
  for shared_folder in "${SHARED_FOLDERS[@]}"; do
    local host_path
    host_path=$(shared_folder_host_path "$shared_folder")
    if ! mountpoint -q "$host_path" 2>/dev/null; then
      echo "Error: VM started but '$host_path' is not mounted." >&2
      echo "  The QEMU prepare hook may have failed." >&2
      echo "  Check: sudo journalctl -u libvirtd" >&2
      exit 1
    fi
  done
}

ensure_shared_folder_images() {
  shared_folder_isolation_enabled || return 0
  local loop_hook="/etc/libvirt/hooks/qemu.d/migrant-loop"
  if [[ ! -f "$loop_hook" ]]; then
    echo "Error: shared folder isolation is enabled but the loop image hook is not installed." >&2
    echo "  Run 'migrant.sh setup' first, then re-run this command." >&2
    exit 1
  fi
  local size_gb="${SHARED_FOLDER_SIZE_GB:-10}"
  for shared_folder in "${SHARED_FOLDERS[@]+"${SHARED_FOLDERS[@]}"}"; do
    local host_path
    host_path=$(shared_folder_host_path "$shared_folder")
    local img_path="${host_path%/}.img"
    if [[ -f "$img_path" ]]; then
      local actual_size
      actual_size=$(du --apparent-size -b "$img_path" 2>/dev/null | cut -f1 || echo 0)
      local expected_size=$(( size_gb * 1024 * 1024 * 1024 ))
      if (( actual_size != expected_size )); then
        echo "Note: $img_path is $(( actual_size / 1024 / 1024 / 1024 ))G" \
          "but SHARED_FOLDER_SIZE_GB=${size_gb}." >&2
        echo "  To resize: halt the VM, back up workspace/ contents," \
          "run 'rm $img_path', then 'migrant.sh up'." >&2
      fi
    else
      echo "Creating ${size_gb}G shared folder image at $img_path..."
      truncate -s "${size_gb}G" "$img_path"
      # root_owner: image is created as root so the guest can write to it.
      # ^has_journal: no benefit for a loopback image.
      # ^resize_inode: image is destroyed and recreated rather than resized;
      # disabling it avoids reserving inode table space for online resize.
      if ! mkfs.ext4 -F -q -E root_owner -O ^has_journal,^resize_inode "$img_path"; then
        rm -f "$img_path"
        echo "Error: mkfs.ext4 failed for $img_path." >&2
        exit 74
      fi
      debugfs -w -R "rmdir lost+found" "$img_path" > /dev/null 2>&1
    fi
  done
}

wg_iface_and_table() {
  # Interface name: "wg-" + first 7 hex chars of MD5(vm_name).
  # 7 chars = 28 bits of hash; collision probability is negligible at any
  # realistic number of VMs. The "wg-XXXXXXX" form stays well under the
  # 15-char kernel interface name limit.
  wg_iface="wg-$(printf '%s' "$1" | md5sum | head -c7)"

  # Routing table ID: the same 7 hex chars interpreted as an integer.
  # 7 chars = 28 bits = 268,435,456 possible values; 50% collision probability
  # at ~19,000 VMs. The four kernel-reserved table IDs (0, 253–255) are hit
  # with probability < 2e-6. The same ID is reused as the fwmark value and
  # the ip rule priority, so all three are unique per VM by construction.
  wg_table=$(( 16#$(printf '%s' "$1" | md5sum | head -c7) ))
}

sync_wireguard_config() {
  local wg_src="$VM_DIR/wireguard.conf"
  local managed_dir="/etc/migrant/${VM_NAME}"

  if [[ ! -f "$wg_src" ]]; then
    # Source absent: remove the managed directory so the hook finds nothing.
    rm -rf "$managed_dir"
    return 0
  fi

  if ! command -v wg &>/dev/null; then
    echo "Error: wireguard.conf is present but 'wg' (wireguard-tools) is not installed." >&2
    echo "  Install wireguard-tools or remove wireguard.conf to start without a VPN." >&2
    exit 69  # EX_UNAVAILABLE
  fi

  # Validate that Endpoint is a numeric IP. Done here so the error surfaces in
  # the user's terminal rather than the libvirt journal.
  local wg_endpoint
  wg_endpoint=$(awk -F= '/^\s*Endpoint\s*=/{gsub(/ /,"",$2); print $2}' \
    "$wg_src" | cut -d: -f1)
  if [[ -z "$wg_endpoint" ]]; then
    echo "Error: wireguard.conf has no Endpoint line." >&2
    echo "  Edit wireguard.conf and re-run 'migrant.sh up'." >&2
    exit 65  # EX_DATAERR
  fi
  if [[ ! "$wg_endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: wireguard.conf Endpoint must be a numeric IP, not a hostname ($wg_endpoint)." >&2
    echo "  Edit wireguard.conf and re-run 'migrant.sh up'." >&2
    exit 65  # EX_DATAERR
  fi

  # The subdirectory is owner-only (700): other libvirt group members can create
  # entries in /etc/migrant/ but cannot read each other's private keys.
  # The qemu hook runs as root and is unaffected by these permissions.
  mkdir -p "$managed_dir"
  chmod 700 "$managed_dir"

  # wireguard.conf — raw copy (contains private key; permissions must be tight)
  cp "$wg_src" "$managed_dir/wireguard.conf"
  chmod 600 "$managed_dir/wireguard.conf"

  # wireguard-wg.conf — wg-quick-only fields stripped before passing to wg setconf.
  # wg setconf only understands the core WireGuard kernel interface fields:
  #   [Interface]: PrivateKey, ListenPort, FwMark
  #   [Peer]:      PublicKey, PresharedKey, AllowedIPs, Endpoint, PersistentKeepalive
  # Fields like Address, DNS, MTU, Table, SaveConfig, PostUp/Down, PreUp/Down
  # are wg-quick extensions that wg setconf rejects as parse errors. Strip them
  # all here; Address is normalized to wireguard-address below, DNS to wireguard-dns.
  grep -Ev '^\s*(Address|DNS|MTU|Table|SaveConfig|Pre(Up|Down)|Post(Up|Down))\s*=' \
    "$wg_src" > "$managed_dir/wireguard-wg.conf"
  chmod 600 "$managed_dir/wireguard-wg.conf"

  # wireguard-endpoint — pre-validated numeric endpoint IP; stored so cmd_status
  # can display it without re-parsing wireguard.conf.
  printf '%s' "$wg_endpoint" > "$managed_dir/wireguard-endpoint"
  chmod 600 "$managed_dir/wireguard-endpoint"

  # wireguard-address — normalized comma-separated interface addresses. Multiple
  # Address = lines (or a single comma-separated value) are collapsed to one line
  # by the same pattern used for wireguard-dns. The hook reads this file so it
  # never needs to parse wireguard.conf directly.
  local wg_addrs
  wg_addrs=$(awk -F= '/^\s*Address\s*=/{gsub(/ /,"",$2); printf "%s%s", sep, $2; sep=","}' \
    "$wg_src")
  if [[ -z "$wg_addrs" ]]; then
    echo "Error: wireguard.conf has no Address line." >&2
    echo "  Edit wireguard.conf and re-run 'migrant.sh up'." >&2
    exit 65  # EX_DATAERR
  fi
  printf '%s' "$wg_addrs" > "$managed_dir/wireguard-address"
  chmod 600 "$managed_dir/wireguard-address"

  # wireguard-dns — normalized comma-separated DNS IPs (absent if no DNS line).
  # Consumed by wg_setup_rules and wg_teardown; replaces /run/migrant/${vm}.wgdns.
  local wg_dns
  wg_dns=$(awk -F= '/^\s*DNS\s*=/{gsub(/ /,"",$2); printf "%s%s", sep, $2; sep=","}' \
    "$wg_src")
  if [[ -n "$wg_dns" ]]; then
    printf '%s' "$wg_dns" > "$managed_dir/wireguard-dns"
    chmod 600 "$managed_dir/wireguard-dns"
  else
    rm -f "$managed_dir/wireguard-dns"
    echo "Warning: wireguard.conf has no DNS line — DNS will use the host resolver, not the VPN." >&2
  fi
}

verify_wireguard_tunnel() {
  # No-op if WireGuard is not configured for this VM
  [[ -f "/etc/migrant/${VM_NAME}/wireguard.conf" ]] || return 0

  local wg_iface wg_table wg_table_hex
  wg_iface_and_table "$VM_NAME"
  wg_table_hex=$(printf '%x' "$wg_table")

  # Synchronous checks: interface and ip rule are created in prepare, which
  # completes before virsh start returns.
  if ! ip link show "$wg_iface" &>/dev/null; then
    echo "Error: WireGuard interface $wg_iface is missing after VM start." >&2
    echo "  Traffic is NOT tunneled. Halting VM." >&2
    virsh destroy "$VM_NAME" 2>/dev/null || true
    exit 70  # EX_SOFTWARE
  fi

  if ! ip rule show | grep -q "fwmark 0x${wg_table_hex}"; then
    echo "Error: WireGuard routing rule for $wg_iface is missing after VM start." >&2
    echo "  Traffic is NOT tunneled. Halting VM." >&2
    virsh destroy "$VM_NAME" 2>/dev/null || true
    exit 70  # EX_SOFTWARE
  fi

  # Async check: poll for the sentinel written by wg_setup_rules in 'started'.
  # Its presence confirms the mangle PREROUTING mark rule was successfully
  # applied. Querying iptables directly would require root.
  local deadline=$(( SECONDS + 5 ))
  while [[ ! -f "/run/migrant/${VM_NAME}.wgmark" ]]; do
    if (( SECONDS >= deadline )); then
      echo "Error: WireGuard marking rule not applied after 5s." >&2
      echo "  Traffic is NOT tunneled. Halting VM." >&2
      virsh destroy "$VM_NAME" 2>/dev/null || true
      exit 70  # EX_SOFTWARE
    fi
    sleep 1
  done

  if [[ -f "/run/migrant/${VM_NAME}.wgbadkey" ]]; then
    echo "Warning: WireGuard interface $wg_iface has no public key." >&2
    echo "  The PrivateKey in wireguard.conf is likely invalid." >&2
    echo "  The VM is running but cannot reach the internet through the tunnel." >&2
    echo "  Fix PrivateKey in wireguard.conf, then run: migrant.sh halt && migrant.sh up" >&2
  else
    echo "WireGuard tunnel active: $wg_iface (table $wg_table)." >&2
  fi
}

cmd_up() {
  if [[ ! -f "$CLOUD_INIT_FILE" ]]; then
    echo "Error: No cloud-init.yml found in $VM_DIR" >&2
    exit 78
  fi

  for var in VM_NAME RAM_MB VCPUS DISK_GB IMAGE_URL OS_VARIANT; do
    if [[ -z "${!var:-}" ]]; then
      echo "Error: '$var' is not set in Migrantfile" >&2
      exit 78
    fi
  done

  local base_image="${IMAGE_URL##*/}"

  # Start any configured networks that exist but are not active.
  for _net in "${LIBVIRT_NETWORKS[@]+"${LIBVIRT_NETWORKS[@]}"}"; do
    if virsh net-info "$_net" &>/dev/null \
        && ! virsh net-list --name | grep -qx "$_net"; then
      echo "Starting libvirt network '$_net'..."
      virsh net-start "$_net"
    fi
  done

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
      exit 78
    fi

    local state
    state=$(virsh domstate "$VM_NAME")
    if [[ "$state" == "running" ]]; then
      echo "VM '$VM_NAME' is already running."
      do_autoconnect
      return
    fi
    check_managed_key_match start
    echo "VM '$VM_NAME' exists but is not running. Starting..."
    ensure_shared_folder_images
    sync_wireguard_config
    virsh start "$VM_NAME"
    verify_shared_folder_mounts
    verify_wireguard_tunnel
    if [[ "${AUTOCONNECT:-}" == "console" ]]; then
      do_autoconnect
      return
    fi
    wait_for_ip
    if vm_has_ssh && [[ "${AUTOCONNECT:-}" != "ssh" ]]; then
      local user ssh_opts ip
      resolve_ssh_conn user ssh_opts ip
      wait_for_ssh "$user" "$ip" "${ssh_opts[@]}"
    fi
    do_autoconnect
    return
  fi

  local from_snapshot=false
  [[ -f "$SNAPSHOT_PATH" ]] && from_snapshot=true

  if [[ "$from_snapshot" == true ]]; then
    check_managed_key_match reset
  else
    check_managed_key_match create
  fi

  check_kvm

  echo "VM '$VM_NAME' not found. Creating..."

  mkdir -p "$IMAGES_DIR"

  local base_image_path
  if [[ "$from_snapshot" == true ]]; then
    echo "Using snapshot: $SNAPSHOT_PATH"
    base_image_path="$SNAPSHOT_PATH"
  else
    base_image_path="$IMAGES_DIR/$base_image"
    # Always re-copy file:// images (local builds like NixOS) since the
    # source may have been rebuilt. Remote images are cached.
    if [[ ! -f "$base_image_path" ]] || [[ "$IMAGE_URL" == file://* ]]; then
      echo "Copying base image..."
      if ! curl --fail -L -o "$base_image_path" "$IMAGE_URL"; then
        echo "Error: Failed to fetch base image. Check IMAGE_URL in Migrantfile." >&2
        rm -f "$base_image_path"
        exit 74
      fi
      if ! qemu-img info "$base_image_path" &>/dev/null; then
        echo "Error: Downloaded file is not a valid disk image. Check IMAGE_URL in Migrantfile." >&2
        rm -f "$base_image_path"
        exit 65
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

  ensure_shared_folder_images

  local extra_args=()
  local has_shared_folders=false

  for shared_folder in "${SHARED_FOLDERS[@]+"${SHARED_FOLDERS[@]}"}"; do
    local host_path guest_tag="${shared_folder##*:}"
    host_path=$(shared_folder_host_path "$shared_folder")
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

  if [[ "${BOOT_FIRMWARE:-}" == "uefi" ]]; then
    extra_args+=(--boot firmware=efi)
  fi

  local vm_description="managed-by=migrant.sh"
  [[ "${NETWORK_ISOLATION:-}" == "true" ]] \
    && vm_description+=",network-isolation=true"
  [[ "${SHARED_FOLDER_ISOLATION:-true}" == "false" ]] \
    && vm_description+=",shared-folder-isolation=false"

  sync_wireguard_config

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

  verify_shared_folder_mounts
  verify_wireguard_tunnel

  # AUTOCONNECT=console with no provisioning needed: attach immediately after
  # the VM starts, letting the user watch the boot. Skip wait_for_ip entirely.
  if [[ "${AUTOCONNECT:-}" == "console" ]] \
      && { [[ "$from_snapshot" == true ]] || [[ ! -f "$VM_DIR/playbook.yml" ]]; }; then
    do_autoconnect
    return
  fi

  wait_for_ip

  if [[ "$from_snapshot" == false ]] && [[ -f "$VM_DIR/playbook.yml" ]]; then
    local user ssh_opts ip
    resolve_ssh_conn user ssh_opts ip

    wait_for_ssh "$user" "$ip" "${ssh_opts[@]}"

    if [[ "${CLOUD_INIT_WAIT:-true}" == true ]]; then
      echo "Waiting for cloud-init to finish..." >&2
      if ! ssh "${ssh_opts[@]}" "${user}@${ip}" sudo cloud-init status --wait; then
        echo "" >&2
        echo "Error: cloud-init failed on '$VM_NAME'." >&2
        echo "  Run 'migrant.sh ssh -- sudo cloud-init status' for details." >&2
        exit 70
      fi
      echo "cloud-init done." >&2
    fi

    cmd_provision
    echo "VM '$VM_NAME' is ready." >&2
  elif [[ "$from_snapshot" == false ]]; then
    if [[ "${CLOUD_INIT_WAIT:-true}" == true ]]; then
      echo "" >&2
      echo "Note: cloud-init is still provisioning in the background." >&2
      echo "  Monitor progress : migrant.sh ssh -- sudo tail -f /var/log/cloud-init-output.log" >&2
      echo "  Wait for finish  : migrant.sh ssh -- sudo cloud-init status --wait" >&2
    fi
  fi

  do_autoconnect
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

  # All temp files are created upfront so a single trap covers them.
  # SC2064: expand now — these vars are local and will be out of scope on EXIT
  local expected_qemu_hook expected_network_hook net_xml expected_loop_hook expected_zsh_completion
  expected_qemu_hook=$(mktemp)
  expected_network_hook=$(mktemp)
  net_xml=$(mktemp --suffix=.xml)
  expected_loop_hook=$(mktemp)
  expected_zsh_completion=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$expected_qemu_hook' '$expected_network_hook' '$net_xml' '$expected_loop_hook' '$expected_zsh_completion'" EXIT

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

  # --- /etc/migrant/ (WireGuard managed config directory) ---
  echo ""
  if [[ ! -d /etc/migrant ]]; then
    echo "Creating /etc/migrant for WireGuard managed configs..."
    sudo mkdir -p /etc/migrant
    sudo chown root:libvirt /etc/migrant
    sudo chmod 2770 /etc/migrant
    echo "  Created."
  elif [[ "$(stat -c '%G' /etc/migrant)" != "libvirt" \
       || "$(stat -c '%a' /etc/migrant)" != "2770" ]]; then
    echo "Updating /etc/migrant permissions..."
    sudo chown root:libvirt /etc/migrant
    sudo chmod 2770 /etc/migrant
    echo "  Updated."
  else
    echo "/etc/migrant already configured."
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

  # --- qemu hook (network isolation + WireGuard) ---
  echo ""
  cat > "$expected_qemu_hook" << 'MIGRANT_QEMU_EOF'
#!/bin/bash
# Managed by migrant.sh

VM_NAME="$1"
OPERATION="$2"
# iptables chain names are limited to 29 characters; hash the VM name so
# the chain name stays within that limit regardless of VM name length.
CHAIN="MIGRANT_$(printf '%s' "$VM_NAME" | md5sum | head -c8)"

# All stderr goes to a persistent log file. libvirtd does not reliably forward
# hook stderr to the journal, so this is the only reliable debug channel.
# /run is tmpfs and clears on reboot; the log accumulates across hook calls.
mkdir -p /run/migrant
exec 2>>/run/migrant/hook.log
echo "$(date --iso-8601=seconds) [$VM_NAME $OPERATION] hook start" >&2

# Read the domain XML from stdin. libvirt pipes it to the hook for every
# operation, so this is always available — unlike the persistent XML file,
# which may not exist yet when the hook fires during initial virt-install.
# (Never call virsh here: hooks run while libvirtd holds the per-domain lock,
# so calling virsh against the same domain deadlocks.)
xml=$(cat)
echo "$xml" | grep -q "managed-by=migrant.sh" || exit 0

HAS_NETWORK_ISOLATION=false
echo "$xml" | grep -q "network-isolation=true" && HAS_NETWORK_ISOLATION=true

VM_MAC=$(echo "$xml" | grep -o "mac address='[^']*'" | head -1 | cut -d"'" -f2)

wg_iface_and_table() {
  # Interface name: "wg-" + first 7 hex chars of MD5(vm_name).
  # 7 chars = 28 bits of hash; collision probability is negligible at any
  # realistic number of VMs. The "wg-XXXXXXX" form stays well under the
  # 15-char kernel interface name limit.
  WG_IFACE="wg-$(printf '%s' "$1" | md5sum | head -c7)"

  # Routing table ID: the same 7 hex chars interpreted as an integer.
  # 7 chars = 28 bits = 268,435,456 possible values; 50% collision probability
  # at ~19,000 VMs. The four kernel-reserved table IDs (0, 253–255) are hit
  # with probability < 2e-6. The same ID is reused as the fwmark value and
  # the ip rule priority, so all three are unique per VM by construction.
  WG_TABLE=$(( 16#$(printf '%s' "$1" | md5sum | head -c7) ))
}

vm_block_mac() {
  local vm="$1"
  [[ "$HAS_NETWORK_ISOLATION" == true ]] \
    || [[ -f "/etc/migrant/${vm}/wireguard.conf" ]] \
    || return 0
  [[ -z "$VM_MAC" ]] && return 0

  # nftables bridge 'prerouting' is the right hook: internet-bound traffic from
  # the VM reaches the bridge with the gateway MAC as destination, so it is
  # handled by the bridge input path — not the forward path between ports.
  # The 'prerouting' hook catches all bridge traffic regardless of path.
  #
  # Infrastructure (table, set, chain, drop rule) is shared across VMs.
  # 'add' is idempotent on table and set; the chain add returns non-zero if it
  # already exists, which is used to gate the one-time rule insertion.
  nft add table bridge migrant 2>/dev/null || true
  nft add set bridge migrant blocked_macs \
    '{ type ether_addr ; }' 2>/dev/null || true
  if nft add chain bridge migrant prerouting \
      '{ type filter hook prerouting priority -200 ; policy accept ; }' 2>/dev/null; then
    nft add rule bridge migrant prerouting ether saddr @blocked_macs drop
  fi

  # Remove any stale MAC entry from a previous failed setup, then add this VM.
  nft delete element bridge migrant blocked_macs "{ $VM_MAC }" 2>/dev/null || true
  nft add element bridge migrant blocked_macs "{ $VM_MAC }"
}

wg_setup_iface() {
  local vm="$1"
  local managed="/etc/migrant/${vm}"
  [[ -f "$managed/wireguard.conf" ]] || return 0

  # wg absence was already caught by cmd_up before virsh start was called,
  # but check defensively in case the hook fires via another path.
  command -v wg &>/dev/null || {
    echo "migrant: wg_setup_iface: 'wg' not found; cannot set up tunnel for $vm" >&2
    return 2
  }

  local WG_IFACE WG_TABLE
  wg_iface_and_table "$vm"

  # Clean up any state left by a previous failed setup attempt. Without this, a
  # partial failure (e.g. wg setconf fails on a malformed key) leaves the
  # interface in the kernel. The next start attempt then fails at ip link add
  # with "File exists" and the VM cannot start until the user manually runs
  # ip link del. ip route flush and ip rule del are similarly defensive.
  ip link del "$WG_IFACE" 2>/dev/null || true
  ip route flush table "$WG_TABLE" 2>/dev/null || true
  ip rule del fwmark "$WG_TABLE" lookup "$WG_TABLE" 2>/dev/null || true

  ip link add "$WG_IFACE" type wireguard 2>/dev/null || {
    echo "migrant: wg_setup_iface: failed to create WireGuard interface for $vm" >&2
    echo "migrant: is the 'wireguard' kernel module available? (try: modprobe wireguard)" >&2
    return 3
  }

  # Disable reverse path filtering on the WireGuard interface. With the default
  # rp_filter=1 (strict mode, the default on linux-hardened), the kernel checks
  # that the route to a packet's source address uses the same interface the
  # packet arrived on. Decrypted packets from the Mullvad peer arrive on
  # wg-XXXXXXX but are destined for 192.168.200.X; the route to that subnet
  # goes via virbr-migrant, so strict rp_filter silently drops them. This is
  # the same issue that affects virbr-migrant itself and is handled there by
  # the existing network hook (migrant-network). The sysctl entry is created
  # by the kernel when the interface is added and disappears when it is deleted,
  # so no cleanup is needed in wg_teardown.
  sysctl -w "net.ipv4.conf.${WG_IFACE}.rp_filter=0" >/dev/null

  # wireguard-wg.conf has DNS lines stripped at sync time; no temp file needed.
  wg setconf "$WG_IFACE" "$managed/wireguard-wg.conf"

  # A valid PrivateKey lets WireGuard derive a public key immediately. If the
  # key is malformed (e.g. wrong length after base64-decoding), the kernel
  # accepts the config but the interface has no public key. Detect this here
  # while we have root, write a sentinel so cmd_up can warn without sudo.
  local pub_key
  pub_key=$(wg show "$WG_IFACE" public-key 2>/dev/null || true)
  if [[ -z "$pub_key" || "$pub_key" == "(none)" ]]; then
    echo "migrant: WireGuard: PrivateKey in wireguard.conf for $vm is invalid — no public key derived" >&2
    touch "/run/migrant/${vm}.wgbadkey"
  else
    rm -f "/run/migrant/${vm}.wgbadkey"
  fi

  IFS=',' read -ra addr_list <<< "$(cat "$managed/wireguard-address")"
  for addr in "${addr_list[@]}"; do
    addr="${addr// /}"
    [[ -n "$addr" ]] && ip addr add "$addr" dev "$WG_IFACE"
  done
  # WireGuard adds ~60 bytes of per-packet overhead; 1420 keeps encapsulated
  # packets under the 1500-byte Ethernet MTU and prevents fragmentation.
  ip link set "$WG_IFACE" mtu 1420
  ip link set "$WG_IFACE" up

  # All VM traffic exits via the WireGuard interface. No endpoint exclusion
  # route is needed: WireGuard's encrypted UDP is locally generated (OUTPUT
  # path) and is never marked by the PREROUTING rule, so it routes via the
  # main table without interference.
  ip route add default dev "$WG_IFACE" table "$WG_TABLE"

  # Policy rule: divert marked packets to the WireGuard table. This does not
  # require the tap interface and is placed here (prepare) so that
  # verify_wireguard_tunnel can confirm it synchronously after virsh start
  # returns, with no polling required.
  #
  # Priority 100 places this rule before the main table (32766). WG_TABLE is
  # not used as the priority: its value is in [0, 2^28-1], which is always
  # above 32766, so the main table would win and the fwmark rule would never
  # be reached. The fwmark condition already uniquely identifies this VM's
  # traffic; a shared low priority is fine for multiple simultaneous VMs.
  ip rule add fwmark "$WG_TABLE" lookup "$WG_TABLE" priority 100

  echo "migrant: WireGuard interface up: $WG_IFACE (table $WG_TABLE) for $vm" >&2
}

wg_setup_rules() {
  local vm="$1" iface="$2"
  [[ -f "/etc/migrant/${vm}/wireguard.conf" ]] || return 0

  local WG_IFACE WG_TABLE
  wg_iface_and_table "$vm"

  # Mark all packets from this VM's tap with the WireGuard table ID. The policy
  # rule that routes marked packets via the WireGuard table was already added in
  # the prepare hook (wg_setup_iface), where it doesn't require the tap interface.
  #
  # -m physdev --physdev-in is required here instead of plain -i. In iptables
  # PREROUTING, bridged packets appear to arrive on the bridge device
  # (virbr-migrant), not the physical tap port (vnet1). physdev matches the
  # underlying bridge port, which is what uniquely identifies this VM's traffic.
  iptables -t mangle -A PREROUTING \
    -m physdev --physdev-in "$iface" -j MARK --set-mark "$WG_TABLE"

  # Drop all IPv6 from this VM. The fwmark routing is IPv4-only; without this
  # rule IPv6 traffic would bypass the tunnel and exit via the host's default
  # IPv6 path. The libvirt network provides no routable IPv6 to VMs, so this
  # rule enforces an existing de-facto limitation rather than removing capability.
  ip6tables -I FORWARD -m physdev --physdev-in "$iface" -j DROP

  # DNS handling — IPs pre-parsed and normalized at sync time.
  # For each DNS IP:
  #   1. FORWARD ACCEPT punches through the NI RFC1918 REJECT rules so the
  #      query can be forwarded through the WireGuard tunnel.
  #   2. DNAT in nat PREROUTING intercepts all DNS traffic from the VM
  #      (regardless of the destination the VM chose) and rewrites the
  #      destination to the configured DNS IP. This forces DNS through the
  #      tunnel without any configuration inside the VM — the VM continues
  #      to believe it is talking to 192.168.200.1; conntrack reverses the
  #      translation on the response. physdev is required for the same
  #      reason it is required for the mangle mark rule above.
  local wg_dns_file="/etc/migrant/${vm}/wireguard-dns"
  if [[ -f "$wg_dns_file" ]]; then
    local first_dns=""
    IFS=',' read -ra dns_list <<< "$(cat "$wg_dns_file")"
    for dns_ip in "${dns_list[@]}"; do
      dns_ip="${dns_ip// /}"
      [[ -z "$dns_ip" ]] && continue
      iptables -I FORWARD -m physdev --physdev-in "$iface" -d "${dns_ip}/32" -j ACCEPT
      [[ -z "$first_dns" ]] && first_dns="$dns_ip"
    done
    if [[ -n "$first_dns" ]]; then
      iptables -t nat -A PREROUTING \
        -m physdev --physdev-in "$iface" -p udp --dport 53 \
        -j DNAT --to-destination "$first_dns"
      iptables -t nat -A PREROUTING \
        -m physdev --physdev-in "$iface" -p tcp --dport 53 \
        -j DNAT --to-destination "$first_dns"
    fi
  fi

  echo "migrant: WireGuard routing rules applied for $vm ($iface → $WG_IFACE)" >&2
}

wg_teardown() {
  local vm="$1" iface="$2"

  local WG_IFACE WG_TABLE
  wg_iface_and_table "$vm"

  iptables -t mangle -D PREROUTING \
    -m physdev --physdev-in "$iface" -j MARK \
    --set-mark "$WG_TABLE" 2>/dev/null || true
  ip rule del fwmark "$WG_TABLE" lookup "$WG_TABLE" 2>/dev/null || true
  ip route flush table "$WG_TABLE" 2>/dev/null || true

  ip6tables -D FORWARD -m physdev --physdev-in "$iface" -j DROP 2>/dev/null || true

  local wg_dns_file="/etc/migrant/${vm}/wireguard-dns"
  if [[ -f "$wg_dns_file" ]]; then
    local first_dns=""
    IFS=',' read -ra dns_list <<< "$(cat "$wg_dns_file")"
    for dns_ip in "${dns_list[@]}"; do
      dns_ip="${dns_ip// /}"
      [[ -z "$dns_ip" ]] && continue
      iptables -D FORWARD -m physdev --physdev-in "$iface" -d "${dns_ip}/32" -j ACCEPT 2>/dev/null || true
      [[ -z "$first_dns" ]] && first_dns="$dns_ip"
    done
    if [[ -n "$first_dns" ]]; then
      iptables -t nat -D PREROUTING \
        -m physdev --physdev-in "$iface" -p udp --dport 53 \
        -j DNAT --to-destination "$first_dns" 2>/dev/null || true
      iptables -t nat -D PREROUTING \
        -m physdev --physdev-in "$iface" -p tcp --dport 53 \
        -j DNAT --to-destination "$first_dns" 2>/dev/null || true
    fi
  fi

  ip link set "$WG_IFACE" down 2>/dev/null || true
  ip link del "$WG_IFACE" 2>/dev/null || true

  rm -f "/run/migrant/${vm}.wgmark"
  rm -f "/run/migrant/${vm}.wgbadkey"

  # Defensive cleanup: if wg_setup_rules never ran (e.g. 'started' hook
  # crashed before unblocking), the MAC entry may still be in the set.
  nft delete element bridge migrant blocked_macs "{ $VM_MAC }" 2>/dev/null || true

  echo "migrant: WireGuard torn down: $WG_IFACE for $vm" >&2
}

apply_rules() {
  local vm="$1"
  echo "$(date --iso-8601=seconds) [$vm started] apply_rules: enter" >&2

  # No work needed if this VM uses neither network isolation nor WireGuard.
  [[ "$HAS_NETWORK_ISOLATION" == true ]] \
    || [[ -f "/etc/migrant/${vm}/wireguard.conf" ]] \
    || return 0

  # Locate the tap interface for this VM without calling virsh.
  local iface=""

  # libvirt assigns tap interfaces before firing 'started begin', so the live
  # domain XML always contains <target dev='vnetN'/> by this point.
  # Anchor to 'vnet' to avoid matching disk targets (<target dev='vda' bus='virtio'/>).
  # Try both quote forms since XML permits either.
  iface=$(echo "$xml" | grep -o "target dev='vnet[^']*'" | head -1 | cut -d"'" -f2)
  if [[ -z "$iface" ]]; then
    iface=$(echo "$xml" | grep -o 'target dev="vnet[^"]*"' | head -1 | cut -d'"' -f2)
  fi

  if [[ -z "$iface" ]]; then
    echo "$(date --iso-8601=seconds) [$vm started] no tap found; XML target lines:" >&2
    echo "$xml" | grep -i "target" >&2
    echo "migrant: no tap interface found for $vm" >&2
    return 4
  fi

  mkdir -p /run/migrant
  echo "$iface" > "/run/migrant/${vm}.iface"

  if [[ "$HAS_NETWORK_ISOLATION" == true ]]; then
    # Per-VM INPUT chain: block new connections from VM to host.
    # Appended (not inserted) so libvirt's LIBVIRT_INP chain — which accepts
    # DHCP and DNS destined for dnsmasq — runs first.
    iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
    iptables -A "$CHAIN" -m conntrack --ctstate NEW -j REJECT
    iptables -A INPUT -m physdev --physdev-in "$iface" -j "$CHAIN"

    # Block VM-to-LAN (all RFC1918 ranges, including the libvirt subnet itself
    # so VMs cannot communicate with each other over the shared bridge)
    iptables -I FORWARD -m physdev --physdev-in "$iface" -d 10.0.0.0/8 -j REJECT
    iptables -I FORWARD -m physdev --physdev-in "$iface" -d 172.16.0.0/12 -j REJECT
    iptables -I FORWARD -m physdev --physdev-in "$iface" -d 192.168.0.0/16 -j REJECT
  fi

  wg_setup_rules "$vm" "$iface"

  # Unblock the VM's MAC now that all rules are in place (both NI and WG).
  # vm_block_mac ran in prepare for any managed VM; this is the corresponding
  # unblock. It runs here — not inside wg_setup_rules — so NI-only VMs are
  # also unblocked after their REJECT rules are applied.
  nft delete element bridge migrant blocked_macs "{ $VM_MAC }" 2>/dev/null || true

  # Sentinel: written last so its presence implies all rules applied and MAC
  # unblocked. verify_wireguard_tunnel polls for this rather than querying
  # iptables (which requires root). Deleted by wg_teardown on release.
  if [[ -f "/etc/migrant/${vm}/wireguard.conf" ]]; then
    echo "ok" > "/run/migrant/${vm}.wgmark"
  fi
}

remove_rules() {
  local vm="$1"
  local iface
  iface=$(cat "/run/migrant/${vm}.iface" 2>/dev/null) || return 0
  [[ -z "$iface" ]] && return 0

  if [[ "$HAS_NETWORK_ISOLATION" == true ]]; then
    iptables -D INPUT -m physdev --physdev-in "$iface" -j "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN" 2>/dev/null || true
    iptables -X "$CHAIN" 2>/dev/null || true

    iptables -D FORWARD -m physdev --physdev-in "$iface" -d 10.0.0.0/8 -j REJECT 2>/dev/null || true
    iptables -D FORWARD -m physdev --physdev-in "$iface" -d 172.16.0.0/12 -j REJECT 2>/dev/null || true
    iptables -D FORWARD -m physdev --physdev-in "$iface" -d 192.168.0.0/16 -j REJECT 2>/dev/null || true
  fi

  local WG_IFACE WG_TABLE
  wg_iface_and_table "$vm"
  if ip link show "$WG_IFACE" &>/dev/null \
      || [[ -f "/etc/migrant/${vm}/wireguard-dns" ]]; then
    wg_teardown "$vm" "$iface"
  fi

  # Defensive MAC cleanup: covers NI-only VMs (wg_teardown never runs for them)
  # and any case where apply_rules crashed before the unblock. Idempotent.
  nft delete element bridge migrant blocked_macs "{ $VM_MAC }" 2>/dev/null || true

  rm -f "/run/migrant/${vm}.iface"
}

case "$OPERATION" in
  prepare) vm_block_mac   "$VM_NAME"    # all managed VMs (NI or WG)
           wg_setup_iface "$VM_NAME" ;; # WG VMs only
  started) apply_rules    "$VM_NAME" ;; # NI rules + wg_setup_rules; unblock MAC; sentinel
  release) remove_rules   "$VM_NAME" ;; # wg_teardown if WG; defensive MAC cleanup
esac
MIGRANT_QEMU_EOF
  if [[ -f "$qemu_hook" ]] && cmp -s "$expected_qemu_hook" "$qemu_hook"; then
    echo "VM hook already up to date."
  else
    if [[ ! -f "$qemu_hook" ]]; then
      echo "Installing VM hook ($qemu_hook)."
      echo "  When a migrant.sh-managed VM starts, this hook:"
      echo "    - sets up a WireGuard tunnel (if wireguard.conf is present in the VM directory)"
      echo "    - blocks the VM from initiating new connections to the host (if NETWORK_ISOLATION=true)"
      echo "    - blocks the VM from reaching other hosts on the local network (if NETWORK_ISOLATION=true)"
      echo "  All rules and interfaces are removed automatically when the VM stops."
    else
      echo "VM hook is outdated, reinstalling ($qemu_hook)."
    fi
    echo "  Elevated permissions are required to write to /etc/libvirt/hooks/."
    install_hook "$expected_qemu_hook" "$qemu_hook"
    echo "  Installed."
  fi

  # --- qemu hook (loop image mount/unmount) ---
  echo ""
  local loop_hook="/etc/libvirt/hooks/qemu.d/migrant-loop"

  cat > "$expected_loop_hook" << 'MIGRANT_LOOP_EOF'
#!/bin/bash
# Managed by migrant.sh

VM_NAME="$1"
OPERATION="$2"

# Read the domain XML from stdin. libvirt pipes it to the hook for every
# operation, so this is always available — unlike the persistent XML file,
# which may not exist yet when the hook fires during initial virt-install.
# (Never call virsh here: hooks run while libvirtd holds the per-domain lock,
# so calling virsh against the same domain deadlocks.)
local_xml=$(mktemp)
trap 'rm -f "$local_xml"' EXIT
cat > "$local_xml"
grep -q "managed-by=migrant.sh" "$local_xml" || exit 0
grep -q "shared-folder-isolation=false" "$local_xml" && exit 0

# Extract the source directory for each virtiofs filesystem from the domain XML.
# python3 is used for robust XML parsing; it is available on all target systems.
virtiofs_sources() {
  python3 - "$local_xml" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.argv[1])
for fs in tree.findall('.//filesystem'):
    drv = fs.find('driver')
    if drv is not None and drv.get('type') == 'virtiofs':
        src = fs.find('source')
        if src is not None and src.get('dir'):
            print(src.get('dir'))
PYEOF
}

mount_shared_folders() {
  local sources=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && sources+=("$line")
  done < <(virtiofs_sources)

  if [[ ${#sources[@]} -eq 0 ]]; then
    echo "migrant: no virtiofs filesystems found in $local_xml" >&2
    return
  fi

  for source_dir in "${sources[@]}"; do
    local img_path="${source_dir%/}.img"

    if [[ ! -f "$img_path" ]]; then
      # Image absent despite isolation being enabled. Refuse to start rather
      # than silently serve an unprotected directory — the user opted into
      # isolation and must not be left thinking it is in effect when it is not.
      # A non-zero exit from a prepare hook causes libvirt to abort VM startup.
      echo "migrant: error: shared folder image not found: $img_path" >&2
      echo "migrant: run 'migrant.sh up' to recreate it" >&2
      exit 1
    fi

    if mountpoint -q "$source_dir" 2>/dev/null; then
      echo "migrant: $source_dir already mounted" >&2
      continue
    fi

    mkdir -p "$source_dir"
    if mount -o loop,nosymfollow "$img_path" "$source_dir"; then
      echo "migrant: mounted $img_path at $source_dir" >&2
    else
      echo "migrant: failed to mount $img_path at $source_dir" >&2
    fi
  done
}

unmount_shared_folders() {
  local sources=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && sources+=("$line")
  done < <(virtiofs_sources)

  for source_dir in "${sources[@]}"; do
    if mountpoint -q "$source_dir" 2>/dev/null; then
      if umount "$source_dir"; then
        echo "migrant: unmounted $source_dir" >&2
      else
        echo "migrant: failed to unmount $source_dir" >&2
      fi
    else
      echo "migrant: $source_dir not mounted, skipping" >&2
    fi
  done
}

case "$OPERATION" in
  prepare)
    echo "migrant: loop-hook prepare ${VM_NAME}" >&2
    mount_shared_folders
    ;;
  release)
    echo "migrant: loop-hook release ${VM_NAME}" >&2
    unmount_shared_folders
    ;;
esac
MIGRANT_LOOP_EOF
  if [[ -f "$loop_hook" ]] && cmp -s "$expected_loop_hook" "$loop_hook"; then
    echo "Shared folder loop image hook already up to date."
  else
    if [[ ! -f "$loop_hook" ]]; then
      echo "Installing shared folder loop image hook ($loop_hook)."
      echo "  When a migrant.sh-managed VM starts, the shared folder loop image"
      echo "  will be mounted with nosymfollow before virtiofsd starts."
      echo "  The image is unmounted automatically when the VM stops."
    else
      echo "Shared folder loop image hook is outdated, reinstalling ($loop_hook)."
    fi
    echo "  Elevated permissions are required to write to /etc/libvirt/hooks/."
    install_hook "$expected_loop_hook" "$loop_hook"
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
if [[ "$1" == "migrant" && "$2" == "started" ]]; then
  sysctl -w "net.ipv4.conf.virbr-migrant.rp_filter=0"
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

  # --- migrant network ---
  echo ""
  if virsh net-info migrant &>/dev/null; then
    echo "Migrant libvirt network already exists."
    if virsh net-info migrant | grep -q "Autostart:.*yes"; then
      virsh net-autostart migrant --disable
      echo "  Autostart disabled — 'migrant.sh up' will start it on demand."
    fi
  else
    echo "Creating migrant libvirt network..."
    cat > "$net_xml" << 'NET_EOF'
<network>
  <name>migrant</name>
  <forward mode="nat"/>
  <bridge name="virbr-migrant" stp="on" delay="0"/>
  <mac address="52:54:00:0a:cd:21"/>
  <ip address="192.168.200.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.200.2" end="192.168.200.254"/>
    </dhcp>
  </ip>
</network>
NET_EOF
    virsh net-define "$net_xml"
    echo "  Migrant network defined."
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

  # --- ZSH completions ---
  echo ""
  if [[ -d "$ZSH_SITE_FUNCTIONS" ]]; then
    cat > "$expected_zsh_completion" << 'MIGRANT_ZSH_EOF'
#compdef migrant.sh

_migrant() {
  local -a subcommands
  subcommands=(
    "setup:One-time host setup: configures libvirt networking and installs firewall hooks"
    "up:Create the VM if it does not exist, or start it if stopped"
    "halt:Gracefully shut down the VM"
    "destroy:Stop and permanently delete the VM, its disk, and any snapshots"
    "provision:Run the Ansible playbook against the running VM"
    "snapshot:Shut down the VM and save a snapshot of its disk"
    "reset:Destroy the VM and rebuild it from the last snapshot"
    "status:Show the VM's current state and snapshot availability"
    "mount:Mount the shared folder loop image for host-side access"
    "unmount:Unmount the shared folder loop image"
    "ssh:SSH into the VM; optionally run a remote command"
    "console:Open a serial console session"
    "ip:Print the VM's IP address"
    "pubkey:Generate the managed SSH key if needed and print its public key"
    "storage:List IMAGES_DIR contents grouped by base images and VMs"
  )

  if (( CURRENT == 2 )); then
    _describe 'command' subcommands
    # 'umount' is a common typo; complete it as 'unmount'
    [[ $PREFIX == um* ]] && compadd -U -- unmount
  elif [[ $words[2] == ssh ]] && (( CURRENT == 3 )); then
    compadd -- '--'
  fi
}

_migrant "$@"
MIGRANT_ZSH_EOF

    local zsh_completion_dest="$ZSH_SITE_FUNCTIONS/_migrant"
    if [[ -f "$zsh_completion_dest" ]] && cmp -s "$expected_zsh_completion" "$zsh_completion_dest"; then
      echo "ZSH completions already up to date."
    else
      if [[ ! -f "$zsh_completion_dest" ]]; then
        echo "Installing ZSH completions ($zsh_completion_dest)."
      else
        echo "ZSH completions are outdated, reinstalling ($zsh_completion_dest)."
      fi
      echo "  Elevated permissions are required to write to $ZSH_SITE_FUNCTIONS/."
      sudo install -m 644 "$expected_zsh_completion" "$zsh_completion_dest"
      echo "  Installed. Run 'compinit' or start a new shell to activate."
    fi
  fi

  echo ""
  echo "Setup complete."
}

teardown_vm() {
  # Forcibly stop, undefine, and delete VM disk files.
  # Pass "keep_snapshot" as $1 to preserve the snapshot image (used by reset).
  local keep_snapshot="${1:-}"
  virsh destroy "$VM_NAME" 2>/dev/null || true
  virsh undefine "$VM_NAME" --remove-all-storage --nvram 2>/dev/null || true
  rm -rf "/etc/migrant/${VM_NAME}"
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
  wait_for_shutdown
  echo "VM '$VM_NAME' has stopped."

  # Destroy libvirt networks that are no longer in use.
  for _net in "${LIBVIRT_NETWORKS[@]+"${LIBVIRT_NETWORKS[@]}"}"; do
    virsh net-list --name 2>/dev/null | grep -qw "^${_net}$" || continue

    # Get list of other running VMs.
    local running_vms
    mapfile -t running_vms < <(virsh list --state-running --name \
      | grep '[^[:space:]]' || true)

    local in_use=false
    if (( ${#running_vms[@]} > 0 )); then
      # Other VMs are running; check if any use this network.
      for _vm in "${running_vms[@]}"; do
        if virsh domiflist "$_vm" 2>/dev/null | awk 'NR>2 {print $3}' \
            | grep -qw "^${_net}$"; then
          in_use=true
          break
        fi
      done
    fi

    if [[ "$in_use" == "true" ]]; then
      echo "Network '${_net}' is still in use by other VMs; leaving it running."
    else
      echo "Stopping libvirt network '${_net}'..."
      virsh net-destroy "${_net}" 2>/dev/null || true
    fi
  done
}

cmd_destroy() {
  if ! virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "VM '$VM_NAME' does not exist."
    return
  fi
  teardown_vm
  echo "VM '$VM_NAME' destroyed."

  # Print paths of any loop images that were preserved
  for shared_folder in "${SHARED_FOLDERS[@]+"${SHARED_FOLDERS[@]}"}"; do
    local host_path
    host_path=$(shared_folder_host_path "$shared_folder")
    local img_path="${host_path%/}.img"
    if [[ -f "$img_path" ]]; then
      echo "Shared folder image preserved at: $img_path"
      echo "  To delete it: rm '$img_path'"
    fi
  done
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
  if virsh dominfo "$VM_NAME" &>/dev/null; then
    while IFS= read -r mac; do
      [[ -n "$mac" ]] && macs+=("$mac")
    done < <(virsh domiflist "$VM_NAME" 2>/dev/null | awk 'NR>2 && $5 ~ /^([0-9a-f]{2}:){5}/ { print $5 }')
  else
    echo "Warning: VM '$VM_NAME' domain not found; MAC addresses cannot be preserved." >&2
    echo "  Network may not work after reset. Run 'migrant.sh destroy && migrant.sh up' instead." >&2
  fi

  teardown_vm keep_snapshot
  echo "VM '$VM_NAME' wiped. Rebuilding..."
  _MIGRANT_RESET_MACS="${macs[*]:-}" cmd_up
}

vm_has_ssh() {
  grep -q 'ssh_authorized_keys' "$CLOUD_INIT_FILE"
}

# Print the key material (base64 field) of the first key in cloud-init.yml
# whose comment is "migrant". Prints nothing if no such key is present.
cloud_init_managed_key_material() {
  grep -E '^\s*-?\s*(ssh|ecdsa|sk)-' "$CLOUD_INIT_FILE" \
    | awk '$NF == "migrant" { print $(NF-1); exit }'
}

# Verify the host-side managed key matches what is in cloud-init.yml.
# Exits with an error if there is a mismatch. $1 is the context:
#   create — first-time VM creation (cloud-init will install the key)
#   reset  — rebuild from snapshot (key is baked into the snapshot)
#   start  — starting a stopped VM (key is already installed)
check_managed_key_match() {
  local context="$1"
  local ci_material
  ci_material=$(cloud_init_managed_key_material)
  [[ -z "$ci_material" ]] && return 0

  if [[ ! -f "$MANAGED_KEY_PATH" ]]; then
    echo "Error: cloud-init.yml contains a managed SSH key (comment: 'migrant')" >&2
    echo "  but ~/.ssh/migrant was not found on this host." >&2
    if [[ "$context" == "create" ]]; then
      echo "  Run 'migrant.sh pubkey' to generate the key, update cloud-init.yml," >&2
      echo "  then re-run 'migrant.sh up'." >&2
    else
      echo "  Restore ~/.ssh/migrant, or update cloud-init.yml with a new key" >&2
      echo "  (via 'migrant.sh pubkey') and run 'migrant.sh destroy && migrant.sh up'." >&2
    fi
    exit 66
  fi

  if [[ ! -f "${MANAGED_KEY_PATH}.pub" ]]; then
    echo "Error: ~/.ssh/migrant.pub not found. Re-run 'ssh-keygen' to regenerate the pair." >&2
    exit 66
  fi

  local host_material
  host_material=$(awk '{print $2}' "${MANAGED_KEY_PATH}.pub")

  if [[ "$ci_material" != "$host_material" ]]; then
    echo "Error: the managed key in cloud-init.yml does not match ~/.ssh/migrant.pub." >&2
    echo "  Update cloud-init.yml with the output of 'migrant.sh pubkey'," >&2
    if [[ "$context" == "create" ]]; then
      echo "  then re-run 'migrant.sh up'." >&2
    else
      echo "  then run 'migrant.sh destroy && migrant.sh up' to rebuild." >&2
    fi
    exit 78
  fi
}

get_ssh_user() {
  local user
  user=$(awk '/^users:/{f=1} f && /- name:/{print $NF; exit}' "$CLOUD_INIT_FILE")
  if [[ -z "$user" ]]; then
    echo "Error: could not determine username from cloud-init.yml." >&2
    exit 78
  fi
  echo "$user"
}

# Populate the named array variable with SSH client options.
# If cloud-init.yml contains a key with comment "migrant", the managed key
# at ~/.ssh/migrant is used exclusively. Otherwise SSH uses whatever keys
# are available in the agent or default identity files.
# Usage: build_ssh_opts ARRAY_NAME
build_ssh_opts() {
  # shellcheck disable=SC2178
  local -n _opts=$1
  # LogLevel=ERROR suppresses the "Permanently added ... to known hosts" warning
  # that SSH emits when UserKnownHostsFile=/dev/null absorbs the ephemeral key.
  _opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

  local managed_material
  managed_material=$(cloud_init_managed_key_material)

  if [[ -n "$managed_material" ]]; then
    if [[ ! -f "$MANAGED_KEY_PATH" ]]; then
      echo "Error: cloud-init.yml references a managed SSH key but ~/.ssh/migrant not found." >&2
      echo "  Restore the key file, or update cloud-init.yml and rebuild with" >&2
      echo "  'migrant.sh destroy && migrant.sh up'." >&2
      exit 66
    fi
    if [[ ! -f "${MANAGED_KEY_PATH}.pub" ]]; then
      echo "Error: ~/.ssh/migrant.pub not found. Re-run 'ssh-keygen' to regenerate the pair." >&2
      exit 66
    fi
    local host_material
    host_material=$(awk '{print $2}' "${MANAGED_KEY_PATH}.pub")
    if [[ "$managed_material" != "$host_material" ]]; then
      echo "Error: the managed key in cloud-init.yml does not match ~/.ssh/migrant.pub." >&2
      echo "  Update cloud-init.yml with 'migrant.sh pubkey' and rebuild with" >&2
      echo "  'migrant.sh destroy && migrant.sh up'." >&2
      exit 78
    fi
    _opts+=(-i "$MANAGED_KEY_PATH" -o IdentitiesOnly=yes)
  else
    if ! vm_has_ssh; then
      echo "Error: no ssh_authorized_keys found in cloud-init.yml." >&2
      echo "  Add your public key and rebuild with 'migrant.sh destroy && migrant.sh up'." >&2
      exit 78
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
  fi
}

cmd_pubkey() {
  ensure_managed_key
  cat "${MANAGED_KEY_PATH}.pub"
}

cmd_console() {
  require_running
  virsh console "$VM_NAME"
}

# Called at the end of cmd_up to connect to the VM when AUTOCONNECT is set.
# For AUTOCONNECT=ssh, waits for SSH if not already ready, then connects.
# For AUTOCONNECT=console, attaches the serial console immediately.
do_autoconnect() {
  case "${AUTOCONNECT:-}" in
    ssh)
      if ! vm_has_ssh; then
        echo "Note: AUTOCONNECT=ssh is set but no ssh_authorized_keys found in cloud-init.yml — skipping autoconnect." >&2
        return
      fi
      local user ssh_opts ip
      resolve_ssh_conn user ssh_opts ip
      wait_for_ssh "$user" "$ip" "${ssh_opts[@]}"
      # SC2029: user@ip intentionally expands on the client side.
      # shellcheck disable=SC2029
      ssh "${ssh_opts[@]}" "${user}@${ip}"
      ;;
    console)
      echo "Attaching console (exit with Ctrl+])..." >&2
      virsh console "$VM_NAME"
      ;;
  esac
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
    exit 127
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
  if [[ -n "$(cloud_init_managed_key_material)" ]]; then
    ansible_args+=(--private-key "$MANAGED_KEY_PATH")
  fi

  echo "Running Ansible playbook..." >&2
  if ANSIBLE_HOST_KEY_CHECKING=false ansible-playbook "${ansible_args[@]}" "$playbook"; then
    echo "Ansible provisioning complete." >&2
  else
    echo "" >&2
    echo "Error: Ansible provisioning failed. The VM is still running." >&2
    echo "  Fix playbook.yml and run 'migrant.sh provision' to retry." >&2
    exit 70
  fi
}

cmd_mount() {
  if [[ -z "${SHARED_FOLDERS[*]+"${SHARED_FOLDERS[*]}"}" ]]; then
    echo "No shared folders configured in Migrantfile."
    return
  fi

  if ! shared_folder_isolation_enabled; then
    echo "SHARED_FOLDER_ISOLATION=false — shared folders are plain directories; nothing to mount."
    return
  fi

  ensure_shared_folder_images

  local vm_running=false
  if virsh dominfo "$VM_NAME" &>/dev/null \
      && [[ "$(virsh domstate "$VM_NAME")" == "running" ]]; then
    vm_running=true
  fi

  for shared_folder in "${SHARED_FOLDERS[@]}"; do
    local host_path
    host_path=$(shared_folder_host_path "$shared_folder")
    local img_path="${host_path%/}.img"

    if mountpoint -q "$host_path" 2>/dev/null; then
      if $vm_running; then
        echo "$host_path: mounted (VM is running — host and guest share access)."
      else
        echo "$host_path: already mounted."
      fi
      continue
    fi

    # Image is not mounted. Refuse if VM is running — mounting under an active
    # virtiofsd session is unsafe and indicates something went wrong.
    if $vm_running; then
      echo "Error: VM '$VM_NAME' is running but $host_path is not mounted." >&2
      echo "  The QEMU hook should have mounted it. Check the hook is installed" >&2
      echo "  by re-running 'migrant.sh setup', then halt and restart the VM." >&2
      exit 1
    fi

    mkdir -p "$host_path"
    echo "Mounting $img_path at $host_path (requires sudo)..."
    sudo mount -o loop,nosymfollow "$img_path" "$host_path"
    echo "  Mounted. Unmount with 'migrant.sh unmount' when done."
  done
}

cmd_unmount() {
  if [[ -z "${SHARED_FOLDERS[*]+"${SHARED_FOLDERS[*]}"}" ]]; then
    echo "No shared folders configured in Migrantfile."
    return
  fi

  if ! shared_folder_isolation_enabled; then
    echo "SHARED_FOLDER_ISOLATION=false — shared folders are plain directories; nothing to unmount."
    return
  fi

  # Refuse if VM is running — unmounting would break virtiofsd.
  if virsh dominfo "$VM_NAME" &>/dev/null \
      && [[ "$(virsh domstate "$VM_NAME")" == "running" ]]; then
    echo "Error: VM '$VM_NAME' is running." >&2
    echo "  Halt the VM with 'migrant.sh halt' before unmounting." >&2
    exit 1
  fi

  for shared_folder in "${SHARED_FOLDERS[@]}"; do
    local host_path
    host_path=$(shared_folder_host_path "$shared_folder")

    if mountpoint -q "$host_path" 2>/dev/null; then
      echo "Unmounting $host_path (requires sudo)..."
      sudo umount "$host_path"
    else
      echo "$host_path: not mounted."
    fi
  done
}

cmd_status() {
  local state=""

  if ! virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "VM '$VM_NAME' has not been created. Run 'migrant.sh up' to create it."
  else
    state=$(virsh domstate "$VM_NAME")

    case "$state" in
      running)
        local ip
        ip=$(get_vm_ip)
        if [[ -n "$ip" ]]; then
          echo "VM '$VM_NAME' is running at $ip."
        else
          echo "VM '$VM_NAME' is running (no IP yet)."
        fi
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

  if shared_folder_isolation_enabled && [[ -n "${SHARED_FOLDERS[*]+"${SHARED_FOLDERS[*]}"}" ]]; then
    for shared_folder in "${SHARED_FOLDERS[@]}"; do
      local host_path
      host_path=$(shared_folder_host_path "$shared_folder")
      local img_path="${host_path%/}.img"
      [[ -f "$img_path" ]] || continue
      if mountpoint -q "$host_path" 2>/dev/null; then
        echo "Loop image: $img_path (mounted at $host_path)"
      else
        echo "Loop image: $img_path (not mounted)"
      fi
    done
  fi

  local wg_iface wg_table wg_table_hex
  wg_iface_and_table "$VM_NAME"
  wg_table_hex=$(printf '%x' "$wg_table")

  if [[ -f "/etc/migrant/${VM_NAME}/wireguard.conf" ]]; then
    local wg_endpoint wg_dns
    wg_endpoint=$(cat "/etc/migrant/${VM_NAME}/wireguard-endpoint")
    wg_dns=$(cat "/etc/migrant/${VM_NAME}/wireguard-dns" 2>/dev/null || true)

    if ip link show "$wg_iface" &>/dev/null \
        && ip rule show | grep -q "fwmark 0x${wg_table_hex}"; then
      if [[ -f "/run/migrant/${VM_NAME}.wgbadkey" ]]; then
        echo "Tunnel:   WARNING — interface up but PrivateKey is invalid (no internet)"
      else
        echo "Tunnel:   active — $wg_iface → $wg_endpoint"
      fi
    elif [[ "$state" == "running" ]]; then
      echo "Tunnel:   ERROR — configured but traffic is NOT tunneled"
    else
      echo "Tunnel:   $wg_endpoint (configured, inactive while VM is stopped)"
    fi

    if [[ -n "$wg_dns" ]]; then
      echo "DNS:      $wg_dns (through tunnel)"
    else
      echo "DNS:      host"
    fi
  else
    echo "Tunnel:   none"
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

  # Base images: .img or .qcow2 files (downloaded cloud images) not belonging to a VM
  local base_images=()
  for f in "${all_files[@]+"${all_files[@]}"}"; do
    [[ -n "${categorized[$f]:-}" ]] && continue
    if [[ "$f" == *.img || "$f" == *.qcow2 ]]; then
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
  mount)        require_config; cmd_mount ;;
  unmount)      require_config; cmd_unmount ;;
  snapshot)     require_config; cmd_snapshot ;;
  reset)        require_config; cmd_reset ;;
  provision)    require_config; cmd_provision ;;
  storage)      cmd_storage ;;
  -h|--help|help) usage 0 ;;
  *)              usage ;;
esac
