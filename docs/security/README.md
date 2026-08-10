# Security model

The isolation guarantee in this setup comes from the KVM hypervisor boundary,
not from Linux user permissions inside the guest. The guest `migrant` user
having passwordless sudo is acceptable because:

- Privilege escalation inside the guest cannot cross the KVM boundary
- The VM is ephemeral and designed to be destroyed and rebuilt
- The shared folder is served by `virtiofsd` on the host side — the guest cannot
  influence the host filesystem beyond the shared directory

See also:

- [Network isolation](network-isolation.md) — blocks the VM from reaching the
  host or LAN by default, and the `HOST_ACCESS` rules that punch targeted
  exceptions in it
- [IPv6 (NAT66)](ipv6-nat66.md) — opt-in IPv6 egress
- [WireGuard VPN tunnel](wireguard.md) — routing all VM traffic through a VPN,
  enforced host-side
- [Shared folder isolation](shared-folder-isolation.md) — the loop-image-backed
  shared folder and the protections it provides
