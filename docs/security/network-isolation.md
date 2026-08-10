# Network isolation

Network isolation is enabled by default for all VMs. Set
`NETWORK_ISOLATION=false` in a `Migrantfile` to opt out. When active, iptables
rules are added that:

- Block the VM from initiating new connections to the host (DNS and DHCP
  responses from the host are still delivered, as those are tracked as existing
  connections)
- Block the VM from reaching private (RFC 1918), shared (`100.64.0.0/10`) and
  link-local (`169.254.0.0/16`) addresses, including the libvirt subnet itself
  (192.168.200.0/24) so VMs cannot reach each other. Shared address space is
  where overlay and mesh VPNs and carrier NAT allocate; link-local carries the
  `169.254.169.254` metadata address. This is not comprehensive LAN isolation —
  private infrastructure can use globally routable prefixes, which no static
  list of special-use ranges identifies
- Drop all IPv6 *egress* from the VM at the `FORWARD` chain by default (the
  libvirt network provides no routable IPv6 to VMs). Opt a VM in to IPv6 egress
  with `NETWORK_IPV6=nat` — see [IPv6 (NAT66)](ipv6-nat66.md)
- Block the VM from initiating new IPv6 connections to the host, in every IPv6
  mode. The bridge always carries a ULA, and guest→host traffic to it is locally
  delivered to `INPUT` rather than `FORWARD`, so the egress drop above does not
  cover it

The rules are removed automatically when the VM stops or is destroyed. This
requires `migrant setup` to have been run to install the libvirt hook and enable
bridge netfilter (`br_netfilter` plus the `net.bridge.bridge-nf-call-ip*tables`
sysctls) — the rules match bridged traffic through `physdev` and are inert
without it. A VM refuses to start if either sysctl is later set back to 0.

libvirt must also be using its **iptables** firewall backend. The per-VM chain
is entered from `INPUT` just after libvirt's `LIBVIRT_INP`, which does not exist
under the nftables backend — libvirt filters in its own table instead. A VM
refuses to start rather than install rules that would both miss host traffic and
reject the guest's own DHCP and DNS. `migrant setup` sets
`firewall_backend = "iptables"` in `/etc/libvirt/network.conf` and restarts
libvirtd; this applies to every libvirt network on the host, not just `migrant`.

These rules govern *forwarded* traffic. A host address inside one of these
ranges is delivered locally, and guest→host is blocked by the per-VM `INPUT`
chain instead — not by the rules above.

Two limits worth knowing. The rules are scoped by `physdev`, which matches a
bridge port, so a NIC attached some other way — macvtap, for instance — is not
covered by them and isolation does not apply to it. And there is no MAC
anti-spoofing: the bridge-level gate that holds a guest offline during rule
setup matches on source MAC, so a guest that changes its own MAC steps around
that gate. Neither weakens the `physdev`-scoped rules themselves, which are what
stops guest→host traffic once they are installed.

## Host access rules

The `HOST_ACCESS` array in a `Migrantfile` declares exceptions to network
isolation. Each entry is a directive that the libvirt hook translates to an
iptables rule, applied atomically alongside the isolation rules:

```bash
HOST_ACCESS=(
  "allow-host-port tcp/8080"        # VM can reach host:8080
  "allow-host-port udp/5353"        # VM can reach host:5353/udp
  "allow-lan-host 192.168.1.50"     # VM can reach a specific LAN host
  "forward-port tcp/11434 100.64.0.6:11434"   # one remote port, via the gateway
)
```

| Directive                                                         | Effect                                                                                       |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `allow-host-port <proto/port>`                                    | Allow the VM to connect to the specified host port, regardless of the service's bind address |
| `allow-lan-host <ip>`                                             | Allow the VM to reach a specific host on the local network                                   |
| `forward-port <proto/guest-port> <ip>:<remote-port> [via-tunnel]` | Map one port on one remote host into the VM, reachable at the bridge gateway                 |

