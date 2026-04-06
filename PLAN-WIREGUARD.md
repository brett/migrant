# WireGuard VPN Integration Plan

## Overview

Route all outbound internet traffic from a migrant.sh-managed VM through a
Mullvad WireGuard VPN tunnel on the host. The tunnel is entirely host-side and
opaque to the VM — a potentially malicious or compromised agent inside the VM
cannot detect, disable, or bypass it.

The feature is activated by placing a `wireguard.conf` file (a standard Mullvad
WireGuard config) in the VM directory alongside the `Migrantfile`. No new
`Migrantfile` variable is introduced. This follows the same convention as
`playbook.yml`: presence of the file enables the feature; absence disables it.
The change takes effect on the next `halt` + `up` cycle. Destroy and recreate
are not required.

If `wireguard-tools` (`wg`) is not installed on the host, migrant.sh behaves as
if no `wireguard.conf` is present — the VM starts normally, a warning is printed
by `migrant.sh up`, and no VPN is configured.

---

## Why copy to `/etc/migrant/<vm-name>/`

`migrant.sh up` copies `wireguard.conf` from the VM directory to
`/etc/migrant/<vm-name>/wireguard.conf` before starting the VM. The qemu hook
reads it from that fixed location. This is necessary for three reasons:

**1. The qemu hook has no knowledge of user directory structure.**
The hook receives only the VM name (`$1`) and operation (`$2`) from libvirt.
It has no access to `$VM_DIR`, `$HOME`, or any context from the migrant.sh
session that created the VM. A path like `~/workspace/claude/wireguard.conf`
cannot be resolved from the hook. `/etc/migrant/<vm-name>/wireguard.conf` is
always unambiguous.

**2. Privilege and confidentiality.**
The config file contains a WireGuard private key. `/etc/migrant/` is created
with mode `700 root:root`, making the private key inaccessible to non-root
users on the host while remaining readable by the hook (which runs as root).
The source file in the VM directory may be in a world-readable location.

**3. Stability across source moves.**
Once a VM is running, the user should be free to rename, move, or delete the
source config without breaking the running VM or leaving the hook in an
inconsistent state. The managed copy is the authoritative version for that
VM's lifetime.

**Lifecycle:** `migrant.sh up` always syncs the managed copy before starting
the VM — copying if the source exists, deleting the managed copy if it does not.
This means the WireGuard config is always exactly what the VM directory says it
should be, evaluated at start time. Changes to `wireguard.conf` take effect on
the next `halt` + `up`.

---

## WireGuard interface naming

Since all VM directories use the same filename (`wireguard.conf`), the interface
name must be derived from the VM name rather than the config filename. A 7-char
hex hash of the VM name gives a stable, unique, and length-safe name:

```bash
WG_IFACE="wg-$(printf '%s' "$VM_NAME" | md5sum | head -c7)"
# e.g. VM_NAME=claude → WG_IFACE=wg-a3f9c12  (10 chars, well under 15)
```

Each VM gets exactly one WireGuard interface. No reference counting or interface
sharing between VMs is required.

---

## Routing design

### fwmark-based per-tap routing

Rather than routing by source subnet (all VMs share `192.168.200.0/24`), we
route by which **tap interface** a packet arrived on. This is the same interface
that the existing NETWORK_ISOLATION hook already identifies and stores in
`/run/migrant/<vm-name>.iface`.

In the mangle PREROUTING chain, packets arriving from the VM's tap are marked
with a fwmark value equal to the routing table ID (see below). A policy rule
then routes all marked packets via the WireGuard-specific routing table:

```bash
iptables -t mangle -A PREROUTING -i "$iface" -j MARK --set-mark "$WG_TABLE"
ip rule add fwmark "$WG_TABLE" lookup "$WG_TABLE" priority 100
```

### Routing table ID

Policy routing tables require integer IDs. The ID is derived from the interface
name, placing it in the range 10000–19999 (well clear of reserved values and
common tool ranges):

```bash
WG_TABLE=$(( 10000 + ( 16#$(printf '%s' "$WG_IFACE" | md5sum | head -c4) % 10000 ) ))
```

The table contains two entries:

