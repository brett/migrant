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

If `wireguard.conf` is present but `wireguard-tools` (`wg`) is not installed on
the host, `migrant.sh up` prints an error and refuses to start the VM. A warning
is easily missed; the user must not be left believing traffic is tunneled when
it is not.

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

### Config sync

Before starting the VM (in both the "existing stopped VM" and "new VM" paths),
sync the managed config. If `wireguard.conf` is present but `wg` is not
installed, exit immediately with an error rather than continuing without VPN:

```bash
# Sync WireGuard config to managed location
local wg_src="$VM_DIR/wireguard.conf"
local wg_managed="/etc/migrant/${VM_NAME}/wireguard.conf"

if [[ -f "$wg_src" ]]; then
  if ! command -v wg &>/dev/null; then
    echo "Error: wireguard.conf is present but 'wg' (wireguard-tools) is not installed." >&2
    echo "  Install wireguard-tools or remove wireguard.conf to start without a VPN." >&2
    exit 69  # EX_UNAVAILABLE
  fi
  sudo mkdir -p "/etc/migrant/${VM_NAME}"
  sudo chmod 700 "/etc/migrant/${VM_NAME}"
  sudo cp "$wg_src" "$wg_managed"
  sudo chmod 600 "$wg_managed"
else
  # Source absent: remove stale managed copy so the hook does not use it
  sudo rm -f "$wg_managed" 2>/dev/null || true
fi
```

This block runs unconditionally on every `up`, including when the VM is already
running. If the VM is running, nothing changes at runtime; the fresh copy takes
effect on the next start.

### Post-start tunnel verification

After the VM is started, `cmd_up` verifies that both phases of WireGuard setup
completed successfully. This is called immediately after `virsh start` (or
`virt-install`) in every code path, including the `AUTOCONNECT=console` early
return, before the user is handed control.

The `prepare` hook (synchronous, see below) will have already caused `virsh
start` to fail if the WireGuard interface could not be created. The
post-start check covers the `started` hook's iptables work, which is async.

```bash
verify_wireguard_tunnel() {
  # No-op if WireGuard is not configured for this VM
  [[ -f "/etc/migrant/${VM_NAME}/wireguard.conf" ]] || return 0

  local wg_iface="wg-$(printf '%s' "$VM_NAME" | md5sum | head -c7)"
  local wg_table
  wg_table=$(( 10000 + ( 16#$(printf '%s' "$wg_iface" | md5sum | head -c4) % 10000 ) ))
  local wg_table_hex
  wg_table_hex=$(printf '%x' "$wg_table")

  # Interface check: should have been created synchronously in the prepare hook.
  # If this fails, it means prepare somehow ran but the interface isn't visible,
  # which indicates a kernel-level problem.
  if ! ip link show "$wg_iface" &>/dev/null; then
    echo "Error: WireGuard interface $wg_iface is missing after VM start." >&2
    echo "  Traffic is NOT tunneled. Halting VM." >&2
    virsh destroy "$VM_NAME" 2>/dev/null || true
    exit 70  # EX_SOFTWARE
  fi

  # fwmark rule check: the started hook is async; poll briefly for it.
  # In practice the hook completes within milliseconds of virsh start returning,
  # but we allow up to 10 seconds to be safe.
  local deadline=$(( $(date +%s) + 10 ))
  while (( $(date +%s) < deadline )); do
    ip rule show | grep -q "fwmark 0x${wg_table_hex}" && break
    sleep 0.2
  done

  if ! ip rule show | grep -q "fwmark 0x${wg_table_hex}"; then
    echo "Error: WireGuard routing rules for $wg_iface were not applied." >&2
    echo "  Traffic is NOT tunneled. Halting VM." >&2
    virsh destroy "$VM_NAME" 2>/dev/null || true
    exit 70  # EX_SOFTWARE
  fi

  echo "WireGuard tunnel active: $wg_iface (table $wg_table)." >&2
}
```

`virsh destroy` (forced immediate shutdown) is used rather than `virsh
shutdown` (graceful) because the agent inside the VM must not be given time to
act on its window of unprotected connectivity.

---

## Changes to the qemu hook

### Why the hook is split across `prepare` and `started`

Libvirt fires two relevant operations on the qemu hook:

- **`prepare`** fires synchronously before the QEMU process starts. If the hook
  exits non-zero, libvirt aborts the VM start entirely, and `virsh start`
  returns a non-zero exit code. This gives us guaranteed, synchronous failure
  detection.

- **`started`** fires asynchronously after the QEMU process is running. Libvirt
  does not wait for it and does not propagate its exit code to `virsh start`.

