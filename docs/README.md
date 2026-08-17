# Documentation

Extended documentation for `migrant`. Start with the main [README](../README.md)
for installation and basic usage; the pages here go deeper on specific topics.

- [comparison.md](comparison.md) — Why not Vagrant?
- [architecture.md](architecture.md) — How `migrant up`/`destroy` work, disk
  image caching, firmware (BIOS vs UEFI)
- [usage.md](usage.md) — `MIGRANT_DIR`, waiting-for-ready semantics, network
  lifecycle, SSH key management, port tunneling, `storage`
- [resize.md](resize.md) — Growing the VM's disk with `migrant resize`; changing
  RAM and vCPUs by rebuilding
- [hooks.md](hooks.md) — Lifecycle hooks (`pre-up`, `post-up`, `pre-down`,
  `post-down`)
- [migrating.md](migrating.md) — Migrating existing VMs to the loop image or to
  IPv6 (NAT66)
- [installation-firewall.md](installation-firewall.md) — nftables and Docker
  firewall caveats
- [security/README.md](security/README.md) — Security model overview
  - [security/network-isolation.md](security/network-isolation.md) — Default
    network isolation and `HOST_ACCESS` rules
  - [security/ipv6-nat66.md](security/ipv6-nat66.md) — Opt-in IPv6 (NAT66)
    egress
  - [security/wireguard.md](security/wireguard.md) — Routing VM traffic through
    a WireGuard VPN
  - [security/shared-folder-isolation.md](security/shared-folder-isolation.md) —
    Loop-image-backed shared folder