```bash
# 1. Endpoint exclusion: the Mullvad server's IP must reach the host's real
#    default gateway, not wg-iface (which would create an infinite loop).
#    Capture the real gateway before bringing up the WireGuard interface.
via_info=$(ip route get "$WG_ENDPOINT_IP")
via_gw=$(awk 'NR==1{for(i=1;i<NF;i++) if ($i=="via"){print $(i+1); exit}}' <<< "$via_info")
via_dev=$(awk 'NR==1{for(i=1;i<NF;i++) if ($i=="dev"){print $(i+1); exit}}' <<< "$via_info")

if [[ -n "$via_gw" ]]; then
  ip route add "${WG_ENDPOINT_IP}/32" via "$via_gw" dev "$via_dev" table "$WG_TABLE"
else
  # Endpoint is on a directly connected network (no gateway hop)
  ip route add "${WG_ENDPOINT_IP}/32" dev "$via_dev" table "$WG_TABLE"
fi

# 2. Default: all other traffic exits via the WireGuard interface
ip route add default dev "$WG_IFACE" table "$WG_TABLE"
```

### Why SSH from the host is unaffected

When the host connects to the VM via SSH, the connection is initiated by the
host and the TCP session is established over the `virbr-migrant` bridge
(192.168.200.0/24). Replies from the VM arrive on the host at the tap interface,
are marked by the mangle PREROUTING rule, and are then subject to policy routing.

However, the destination of a reply is `192.168.200.1` — the host's own bridge
IP. Linux's local routing table (table 255, priority 0) is evaluated before any
user-defined rule. It always contains a local route for `192.168.200.1`. The
policy rule at priority 100 is never reached for traffic destined to the host
itself. SSH from the host to the VM works correctly with the tunnel active.

---

## WireGuard interface management

`wg-quick` is not used. It processes `DNS`, `Table`, and `PostUp`/`PostDown`
directives and applies them to the host system — modifying `/etc/resolv.conf`,
routing tables, and running arbitrary scripts. Instead, the hook brings up the
interface using the lower-level `wg` and `ip` commands directly, which gives
full control and no host side effects.

The managed conf is parsed manually:

```bash
wg_conf="/etc/migrant/${VM_NAME}/wireguard.conf"

# Address may be comma-separated (IPv4 + IPv6)
WG_ADDRS=$(awk -F= '/^\s*Address\s*=/{gsub(/ /, "", $2); print $2}' "$wg_conf")
WG_ENDPOINT_IP=$(awk -F= '/^\s*Endpoint\s*=/{gsub(/ /, "", $2); print $2}' \
  "$wg_conf" | cut -d: -f1)
```

Interface bring-up:

```bash
ip link add "$WG_IFACE" type wireguard

# Apply crypto config. The DNS line is stripped: we resolve the DNS field
# ourselves (see below). We do not want wg or wg-quick to touch host DNS.
local wg_tmp
wg_tmp=$(mktemp)
trap 'rm -f "$wg_tmp"' RETURN
grep -v '^\s*DNS\s*=' "$wg_conf" > "$wg_tmp"
wg setconf "$WG_IFACE" "$wg_tmp"

# Assign addresses
IFS=',' read -ra addr_list <<< "$WG_ADDRS"
for addr in "${addr_list[@]}"; do
  addr="${addr// /}"
  [[ -n "$addr" ]] && ip addr add "$addr" dev "$WG_IFACE"
done

ip link set "$WG_IFACE" up
```

---

## DNS handling

If the Mullvad config contains a `DNS` line (e.g. `DNS = 10.64.0.1`), the hook
parses the value and stores it in `/run/migrant/<vm-name>.wgdns` for use at
teardown time. When `NETWORK_ISOLATION=true` is also set, the RFC1918 FORWARD
REJECT rules would otherwise block the VM from reaching `10.64.0.1` — even
though the traffic travels inside the WireGuard tunnel. A targeted FORWARD
ACCEPT rule is inserted before the REJECT rules for each DNS IP:

```bash
WG_DNS=$(awk -F= '/^\s*DNS\s*=/{gsub(/ /, "", $2); print $2}' "$wg_conf")

if [[ -n "$WG_DNS" ]]; then
  printf '%s' "$WG_DNS" > "/run/migrant/${VM_NAME}.wgdns"
  IFS=',' read -ra dns_list <<< "$WG_DNS"
  for dns_ip in "${dns_list[@]}"; do
    dns_ip="${dns_ip// /}"
    [[ -z "$dns_ip" ]] && continue
    # -I inserts at position 1 (head of chain), before the RFC1918 REJECTs
    iptables -I FORWARD -i "$iface" -d "${dns_ip}/32" -j ACCEPT
  done
fi
```

The condition is only relevant when `NETWORK_ISOLATION=true`. Without it, there
are no RFC1918 blocks to punch through. The ACCEPT rules are harmless either way.

If `wireguard.conf` has no `DNS` line, the VM uses the host's resolver via
libvirt's DHCP (`192.168.200.1`). DNS queries are resolved by the host and are
not routed through the VPN. This is an acceptable trade-off; users who want
full DNS isolation through the VPN should include a `DNS` line in their config.

---

## Fail-closed behaviour on tunnel drop

If the WireGuard tunnel goes down mid-session (e.g. the Mullvad server becomes
unreachable, or the session times out), the host-side routing state is unchanged:

- The `wg-XXXXXXX` interface still exists as a kernel network interface
- The routing table still has `default dev wg-XXXXXXX`
- The fwmark rule still redirects VM traffic to that table

Traffic from the VM is delivered to the WireGuard interface, which attempts to
encrypt and forward it to the peer. With no active session, WireGuard silently
drops the packets. From the VM's perspective, internet access stops working.

**The VM cannot break out of this.** The routing rules are enforced in the host
kernel. There is no fallback route available to the VM. The only internet path
is through the WireGuard interface.

SSH from the host continues to work (see routing section above). The VM remains
accessible and manageable. The tunnel will resume forwarding traffic if the peer
becomes reachable again (WireGuard is stateless and reconnects automatically).

To reduce the likelihood of silent drops on idle sessions, users may add
`PersistentKeepalive = 25` to the `[Peer]` section of `wireguard.conf`. This
is a standard Mullvad recommendation for NAT traversal.

---

## Changes to `cmd_up`

Before starting the VM (in both the "existing stopped VM" and "new VM" paths),
sync the managed config:

```bash
# Sync WireGuard config to managed location
local wg_src="$VM_DIR/wireguard.conf"
local wg_managed="/etc/migrant/${VM_NAME}/wireguard.conf"

if [[ -f "$wg_src" ]]; then
  if ! command -v wg &>/dev/null; then
    echo "Warning: wireguard.conf found but 'wg' (wireguard-tools) is not installed." >&2
    echo "  WireGuard tunnel will not be configured for '$VM_NAME'." >&2
    echo "  Install wireguard-tools and re-run 'migrant.sh up' to enable it." >&2
  else
    sudo mkdir -p "/etc/migrant/${VM_NAME}"
    sudo chmod 700 "/etc/migrant/${VM_NAME}"
    sudo cp "$wg_src" "$wg_managed"
    sudo chmod 600 "$wg_managed"
  fi
else
  # Source absent: remove stale managed copy so the hook does not use it
  sudo rm -f "$wg_managed" 2>/dev/null || true
fi
```

This block runs unconditionally on every `up`, including when the VM is already
running. If the VM is running, nothing changes at runtime; the fresh copy takes
effect on the next start.

---

## Changes to the qemu hook

The qemu hook (installed by `cmd_setup` to `/etc/libvirt/hooks/qemu.d/migrant`)
gains two new functions: `wg_setup` and `wg_teardown`. They are called from
within the existing `apply_rules` and `remove_rules` functions.

### `wg_setup` (called from `apply_rules` on VM start)