The tap interface (e.g. `vnet0`) does not exist in `prepare` — it is created by
QEMU during startup, after `prepare` completes. This divides the WireGuard work
naturally:

| Phase     | Operation         | What can be done                        | Failure mode              |
| --------- | ----------------- | --------------------------------------- | ------------------------- |
| `prepare` | `wg_setup_iface`  | Create WG interface, assign addr, routing table | Aborts VM start  |
| `started` | `wg_setup_rules`  | fwmark mangle rule, DNS FORWARD ACCEPTs | Async; caught by `cmd_up` |
| `release` | `wg_teardown`     | Remove all of the above                 | —                         |

The existing `apply_rules` (NETWORK_ISOLATION iptables) and `remove_rules`
functions stay on `started`/`release` as before. `wg_setup_iface` is added as
a new `prepare` branch in the hook's `case` statement.

### `wg_setup_iface` (called on `prepare` — synchronous)

A non-zero exit here aborts the VM start. Any failure to create the interface or
configure the routing table is immediately visible to `cmd_up` as a failed
`virsh start`.

```bash
wg_setup_iface() {
  local vm="$1"
  local wg_conf="/etc/migrant/${vm}/wireguard.conf"
  [[ -f "$wg_conf" ]] || return 0

  # wg absence was already caught by cmd_up before virsh start was called,
  # but check defensively in case the hook fires via another path.
  command -v wg &>/dev/null || {
    echo "migrant: wg_setup_iface: 'wg' not found; cannot set up tunnel for $vm" >&2
    return 1
  }

  local WG_IFACE="wg-$(printf '%s' "$vm" | md5sum | head -c7)"
  local WG_TABLE
  WG_TABLE=$(( 10000 + ( 16#$(printf '%s' "$WG_IFACE" | md5sum | head -c4) % 10000 ) ))

  local WG_ADDRS WG_ENDPOINT_IP
  WG_ADDRS=$(awk -F= '/^\s*Address\s*=/{gsub(/ /,"",$2); print $2}' "$wg_conf")
  WG_ENDPOINT_IP=$(awk -F= '/^\s*Endpoint\s*=/{gsub(/ /,"",$2); print $2}' \
    "$wg_conf" | cut -d: -f1)

  # Capture real gateway to the endpoint BEFORE touching routing.
  local via_info via_gw via_dev
  via_info=$(ip route get "$WG_ENDPOINT_IP" 2>/dev/null) || {
    echo "migrant: wg_setup_iface: no route to endpoint $WG_ENDPOINT_IP" >&2
    return 1
  }
  via_gw=$(awk 'NR==1{for(i=1;i<NF;i++) if($i=="via"){print $(i+1);exit}}' \
    <<< "$via_info")
  via_dev=$(awk 'NR==1{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1);exit}}' \
    <<< "$via_info")

  ip link add "$WG_IFACE" type wireguard

  local wg_tmp
  wg_tmp=$(mktemp)
  # Strip DNS: we parse it ourselves and must not let wg-quick touch host DNS.
  grep -v '^\s*DNS\s*=' "$wg_conf" > "$wg_tmp"
  wg setconf "$WG_IFACE" "$wg_tmp"
  rm -f "$wg_tmp"

  IFS=',' read -ra addr_list <<< "$WG_ADDRS"
  for addr in "${addr_list[@]}"; do
    addr="${addr// /}"
    [[ -n "$addr" ]] && ip addr add "$addr" dev "$WG_IFACE"
  done
  ip link set "$WG_IFACE" up

  # Routing table: endpoint via real gateway (loop prevention) + default via WG.
  if [[ -n "$via_gw" ]]; then
    ip route add "${WG_ENDPOINT_IP}/32" via "$via_gw" dev "$via_dev" table "$WG_TABLE"
  else
    ip route add "${WG_ENDPOINT_IP}/32" dev "$via_dev" table "$WG_TABLE"
  fi
  ip route add default dev "$WG_IFACE" table "$WG_TABLE"

  echo "migrant: WireGuard interface up: $WG_IFACE (table $WG_TABLE) for $vm" >&2
}
```

### `wg_setup_rules` (called from `apply_rules` on `started` — async)

This function requires the tap interface, which exists by the time `started`
fires. It is called at the end of `apply_rules`, after NETWORK_ISOLATION has
inserted its REJECT rules, so that the DNS ACCEPT rules (inserted with `-I` at
the head) end up before the REJECTs.

