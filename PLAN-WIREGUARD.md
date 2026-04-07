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
ip rule add fwmark "$WG_TABLE" lookup "$WG_TABLE" priority "$WG_TABLE"
```

### Routing table ID

Policy routing tables require integer IDs. The ID is derived by interpreting
the same 7-char hex hash as an integer, giving 2²⁸ = 268,435,456 possible
values (50% collision probability at ~19,000 VMs — negligible in practice).
The four kernel-reserved table IDs (0, 253–255) are avoided with probability
< 2 × 10⁻⁶:

```bash
WG_TABLE=$(( 16#$(printf '%s' "$vm" | md5sum | head -c7) ))
```

The table contains one entry:

```bash
# All VM traffic exits via the WireGuard interface.
ip route add default dev "$WG_IFACE" table "$WG_TABLE"
```

No endpoint exclusion route is needed. The mangle PREROUTING mark only applies
to packets *received* on the VM's tap interface. WireGuard's own outgoing
encrypted UDP is a locally-generated packet: it is born in the kernel and flows
through the `OUTPUT` chain, never through `PREROUTING`. It is therefore never
marked with `WG_TABLE`, the policy rule never applies to it, and it routes via
the main table to the real gateway. There is no routing loop under any
circumstances.

### Why SSH from the host is unaffected

When the host connects to the VM via SSH, the connection is initiated by the
host and the TCP session is established over the `virbr-migrant` bridge
(192.168.200.0/24). Replies from the VM arrive on the host at the tap interface,
are marked by the mangle PREROUTING rule, and are then subject to policy routing.

However, the destination of a reply is `192.168.200.1` — the host's own bridge
IP. Linux's local routing table (table 255, priority 0) is evaluated before any
user-defined rule. It always contains a local route for `192.168.200.1`. The
policy rule (at priority `WG_TABLE`) is never reached for traffic destined to the host itself. SSH from the host to the VM works correctly with the tunnel active.

---

## WireGuard interface management

`wg-quick` is not used. It processes `DNS`, `Table`, and `PostUp`/`PostDown`
directives and applies them to the host system — modifying `/etc/resolv.conf`,
routing tables, and running arbitrary scripts. Instead, the hook brings up the
interface using the lower-level `wg` and `ip` commands directly, which gives
full control and no host side effects.

All parsing and validation of `wireguard.conf` is done at sync time by
`sync_wireguard_config` (called from `cmd_up`), which writes pre-processed files
into `/etc/migrant/<vm-name>/`. The hook reads those files directly:

| File                | Content                                    |
| ------------------- | ------------------------------------------ |
| `wireguard.conf`    | Raw copy (contains private key)                      |
| `wireguard-wg.conf` | `wg-quick`-only fields stripped; passed to `wg setconf` |
| `wireguard-endpoint`| Validated numeric endpoint IP (used by `cmd_status`) |
| `wireguard-address` | Normalized comma-separated interface addresses       |
| `wireguard-dns`     | Normalized comma-separated DNS IPs (absent if none)  |

Interface bring-up in the hook:

```bash
ip link add "$WG_IFACE" type wireguard

# wireguard-wg.conf has wg-quick-only fields stripped at sync time; no temp file needed.
wg setconf "$WG_IFACE" "/etc/migrant/${VM_NAME}/wireguard-wg.conf"

IFS=',' read -ra addr_list <<< "$(cat "/etc/migrant/${VM_NAME}/wireguard-address")"
for addr in "${addr_list[@]}"; do
  addr="${addr// /}"
  [[ -n "$addr" ]] && ip addr add "$addr" dev "$WG_IFACE"
done

# WireGuard adds ~60 bytes of per-packet overhead; 1420 keeps encapsulated
# packets under the 1500-byte Ethernet MTU and prevents fragmentation.
ip link set "$WG_IFACE" mtu 1420
ip link set "$WG_IFACE" up
```

---

## DNS handling

If the Mullvad config contains a `DNS` line (e.g. `DNS = 10.64.0.1`),
`sync_wireguard_config` parses and normalizes the value into
`/etc/migrant/<vm-name>/wireguard-dns` (comma-separated IPs). When
`NETWORK_ISOLATION=true` is also set, the RFC1918 FORWARD REJECT rules would
otherwise block the VM from reaching `10.64.0.1` — even though the traffic
travels inside the WireGuard tunnel. `wg_setup_rules` reads `wireguard-dns` and
inserts a targeted FORWARD ACCEPT rule before the REJECT rules for each DNS IP.
`wg_teardown` reads the same file to remove those rules on shutdown.

The ACCEPT rules are harmless when `NETWORK_ISOLATION=false` — there are no
RFC1918 blocks to punch through, so the rules simply match nothing of
consequence.

If `wireguard.conf` has no `DNS` line, `wireguard-dns` is not created. The VM
uses the host's resolver via libvirt's DHCP (`192.168.200.1`). DNS queries are
resolved by the host and are not routed through the VPN. The host is trusted, so
this is acceptable; `sync_wireguard_config` prints a one-line warning so the user
is aware rather than surprised. Users who want DNS routed through the VPN should
add a `DNS` line to their config.

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

All WireGuard setup that can be done as the invoking user is handled by
`sync_wireguard_config`. No `sudo` is needed: `cmd_setup` creates `/etc/migrant/`
as `root:libvirt 2770`, and because the invoking user is in the `libvirt` group,
they can create and manage their own subdirectory there without elevated
privileges. The hooks receive pre-validated, pre-parsed files and do no parsing
of their own.

`cmd_up` calls `sync_wireguard_config` after the "VM is already running" early
return. The managed directory must reflect the config the VM is actually running
with: `cmd_status` reads from it to report tunnel state, so syncing on a running
VM would show a config not yet in effect. Changes to `wireguard.conf` take effect
on the next `halt` + `up`.

```bash
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
```

### `wg_iface_and_table` (helper — main script)

An identical helper lives in the main script (lowercase variables to match the
surrounding code style) and is shared by `verify_wireguard_tunnel` and
`cmd_status`:

```bash
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
```

### Post-start tunnel verification

After the VM is started, `cmd_up` verifies that WireGuard setup completed
successfully. This is called immediately after `virsh start` (or `virt-install`)
in every code path, including the `AUTOCONNECT=console` early return, before the
user is handed control.

Both the interface and the `ip rule` are created synchronously in `prepare`, so
no polling is required — if `virsh start` succeeds, both are guaranteed to be
present. The mangle PREROUTING rule (added asynchronously in `started`) is not
checked here; its absence means packets are not marked and therefore not routed
via the WireGuard table, which is equivalent to the interface check failing.

```bash
verify_wireguard_tunnel() {
  # No-op if WireGuard is not configured for this VM
  [[ -f "/etc/migrant/${VM_NAME}/wireguard.conf" ]] || return 0

  local wg_iface wg_table wg_table_hex
  wg_iface_and_table "$VM_NAME"
  wg_table_hex=$(printf '%x' "$wg_table")

  # Both checks are synchronous: the interface and ip rule are created in the
  # prepare hook, which must complete before virsh start returns.
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

| Phase     | Operation         | What can be done                                       | Failure mode              |
| --------- | ----------------- | ------------------------------------------------------ | ------------------------- |
| `prepare` | `wg_setup_iface`  | Create WG interface, assign addr, routing table, `ip rule` | Aborts VM start       |
| `started` | `wg_setup_rules`  | mangle PREROUTING mark rule, DNS FORWARD ACCEPTs       | Async; caught by `cmd_up` |
| `release` | `wg_teardown`     | Remove all of the above                                | —                         |

The existing `apply_rules` (NETWORK_ISOLATION iptables) and `remove_rules`
functions stay on `started`/`release` as before. `wg_setup_iface` is added as
a new `prepare` branch in the hook's `case` statement.

### `wg_iface_and_table` (helper — defined once, used by all three hook functions)

Sets `WG_IFACE` and `WG_TABLE` for a given VM name. Both values are derived
directly from the VM name so there is no double-hashing. Callers declare the
variables `local` before calling so bash's dynamic scoping keeps them out of
the global namespace.

```bash
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
```

### `wg_setup_iface` (called on `prepare` — synchronous)

A non-zero exit here aborts the VM start. Any failure to create the interface or
configure the routing table is immediately visible to `cmd_up` as a failed
`virsh start`.

```bash
wg_setup_iface() {
  local vm="$1"
  local managed="/etc/migrant/${vm}"
  [[ -f "$managed/wireguard.conf" ]] || return 0

  # wg absence was already caught by cmd_up before virsh start was called,
  # but check defensively in case the hook fires via another path.
  command -v wg &>/dev/null || {
    echo "migrant: wg_setup_iface: 'wg' not found; cannot set up tunnel for $vm" >&2
    return 1
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
    return 1
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
  ip rule add fwmark "$WG_TABLE" lookup "$WG_TABLE" priority "$WG_TABLE"

  echo "migrant: WireGuard interface up: $WG_IFACE (table $WG_TABLE) for $vm" >&2
}
```

### `wg_setup_rules` (called from `apply_rules` on `started` — async)

This function requires the tap interface, which exists by the time `started`
fires. It is called at the end of `apply_rules`. When `NETWORK_ISOLATION=true`,
the REJECT rules are already in place by that point, so the DNS ACCEPT rules
(inserted with `-I`) end up before them. When only WireGuard is configured (no
network isolation), there are no REJECT rules; the ACCEPT rules are harmless.

```bash
wg_setup_rules() {
  local vm="$1" iface="$2"
  [[ -f "/etc/migrant/${vm}/wireguard.conf" ]] || return 0

  local WG_IFACE WG_TABLE
  wg_iface_and_table "$vm"

  # Mark all packets from this VM's tap with the WireGuard table ID. The policy
  # rule that routes marked packets via the WireGuard table was already added in
  # the prepare hook (wg_setup_iface), where it doesn't require the tap interface.
  iptables -t mangle -A PREROUTING -i "$iface" -j MARK --set-mark "$WG_TABLE"

  # Drop all IPv6 from this VM. The fwmark routing is IPv4-only; without this
  # rule IPv6 traffic would bypass the tunnel and exit via the host's default
  # IPv6 path. The libvirt network provides no routable IPv6 to VMs, so this
  # rule enforces an existing de-facto limitation rather than removing capability.
  ip6tables -I FORWARD -i "$iface" -j DROP

  # DNS FORWARD exceptions — IPs pre-parsed and normalized at sync time.
  local wg_dns_file="/etc/migrant/${vm}/wireguard-dns"
  if [[ -f "$wg_dns_file" ]]; then
    IFS=',' read -ra dns_list <<< "$(cat "$wg_dns_file")"
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

  local WG_IFACE WG_TABLE
  wg_iface_and_table "$vm"

  iptables -t mangle -D PREROUTING -i "$iface" -j MARK \
    --set-mark "$WG_TABLE" 2>/dev/null || true
  ip rule del fwmark "$WG_TABLE" lookup "$WG_TABLE" 2>/dev/null || true
  ip route flush table "$WG_TABLE" 2>/dev/null || true

  ip6tables -D FORWARD -i "$iface" -j DROP 2>/dev/null || true

  local wg_dns_file="/etc/migrant/${vm}/wireguard-dns"
  if [[ -f "$wg_dns_file" ]]; then
    IFS=',' read -ra dns_list <<< "$(cat "$wg_dns_file")"
    for dns_ip in "${dns_list[@]}"; do
      dns_ip="${dns_ip// /}"
      [[ -z "$dns_ip" ]] && continue
      iptables -D FORWARD -i "$iface" -d "${dns_ip}/32" -j ACCEPT 2>/dev/null || true
    done
  fi

  ip link set "$WG_IFACE" down 2>/dev/null || true
  ip link del "$WG_IFACE" 2>/dev/null || true

  echo "migrant: WireGuard torn down: $WG_IFACE for $vm" >&2
}
```

### Hook guard restructuring

The existing hook has two top-level guards:

```bash
echo "$xml" | grep -q "managed-by=migrant.sh" || exit 0
echo "$xml" | grep -q "network-isolation=true" || exit 0
```

The second guard must be removed. WireGuard is activated by the presence of
`/etc/migrant/<vm-name>/wireguard.conf`, not by the `network-isolation=true`
description flag. A VM may use WireGuard without network isolation, and vice
versa. With both guards at the top, the hook exits before `wg_setup_iface` runs
for any VM where `NETWORK_ISOLATION` is not set.

Instead, the flag is read into a local variable immediately after the
`managed-by` check:

```bash
echo "$xml" | grep -q "managed-by=migrant.sh" || exit 0

HAS_NETWORK_ISOLATION=false
echo "$xml" | grep -q "network-isolation=true" && HAS_NETWORK_ISOLATION=true
```

`apply_rules` is updated to gate the INPUT/FORWARD iptables rules on
`$HAS_NETWORK_ISOLATION`. The tap interface discovery and `/run/migrant/` write
run unconditionally — they are needed by `wg_setup_rules` regardless of whether
network isolation is active:

```bash
apply_rules() {
  local vm="$1"

  # No work needed if this VM uses neither network isolation nor WireGuard.
  [[ "$HAS_NETWORK_ISOLATION" == true ]] \
    || [[ -f "/etc/migrant/${vm}/wireguard.conf" ]] \
    || return 0

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

  if [[ "$HAS_NETWORK_ISOLATION" == true ]]; then
    iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
    iptables -A "$CHAIN" -m conntrack --ctstate NEW -j REJECT
    iptables -I INPUT -i "$iface" -j "$CHAIN"

    iptables -I FORWARD -i "$iface" -d 10.0.0.0/8 -j REJECT
    iptables -I FORWARD -i "$iface" -d 172.16.0.0/12 -j REJECT
    iptables -I FORWARD -i "$iface" -d 192.168.0.0/16 -j REJECT
  fi

  wg_setup_rules "$vm" "$iface"
}
```

`remove_rules` mirrors this structure. The isolation teardown is conditional;
the WireGuard teardown is unconditional (guarded by interface existence rather
than the flag, because the conf may have been removed since the VM started):

```bash
remove_rules() {
  local vm="$1"
  local iface
  iface=$(cat "/run/migrant/${vm}.iface" 2>/dev/null) || return 0
  [[ -z "$iface" ]] && return 0

  if [[ "$HAS_NETWORK_ISOLATION" == true ]]; then
    iptables -D INPUT -i "$iface" -j "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN" 2>/dev/null || true
    iptables -X "$CHAIN" 2>/dev/null || true

    iptables -D FORWARD -i "$iface" -d 10.0.0.0/8 -j REJECT 2>/dev/null || true
    iptables -D FORWARD -i "$iface" -d 172.16.0.0/12 -j REJECT 2>/dev/null || true
    iptables -D FORWARD -i "$iface" -d 192.168.0.0/16 -j REJECT 2>/dev/null || true
  fi

  local WG_IFACE WG_TABLE
  wg_iface_and_table "$vm"
  if ip link show "$WG_IFACE" &>/dev/null \
      || [[ -f "/etc/migrant/${vm}/wireguard-dns" ]]; then
    wg_teardown "$vm" "$iface"
  fi

  rm -f "/run/migrant/${vm}.iface"
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

---

## Changes to `cmd_status`

`cmd_status` should report tunnel state so the user can confirm at a glance
whether traffic is actually being tunneled. The check is based on the managed
conf (for configuration) and the live kernel state (for active status).

The WireGuard block uses `$state` (the VM's libvirt domain state) to distinguish
between "running but untunneled" and "stopped with config present". Currently
`state` is declared inside the `else` branch of the VM-exists check, making it
unavailable at the outer scope where snapshot and shared folder output also run.
Hoist the declaration to the top of `cmd_status`:

```bash
local state=""
```

and set it inside the `else` branch as before. The WireGuard block then sits
at the outer scope alongside snapshot and shared folder output, with `state`
available. When the VM does not exist, `state` is empty and the managed
directory is absent, so the WireGuard block outputs `Tunnel:   none` and the
`$state` comparison is never reached.

```bash
local wg_iface wg_table wg_table_hex
wg_iface_and_table "$VM_NAME"
wg_table_hex=$(printf '%x' "$wg_table")

if [[ -f "/etc/migrant/${VM_NAME}/wireguard.conf" ]]; then
  local wg_endpoint
  wg_endpoint=$(cat "/etc/migrant/${VM_NAME}/wireguard-endpoint")

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
rm -rf "/etc/migrant/${VM_NAME}"
```

No `sudo` is needed: the directory is owned by the invoking user. This should
run after `virsh undefine` in `teardown_vm`, so stale configs do not accumulate
in `/etc/migrant/` for long-deleted VMs.

---

## `cmd_setup`

The qemu hook is content-checked with `cmp` on every `setup` run. Adding
WireGuard logic to the hook body will cause `cmp` to fail, triggering the
existing "hook is outdated, reinstalling" path. Users must re-run
`migrant.sh setup` after the update, as they would for any hook change.

The `wireguard-tools` prerequisite is intentionally not checked here. `setup`
configures host infrastructure; WireGuard is an optional per-VM feature. The
error in `cmd_up` is the appropriate place.

`cmd_setup` must also create `/etc/migrant/` with the correct ownership and
permissions. This is the only step that requires elevated privileges for
WireGuard — everything else in `sync_wireguard_config` runs as the invoking
user. The directory is owned by `root:libvirt` with the setgid bit set so that
subdirectories created by libvirt group members inherit the group automatically:

```bash
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
```

Because `cmd_setup` verifies the user is in the `libvirt` group (and adds them
if not), the invoking user is guaranteed to have write access to `/etc/migrant/`
by the time they run `migrant.sh up`. No new group is needed.

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
the `ip link add` call in `wg_setup_iface` is wrapped with an explicit error
message (see the function body above). In summary: `cmd_up` catches the
missing-userspace-tool case early with a clear message. The missing-kernel-module
case is caught synchronously by the `prepare` hook with an equally clear message.
No additional check is needed in `cmd_up`.

---

## `.gitignore` and README

**`.gitignore`:** Add `*/wireguard.conf` to prevent accidental commits of
WireGuard private keys from any of the three example VM directories.

**`README.md`:** Add a warning alongside the existing loop image note:

> Add `*/wireguard.conf` to `.gitignore` to avoid committing WireGuard private
> keys to source control if your VM directory is in a git repository.

---

## Summary of file changes

| File                                       | Change                                                                               |
| ------------------------------------------ | ------------------------------------------------------------------------------------ |
| `migrant.sh` — `sync_wireguard_config`    | New function: validates, copies, and pre-parses WireGuard config into managed files  |
| `migrant.sh` — `cmd_up`                   | Call `sync_wireguard_config`; call `verify_wireguard_tunnel` after start             |
| `migrant.sh` — `cmd_status`               | Report tunnel state (active/error/configured/none) with interface and endpoint IP    |
| `migrant.sh` — `teardown_vm`              | `rm -rf /etc/migrant/<name>/`                                                        |
| `migrant.sh` — qemu hook `case` statement | Add `prepare` branch calling `wg_setup_iface`; remove top-level network-isolation guard |
| `migrant.sh` — qemu hook body             | Add `wg_setup_iface`, `wg_setup_rules`, `wg_teardown` functions                     |
| `migrant.sh` — qemu hook `apply_rules`    | Discover tap unconditionally; gate isolation rules on `HAS_NETWORK_ISOLATION`; call `wg_setup_rules` |
| `migrant.sh` — qemu hook `remove_rules`   | Gate isolation teardown on `HAS_NETWORK_ISOLATION`; call `wg_teardown` if WG state exists |
| `.gitignore`                               | Add `*/wireguard.conf`                                                               |
| `README.md`                               | Add private key gitignore warning                                                    |
