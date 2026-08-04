# IPv6 (NAT66)

By default a migrant VM has no routable IPv6 — the `migrant` network is IPv4 NAT
only, and the qemu hook drops the VM's IPv6 at the `FORWARD` chain. Set
`NETWORK_IPV6=nat` in a `Migrantfile` to opt a VM in to IPv6 egress. When
enabled, the VM receives a ULA address (`fdca:6d16:2b1a::/64`) and the hook
masquerades it to the host's IPv6 uplink, mirroring the IPv4 NAT. With
`NETWORK_ISOLATION` on (the default), the VM still cannot reach the host or
other VMs/LAN over IPv6 — only the internet.

Once the VM is up, `migrant status` shows an `ipv6:` line and `migrant ip -6`
prints the ULA address (best-effort — it is read from the DHCPv6 lease, so it
may be blank if the guest configured a SLAAC-only address).

Requirements and caveats:

- **The host must have working IPv6 egress.** NAT66 masquerades to the host's
  own IPv6 route; if the host is IPv4-only there is nothing to NAT to. Check on
  the host with `ip -6 route get 2620:fe::fe`.
- **The host firewall must permit ICMPv6 on the `virbr-migrant` bridge.**
  Neighbor discovery to the VM's ULA gateway is global-scoped, so a firewall
  that accepts ICMPv6 only from `fe80::/10` (a common default) breaks NAT66
  *reply* traffic while egress still works. The qemu hook adds a per-VM INPUT
  accept for exactly the needed ICMPv6 (neighbor discovery, router
  solicit/advert, and PMTUD errors) — echo and everything else stay blocked, so
  the guest cannot ping or otherwise reach the host over IPv6. Keep this rule in
  place if you manage the host firewall out-of-band.
- **Incompatible with WireGuard.** IPv6 is not routed through the tunnel (fwmark
  policy routing is IPv4-only), so `migrant up` refuses to start a VM that sets
  both `NETWORK_IPV6=nat` and a `wireguard.conf`.