```bash
wg_setup_rules() {
  local vm="$1" iface="$2"
  local wg_conf="/etc/migrant/${vm}/wireguard.conf"
  [[ -f "$wg_conf" ]] || return 0

  local WG_IFACE="wg-$(printf '%s' "$vm" | md5sum | head -c7)"
  local WG_TABLE
  WG_TABLE=$(( 10000 + ( 16#$(printf '%s' "$WG_IFACE" | md5sum | head -c4) % 10000 ) ))

  # Mark all packets from this VM's tap; route them via the WireGuard table.
  iptables -t mangle -A PREROUTING -i "$iface" -j MARK --set-mark "$WG_TABLE"
  ip rule add fwmark "$WG_TABLE" lookup "$WG_TABLE" priority 100

  # DNS FORWARD exceptions.
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

  echo "migrant: WireGuard routing rules applied for $vm ($iface → $WG_IFACE)" >&2
}
```

### `wg_teardown` (called from `remove_rules` on `release`)

Teardown is detected by checking whether the WireGuard interface exists, not
whether the conf file is present (the conf may have been removed since the VM
started, but the interface and rules still need cleaning up).

```bash
wg_teardown() {
  local vm="$1" iface="$2"

  local WG_IFACE="wg-$(printf '%s' "$vm" | md5sum | head -c7)"
  local WG_TABLE
  WG_TABLE=$(( 10000 + ( 16#$(printf '%s' "$WG_IFACE" | md5sum | head -c4) % 10000 ) ))

  iptables -t mangle -D PREROUTING -i "$iface" -j MARK \
    --set-mark "$WG_TABLE" 2>/dev/null || true
  ip rule del fwmark "$WG_TABLE" lookup "$WG_TABLE" 2>/dev/null || true
  ip route flush table "$WG_TABLE" 2>/dev/null || true

  if [[ -f "/run/migrant/${vm}.wgdns" ]]; then
    IFS=',' read -ra dns_list <<< "$(cat "/run/migrant/${vm}.wgdns")"
    for dns_ip in "${dns_list[@]}"; do
      dns_ip="${dns_ip// /}"
      [[ -z "$dns_ip" ]] && continue
      iptables -D FORWARD -i "$iface" -d "${dns_ip}/32" -j ACCEPT 2>/dev/null || true
    done
    rm -f "/run/migrant/${vm}.wgdns"
  fi

  ip link set "$WG_IFACE" down 2>/dev/null || true
  ip link del "$WG_IFACE" 2>/dev/null || true

  echo "migrant: WireGuard torn down: $WG_IFACE for $vm" >&2
}
```

### Hook `case` statement

```bash
case "$OPERATION" in
  prepare) wg_setup_iface  "$VM_NAME" ;;
  started) apply_rules     "$VM_NAME" ;;   # calls wg_setup_rules at the end
  release) remove_rules    "$VM_NAME" ;;   # calls wg_teardown if iface exists
esac
```

`remove_rules` checks for the WireGuard interface before calling `wg_teardown`:

```bash
local WG_IFACE="wg-$(printf '%s' "$vm" | md5sum | head -c7)"
if ip link show "$WG_IFACE" &>/dev/null \
    || [[ -f "/run/migrant/${vm}.wgdns" ]]; then
  wg_teardown "$vm" "$iface"
fi
```

---

## Changes to `cmd_status`

`cmd_status` should report tunnel state so the user can confirm at a glance
whether traffic is actually being tunneled. The check is based on the managed
conf (for configuration) and the live kernel state (for active status):

```bash
# Derive interface name and table ID the same way the hook does
local wg_iface="wg-$(printf '%s' "$VM_NAME" | md5sum | head -c7)"
local wg_table wg_table_hex
wg_table=$(( 10000 + ( 16#$(printf '%s' "$wg_iface" | md5sum | head -c4) % 10000 ) ))
wg_table_hex=$(printf '%x' "$wg_table")

if [[ -f "/etc/migrant/${VM_NAME}/wireguard.conf" ]]; then
  local wg_endpoint
  wg_endpoint=$(awk -F= '/^\s*Endpoint\s*=/{gsub(/ /,"",$2); print $2}' \
    "/etc/migrant/${VM_NAME}/wireguard.conf" | cut -d: -f1)

  if ip link show "$wg_iface" &>/dev/null \
      && ip rule show | grep -q "fwmark 0x${wg_table_hex}"; then
    echo "Tunnel:   active — $wg_iface → $wg_endpoint"
  elif [[ "$state" == "running" ]]; then
    echo "Tunnel:   ERROR — configured but traffic is NOT tunneled"
  else
    echo "Tunnel:   $wg_endpoint (configured, inactive while VM is stopped)"
  fi
else
  echo "Tunnel:   none"
fi
```

