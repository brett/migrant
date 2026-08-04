# Migrating existing VMs

## Migrating an existing VM to the loop image

If you have an existing VM created before the loop image was introduced (i.e.,
`workspace/` is a plain host directory with no `workspace.img`), `destroy` is
not required. The VM definition is reused as-is:

```bash
# 1. Re-run setup to install the new shared folder hook
migrant setup

# 2. Halt the VM if it is running
migrant halt

# 3. Move workspace contents out
mv workspace/ ~/workspace-backup/

# 4. Start the VM — this creates workspace.img, mounts it, then starts
migrant up

# 5. Copy files into the now-mounted workspace/
cp -a ~/workspace-backup/. workspace/
```

Alternatively, pre-populate the image before starting the VM:

```bash
migrant halt
mv workspace/ ~/workspace-backup/
migrant mount            # creates workspace.img and mounts it
cp -a ~/workspace-backup/. workspace/
migrant unmount
migrant up
```

## Migrating an existing VM to IPv6 (NAT66)

`NETWORK_IPV6=nat` needs the `migrant` network to carry an IPv6 (ULA) subnet.
`migrant setup` only *creates* the network when it is missing, so an existing
install keeps its IPv4-only network and re-running `setup` alone will **not**
add IPv6 — you have to recreate the network once.

Recreating it restarts the shared `virbr-migrant` bridge, which interrupts
**every** VM attached to the `migrant` network, so shut those down first.
`net-destroy` stops the network only — it does not touch any VM's disk or
definition — but a running VM loses connectivity until it is restarted.

```bash
# 1. Halt every VM on the migrant network (repeat per project if you run several)
migrant halt

# 2. Tear down the old IPv4-only network
virsh net-destroy migrant
virsh net-undefine migrant

# 3. Recreate it — now dual-stack — and reinstall the hooks
migrant setup

# 4. Set NETWORK_IPV6=nat in the VM's Migrantfile, then bring it back up
migrant up
```

Then confirm inside the VM that it picked up a ULA and can reach IPv6:

```bash
ip -6 addr show scope global      # expect an fdca:6d16:2b1a::/64 address
curl -6 -sS https://ifconfig.co   # returns an IPv6 address
```

This requires the **host** to have working IPv6 egress
(`ip -6 route get 2620:fe::fe` on the host); NAT66 has nothing to masquerade to
otherwise. `NETWORK_IPV6=nat` is refused on a VM that also has a
`wireguard.conf`.
