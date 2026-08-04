# Why not Vagrant?

Vagrant is a solid tool, but has some drawbacks for this use case:

|                         | Vagrant + VirtualBox             | migrant + KVM                            |
| ----------------------- | -------------------------------- | ---------------------------------------- |
| Hypervisor              | VirtualBox (userspace)           | KVM (Linux kernel native)                |
| Shared folders          | `vboxsf` via guest kernel module | `virtiofs` via host daemon               |
| Guest→host/LAN network  | Off by default (NAT)             | On by default (iptables)                 |
| Default user privileges | Passwordless sudo (vagrant user) | Configurable via cloud-init              |
| Rebuild speed           | Slow (full image copy)           | Fast (qcow2 backing file, copy-on-write) |
| Dependency footprint    | Vagrant + VirtualBox             | libvirt + QEMU (standard Linux stack)    |
| Config format           | Ruby (Vagrantfile)               | Bash (Migrantfile) + YAML (cloud-init)   |

The most important difference is isolation. VirtualBox shared folders require a
kernel module running inside the guest (`vboxsf`), which increases the attack
surface between the guest and host. `virtiofs` instead uses a daemon on the host
side; the guest interacts with it over a virtio channel without any special
kernel module. `vboxsf` also exposes the shared directory with no size cap and
follows symlinks the guest plants in it, so a malicious guest can exhaust host
disk space or escape the share to read or write files like `~/.ssh` or
`/etc/passwd`. migrant's default shared folder is a fixed-size loop image
mounted with `nosymfollow`, closing off both paths (see
[Shared folder isolation](security/shared-folder-isolation.md)). Combined with
KVM's smaller hypervisor attack surface compared to VirtualBox, this makes
`migrant` a better fit for running untrusted or autonomous workloads.

Network isolation is the other half of that story. Vagrant + VirtualBox's
default NAT networking lets a guest reach the host and the LAN with no firewall
in the way. `migrant` blocks guest-initiated connections to the host and to
private, shared, and link-local address ranges by default (see
[Network isolation](security/network-isolation.md)), so a compromised or
malicious workload can't pivot from the VM onto the host or the local network
unless a `Migrantfile` explicitly opens an exception.
