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
)
```

| Directive                      | Effect                                                                                       |
| ------------------------------ | -------------------------------------------------------------------------------------------- |
| `allow-host-port <proto/port>` | Allow the VM to connect to the specified host port, regardless of the service's bind address |
| `allow-lan-host <ip>`          | Allow the VM to reach a specific host on the local network                                   |

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

`HOST_ACCESS` has no effect when isolation is disabled
(`NETWORK_ISOLATION=false`) — there is nothing to poke holes in.

Combined with [lifecycle hooks](../hooks.md), this enables host-side service
patterns: a hook starts a systemd service before the VM boots, `HOST_ACCESS`
opens the port, and a hook stops the service when the VM shuts down.