```bash
wg_setup() {
  local vm="$1" iface="$2"
  local wg_conf="/etc/migrant/${vm}/wireguard.conf"
  [[ -f "$wg_conf" ]] || return 0
  command -v wg &>/dev/null || return 0

  local WG_IFACE="wg-$(printf '%s' "$vm" | md5sum | head -c7)"
  local WG_TABLE
  WG_TABLE=$(( 10000 + ( 16#$(printf '%s' "$WG_IFACE" | md5sum | head -c4) % 10000 ) ))

  local WG_ADDRS WG_ENDPOINT_IP
  WG_ADDRS=$(awk -F= '/^\s*Address\s*=/{gsub(/ /,"",$2); print $2}' "$wg_conf")
  WG_ENDPOINT_IP=$(awk -F= '/^\s*Endpoint\s*=/{gsub(/ /,"",$2); print $2}' \
    "$wg_conf" | cut -d: -f1)

  # Capture real gateway to the endpoint BEFORE altering routing
  local via_info via_gw via_dev
  via_info=$(ip route get "$WG_ENDPOINT_IP" 2>/dev/null) || {
    echo "migrant: wg_setup: cannot route to endpoint $WG_ENDPOINT_IP" >&2
    return 1
  }
  via_gw=$(awk 'NR==1{for(i=1;i<NF;i++) if($i=="via"){print $(i+1);exit}}' \
    <<< "$via_info")
  via_dev=$(awk 'NR==1{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1);exit}}' \
    <<< "$via_info")

  # Create WireGuard interface
  ip link add "$WG_IFACE" type wireguard

  local wg_tmp
  wg_tmp=$(mktemp)
  grep -v '^\s*DNS\s*=' "$wg_conf" > "$wg_tmp"
  wg setconf "$WG_IFACE" "$wg_tmp"
  rm -f "$wg_tmp"

  IFS=',' read -ra addr_list <<< "$WG_ADDRS"
  for addr in "${addr_list[@]}"; do
    addr="${addr// /}"
    [[ -n "$addr" ]] && ip addr add "$addr" dev "$WG_IFACE"
  done
  ip link set "$WG_IFACE" up

  # Build routing table
  if [[ -n "$via_gw" ]]; then
    ip route add "${WG_ENDPOINT_IP}/32" via "$via_gw" dev "$via_dev" table "$WG_TABLE"
  else
    ip route add "${WG_ENDPOINT_IP}/32" dev "$via_dev" table "$WG_TABLE"
  fi
  ip route add default dev "$WG_IFACE" table "$WG_TABLE"

  # Mark packets from this VM's tap and route them via the WireGuard table
  iptables -t mangle -A PREROUTING -i "$iface" -j MARK --set-mark "$WG_TABLE"
  ip rule add fwmark "$WG_TABLE" lookup "$WG_TABLE" priority 100

  # DNS FORWARD exceptions (must come after NETWORK_ISOLATION inserts its REJECTs
  # so that -I places these ACCEPTs before the REJECTs in the chain)
  local WG_DNS
  WG_DNS=$(awk -F= '/^\s*DNS\s*=/{gsub(/ /,"",$2); print $2}' "$wg_conf")
  if [[ -n "$WG_DNS" ]]; then
    printf '%s' "$WG_DNS" > "/run/migrant/${vm}.wgdns"
    IFS=',' read -ra dns_list <<< "$WG_DNS"
    for dns_ip in "${dns_list[@]}"; do
      dns_ip="${dns_ip// /}"
      [[ -z "$dns_ip" ]] && continue
      iptables -I FORWARD -i "$iface" -d "${dns_ip}/32" -j ACCEPT
    done
  fi

  echo "migrant: WireGuard tunnel up: $WG_IFACE (table $WG_TABLE) for $vm" >&2
}
```

### `wg_teardown` (called from `remove_rules` on VM stop)