`allow-host-port` inserts an ACCEPT in the per-VM INPUT chain and DNATs traffic
to `127.0.0.1`, so the VM can reach host services regardless of bind address.
`allow-lan-host` inserts an ACCEPT in the FORWARD chain before the RFC 1918
REJECT rules. All directives are removed automatically when the VM stops.

The `allow-host-port` DNAT matches only traffic addressed to the bridge gateway,
`192.168.200.1`. Point the guest there — reaching the host by any other address,
such as its LAN IP, is not rewritten and is blocked by the isolation rules.
Connections the guest makes to *other* hosts on the same port are left alone.

On a WireGuard VM, `allow-lan-host` is resolved against the host's main routing
table and the result is excluded from the tunnel. Point it at an address that
lives *inside* the VPN and the traffic leaves by whatever device that table
selects instead — another VPN, an overlay, a VLAN, or the physical NIC — where a
different machine may hold that address, so the VM talks to a stranger with no
error anywhere. The hook logs a warning when the tunnel's `AllowedIPs`
explicitly claims a target that routes elsewhere; it cannot warn for a
full-tunnel `0.0.0.0/0`, which claims every address.

### forward-port

`allow-lan-host` opens every port on a host. `forward-port` opens one:

```bash
HOST_ACCESS=(
  "forward-port tcp/11434 100.64.0.6:11434"
)
```

The guest connects to `192.168.200.1:11434` — the bridge gateway — and lands on
`100.64.0.6:11434`. Both ports are written out, so they need not match.

The ACCEPT that lets the traffic through is matched on the connection's
*original* destination, meaning what the guest addressed before the mapping
rewrote it. A packet the guest sends straight to `100.64.0.6:11434` has a
different original destination, does not match, and falls through to the
isolation rejects. The mapping is the only way in.

**That said, `forward-port` adds a route; it removes none.** The one-port
property holds when the target is somewhere the guest could not otherwise reach
— anything in the private, shared or link-local ranges isolation already
rejects. Point it at a *public* address and the guest can still reach that host
directly on every port, over ordinary internet egress. Not because the directive
leaks, but because nothing rejects public destinations.

IPv4 only. There is no IPv6 form, and a NAT66 target is not supported.

Guest ports 53, 67 and 68 are refused: DHCP and DNS are answered on the gateway,
and a mapping on 53 would sit above the WireGuard DNS interception and take the
guest's queries out of the tunnel.

The reply arrives on whichever interface the host uses to reach the target, so
that interface must not have reverse-path filtering strict enough to drop it.
migrant sets `rp_filter` on its own bridge and WireGuard interfaces and does not
touch interfaces it did not create.

**On a WireGuard VM**, the target is excluded from the tunnel by a host route,
exactly as `allow-lan-host` is — which is wrong if the target lives *inside* the
VPN. Append `via-tunnel` for that case and no exclusion is installed, so the
mapped traffic follows the tunnel. Omitting it for a tunnel-internal address
sends the traffic out whatever the main routing table selects, where another
machine may answer on that address. `via-tunnel` without a `wireguard.conf` is
refused rather than ignored.

The exclusion route is resolved once, when the VM is prepared. If the route to
the target changes afterwards the tunnel table is not updated and the mapping
stops working until the VM restarts.

No two entries may claim the same guest `proto/port`, whichever directives they
are: two rules for one endpoint install both, and insertion order rather than
the config decides which the guest reaches.

`allow-lan-host` and `forward-port` are, by construction, deliberate holes in
the tunnel: each installs a host route that sends that destination out of the
VPN, with whatever source address the selected interface gives it. That is the
point of the directives, but it means a target outside the tunnel is reached
outside the tunnel. `forward-port … via-tunnel` is the form that does not do
this.

`HOST_ACCESS` has no effect when isolation is disabled
(`NETWORK_ISOLATION=false`) — there is nothing to poke holes in.

Combined with [lifecycle hooks](../hooks.md), this enables host-side service
patterns: a hook starts a systemd service before the VM boots, `HOST_ACCESS`
opens the port, and a hook stops the service when the VM shuts down.
