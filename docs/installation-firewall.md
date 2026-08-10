# Firewall caveats

If you run an **nftables firewall** (`nftables.service` active with a custom
ruleset), be aware of two issues with standard Arch example configurations:

- The Workstation and Server example configs both include a `forward` chain with
  `policy drop`. This drops all packets routed between interfaces, blocking VM
  traffic on `virbr-migrant`. Any nftables config must either omit the `forward`
  chain or add explicit accept rules for `virbr-migrant` traffic.

- Both example configs start with `flush ruleset`. Reloading `nftables.service`
  will wipe libvirt's rules until libvirt restarts. Avoid reloading nftables
  while VMs are running, or use the
  [atomic reload](https://wiki.archlinux.org/title/Nftables#Atomic_reloading)
  technique to prepend libvirt's rules to your config.

If you also run **Docker on the host**, Docker and libvirt both modify firewall
rules at startup. If they use the same backend, reloading either service can
disrupt the other's networking. The Arch nftables wiki recommends running Docker
in a separate network namespace to avoid this conflict. See the
[Working with Docker](https://wiki.archlinux.org/title/Nftables#Working_with_Docker)
section for the drop-in configuration.
