# TODO

## Network lifecycle management

Currently `setup` starts the default libvirt network and enables autostart, so
it runs permanently. Consider instead: removing autostart from `setup`, and
having `up` start the network if it is not already running. This would mean the
network is not running at boot and only comes up when a VM is needed.

Stopping the network on `halt`/`destroy` is riskier — migrant.sh would need to
confirm no other VMs (including non-migrant ones) are still using it before
bringing the network down. The simplest safe heuristic is to stop the network
only if `virsh list` returns no running domains, but this is a blunt instrument.
Given that the default network is cheap (one bridge interface and a dnsmasq
process), it may not be worth the added complexity to stop it proactively.

## Shared folder security

Two unresolved attack vectors from a malicious guest:

**Symlink traversal** — the guest can create symlinks inside the shared folder
pointing to arbitrary host paths (e.g. `~/.ssh`, `/etc/passwd`). The host
process accessing those symlinks (`virtiofsd`) may follow them, giving the
guest read or write access to paths outside the shared directory. Possible
mitigations to explore:
- `virtiofsd` sandboxing options — check whether current versions of
  `virtiofsd` have a `--no-follow-symlinks` flag or equivalent, and whether
  the `--sandbox` mode restricts symlink traversal to within the shared root
- Mount the shared folder on a dedicated filesystem (e.g. a fixed-size ext4
  image) on the host side and point virtiofsd at that, rather than pointing it
  at a plain host directory — this would also address the disk-fill issue below

**Disk exhaustion** — the guest can fill the host disk by writing large files
into the shared folder (or into the qcow2 overlay, which also grows on the
host). Possible mitigations to explore:
- Use a fixed-size ext4 or btrfs image file as the shared folder backing store;
  virtiofsd serves the mounted image rather than a host directory — the guest
  cannot write beyond the image size
- Set a qcow2 disk size cap (already done via `DISK_GB`) and verify that
  `qemu-img` enforces it as a hard limit rather than a soft advisory
- Explore whether `virtiofsd` or the host kernel supports per-share quota
  enforcement