```bash
wg_teardown() {
  local vm="$1" iface="$2"

  local WG_IFACE="wg-$(printf '%s' "$vm" | md5sum | head -c7)"
  local WG_TABLE
  WG_TABLE=$(( 10000 + ( 16#$(printf '%s' "$WG_IFACE" | md5sum | head -c4) % 10000 ) ))

  # Remove mangle mark rule and policy routing rule
  iptables -t mangle -D PREROUTING -i "$iface" -j MARK \
    --set-mark "$WG_TABLE" 2>/dev/null || true
  ip rule del fwmark "$WG_TABLE" lookup "$WG_TABLE" 2>/dev/null || true
  ip route flush table "$WG_TABLE" 2>/dev/null || true

  # Remove DNS FORWARD ACCEPT rules
  if [[ -f "/run/migrant/${vm}.wgdns" ]]; then
    IFS=',' read -ra dns_list <<< "$(cat "/run/migrant/${vm}.wgdns")"
    for dns_ip in "${dns_list[@]}"; do
      dns_ip="${dns_ip// /}"
      [[ -z "$dns_ip" ]] && continue
      iptables -D FORWARD -i "$iface" -d "${dns_ip}/32" -j ACCEPT 2>/dev/null || true
    done
    rm -f "/run/migrant/${vm}.wgdns"
  fi

  # Bring down and delete the WireGuard interface
  ip link set "$WG_IFACE" down 2>/dev/null || true
  ip link del "$WG_IFACE" 2>/dev/null || true

  echo "migrant: WireGuard tunnel down: $WG_IFACE for $vm" >&2
}
```

### Integration into `apply_rules` / `remove_rules`

`wg_setup` is called at the end of `apply_rules`, after the NETWORK_ISOLATION
REJECT rules have been inserted. This ordering is required: the DNS ACCEPT rules
inserted by `wg_setup` use `-I FORWARD` (insert at head), so they land before
the REJECT rules only if the REJECTs are already in the chain.

`wg_teardown` is called from `remove_rules`. Detection uses the WireGuard
interface name rather than the presence of the conf file (the conf may have been
removed since the VM started):

```bash
remove_rules() {
  local vm="$1"
  local iface
  iface=$(cat "/run/migrant/${vm}.iface" 2>/dev/null) || return 0
  [[ -z "$iface" ]] && return 0

  # ... existing NETWORK_ISOLATION cleanup ...

  # WireGuard teardown: check if the interface exists, not the conf file
  local WG_IFACE="wg-$(printf '%s' "$vm" | md5sum | head -c7)"
  if ip link show "$WG_IFACE" &>/dev/null \
      || [[ -f "/run/migrant/${vm}.wgdns" ]]; then
    wg_teardown "$vm" "$iface"
  fi

  rm -f "/run/migrant/${vm}.iface"
}
```

---

## Changes to `teardown_vm` / `cmd_destroy`

Remove the managed config directory when a VM is destroyed:

```bash
sudo rm -rf "/etc/migrant/${VM_NAME}"
```

This should run after `virsh undefine` in `teardown_vm`, so stale configs do
not accumulate in `/etc/migrant/` for long-deleted VMs.

---

## `cmd_setup`

No new sections are needed. The qemu hook is content-checked with `cmp` on
every `setup` run. Adding WireGuard logic to the hook body will cause `cmp` to
fail, triggering the existing "hook is outdated, reinstalling" path. Users must
re-run `migrant.sh setup` after the update, as they would for any hook change.

The `wireguard-tools` prerequisite is intentionally not checked here. `setup`
configures host infrastructure; WireGuard is an optional per-VM feature. The
warning in `cmd_up` is the appropriate place.

---

## `.gitignore` and README

**`.gitignore`:** Add `*/wireguard.conf` to prevent accidental commits of
WireGuard private keys from any of the three example VM directories.

**`README.md`:** Add a warning alongside the existing loop image note:

> Add `*/wireguard.conf` to `.gitignore` to avoid committing WireGuard private
> keys to source control if your VM directory is in a git repository.

---

## Summary of file changes

| File                                  | Change                                          |
| ------------------------------------- | ----------------------------------------------- |
| `migrant.sh` — `cmd_up`              | Sync `wireguard.conf` to `/etc/migrant/<name>/` |
| `migrant.sh` — `teardown_vm`         | `rm -rf /etc/migrant/<name>/`                   |
| `migrant.sh` — qemu hook body        | Add `wg_setup` + `wg_teardown` functions        |
| `migrant.sh` — qemu hook `apply_rules` | Call `wg_setup` after NETWORK_ISOLATION rules  |
| `migrant.sh` — qemu hook `remove_rules` | Call `wg_teardown` if WG iface exists         |
| `.gitignore`                          | Add `*/wireguard.conf`                          |
| `README.md`                           | Add private key gitignore warning               |
