# Why not Vagrant?

Vagrant is a solid tool, but has some drawbacks for this use case:

|                         | Vagrant + VirtualBox             | migrant + KVM                            |
| ----------------------- | -------------------------------- | ---------------------------------------- |
| Hypervisor              | VirtualBox (userspace)           | KVM (Linux kernel native)                |
| Shared folders          | `vboxsf` via guest kernel module | `virtiofs` via host daemon               |
| Default user privileges | Passwordless sudo (vagrant user) | Configurable via cloud-init              |
| Rebuild speed           | Slow (full image copy)           | Fast (qcow2 backing file, copy-on-write) |
| Dependency footprint    | Vagrant + VirtualBox             | libvirt + QEMU (standard Linux stack)    |
| Config format           | Ruby (Vagrantfile)               | Bash (Migrantfile) + YAML (cloud-init)   |

The most important difference is isolation. VirtualBox shared folders require a
kernel module running inside the guest (`vboxsf`), which increases the attack
surface between the guest and host. `virtiofs` instead uses a daemon on the host
side; the guest interacts with it over a virtio channel without any special
kernel module. Combined with KVM's smaller hypervisor attack surface compared to
VirtualBox, this makes `migrant` a better fit for running untrusted or
autonomous workloads.
