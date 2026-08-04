# WireGuard VPN tunnel

Place a standard `wireguard.conf` (wg-quick format) alongside the `Migrantfile`
to route all VM traffic through a WireGuard VPN. No changes to `cloud-init.yml`
or the VM are required.

```
examples/ubuntu/
├── Migrantfile
├── cloud-init.yml
└── wireguard.conf      ← drop any wg-quick config here
```

`migrant up` validates the config and syncs it to a root-owned directory
(`/etc/migrant/<vm-name>/`) before starting the VM. The hook brings up the
tunnel as part of VM startup and tears it down when the VM stops.

**Requirements:**

- `wireguard-tools` (`wg`) must be installed on the host
- The `wireguard` kernel module must be available (`modprobe wireguard`)
- `Endpoint` must be a numeric IP address, not a hostname

## How it works

The host creates a WireGuard interface (`mg-wg-<hash>`) and a dedicated routing
table. An iptables `mangle PREROUTING` rule marks every packet arriving from the
VM's tap device with the table ID; a policy rule (`ip rule`) then diverts those
marked packets to the WireGuard table, where the only route is
`default dev mg-wg-<hash>`. The result: all VM traffic exits the host via the
encrypted WireGuard tunnel, regardless of what the VM itself does.

IPv6 from the VM is dropped at the `FORWARD` chain. The fwmark routing is
IPv4-only, so without this IPv6 would bypass the tunnel — which is why
`NETWORK_IPV6=nat` is refused alongside WireGuard (see
[IPv6 (NAT66)](ipv6-nat66.md)). A WireGuard VM therefore always has its IPv6
dropped.

`migrant up` verifies the tunnel is active before returning. If the WireGuard
interface or routing rule is missing, or the marking rule was not applied within
5 seconds, `up` halts the VM and exits with an error so the VM never runs
un-tunneled.

## DNS

DNS behaviour depends on whether `wireguard.conf` contains a `DNS =` line:

- **With `DNS =`**: migrant intercepts all DNS traffic from the VM with a
  `nat PREROUTING` DNAT rule and rewrites the destination to the VPN's DNS
  server. The VM continues to believe it is talking to the libvirt resolver
  (`192.168.200.1`); conntrack reverses the translation on the reply. DNS
  queries reach the VPN server through the tunnel and are never seen by the host
  resolver.

- **Without `DNS =`**: a warning is printed and DNS falls back to the host's
  resolver via libvirt's dnsmasq. Queries are not tunneled.

`migrant status` shows which DNS mode is active:

```
tunnel:     active
  iface:    mg-wg-a1b2c3d
  peer:     198.51.100.1
  dns:      10.8.0.1
```

## Threat model

The WireGuard tunnel is enforced entirely on the host, in kernel space. The VM
cannot bypass it:

- The routing policy is applied to packets leaving the VM's tap interface before
  they reach any user-space process. An attacker with root inside the VM cannot
  remove or modify these host-side rules.
- DNS interception via DNAT is also host-side. The VM cannot make DNS queries to
  an off-tunnel resolver by targeting a different IP — all port-53 traffic is
  rewritten.
- If the tunnel fails to come up, `migrant up` halts the VM rather than letting
  it run un-tunneled.
- IPv6 is dropped at the FORWARD chain, so there is no IPv6 leak path.
  `NETWORK_IPV6=nat` (which opens IPv6 egress) is refused on WireGuard VMs, so a
  tunneled VM always has its IPv6 dropped.

This does not prevent the VM from sending traffic to other hosts on the VPN once
the tunnel is active. Network isolation is enabled by default alongside
WireGuard, which restricts which VPN destinations the VM can reach (note:
`NETWORK_ISOLATION` blocks RFC 1918 ranges, which do not apply inside a VPN
tunnel).

## Security notes

`wireguard.conf` contains a WireGuard private key. Keep it out of source
control:

```gitignore
*/wireguard.conf
```

The managed config directory (`/etc/migrant/<vm-name>/`) is owner-only (`700`)
so other users in the `libvirt` group cannot read each other's private keys. The
qemu hook runs as root and is unaffected by these permissions.