The three running-VM states map to distinct messages:

| State                                  | Output                                             |
| -------------------------------------- | -------------------------------------------------- |
| Interface up + fwmark rule present     | `active — wg-XXXXXXX → 142.147.89.210`            |
| Interface up but fwmark rule missing   | `ERROR — configured but traffic is NOT tunneled`  |
| Managed conf exists but interface down | `ERROR — configured but traffic is NOT tunneled`  |
| VM stopped, managed conf exists        | `142.147.89.210 (configured, inactive while VM is stopped)` |
| No managed conf                        | `none`                                             |

The "ERROR" line uses the same wording as the `verify_wireguard_tunnel` failure
message so the user sees a consistent signal regardless of how they discover the
problem.

Note that `cmd_status` reads `/etc/migrant/<vm-name>/wireguard.conf` (the
managed copy placed by `up`) rather than `$VM_DIR/wireguard.conf`. This means
a `wireguard.conf` that has been added to the VM directory but not yet activated
by a `halt` + `up` cycle is not shown — accurately reflecting that the VM is not
yet tunneled.

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
error in `cmd_up` is the appropriate place.

---

## Prerequisite checking: userspace tool vs kernel module

`cmd_up` checks for the `wg` binary (`wireguard-tools`). It does **not**
separately check for the WireGuard kernel module. These are independent:
on Arch Linux, `wireguard-tools` is a separate package from the kernel, and
one can be present without the other.

A reliable userspace check for the kernel module is not feasible. The
available approaches all have gaps:

| Method                          | Problem                                      |
| ------------------------------- | -------------------------------------------- |
| `grep wireguard /proc/modules`  | Only shows loaded modules; misses built-ins  |
| `modinfo wireguard`             | Finds `.ko` file; fails for built-in kernels |
| `modprobe --dry-run wireguard`  | Same as above                                |
| `/sys/module/wireguard/`        | Only present once the module is active       |

The definitive check is `ip link add <iface> type wireguard`, which exercises
the actual kernel interface — but this requires root and is exactly what
`wg_setup_iface` does in the `prepare` hook. If the module is absent, `ip link
add` fails, the hook returns non-zero, libvirt aborts the VM start, and `cmd_up`
exits via `set -euo pipefail`.

To make this failure legible rather than surfacing a raw `RTNETLINK` error,
`wg_setup_iface` should wrap the `ip link add` call explicitly:

```bash
ip link add "$WG_IFACE" type wireguard 2>/dev/null || {
  echo "migrant: wg_setup_iface: failed to create WireGuard interface for $vm" >&2
  echo "migrant: is the 'wireguard' kernel module available? (try: modprobe wireguard)" >&2
  return 1
}
```

In summary: `cmd_up` catches the missing-userspace-tool case early with a clear
message. The missing-kernel-module case is caught synchronously by the `prepare`
hook with an equally clear message. No additional check is needed in `cmd_up`.

---

## `.gitignore` and README

**`.gitignore`:** Add `*/wireguard.conf` to prevent accidental commits of
WireGuard private keys from any of the three example VM directories.

**`README.md`:** Add a warning alongside the existing loop image note:

> Add `*/wireguard.conf` to `.gitignore` to avoid committing WireGuard private
> keys to source control if your VM directory is in a git repository.

---

## Summary of file changes

| File                                       | Change                                                              |
| ------------------------------------------ | ------------------------------------------------------------------- |
| `migrant.sh` — `cmd_up`                   | Error+abort if `wg` missing; sync conf; call `verify_wireguard_tunnel` after start  |
| `migrant.sh` — `cmd_status`               | Report tunnel state (active/error/configured/none) with interface and endpoint IP   |
| `migrant.sh` — `teardown_vm`              | `rm -rf /etc/migrant/<name>/`                                       |
| `migrant.sh` — qemu hook `case` statement | Add `prepare` branch calling `wg_setup_iface`                       |
| `migrant.sh` — qemu hook body             | Add `wg_setup_iface`, `wg_setup_rules`, `wg_teardown` functions     |
| `migrant.sh` — qemu hook `apply_rules`    | Call `wg_setup_rules` after NETWORK_ISOLATION rules                 |
| `migrant.sh` — qemu hook `remove_rules`   | Call `wg_teardown` if WG interface exists                           |
| `.gitignore`                               | Add `*/wireguard.conf`                                              |
| `README.md`                               | Add private key gitignore warning                                   |
