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

# Why not Docker?

Plain Docker containers share the host kernel, which is the core problem for
running an untrusted or potentially-compromised coding agent:

|                         | Docker (containers)                                                  | migrant + KVM                            |
| ----------------------- | -------------------------------------------------------------------- | ---------------------------------------- |
| Isolation boundary      | Linux namespaces + cgroups (shared kernel)                           | KVM hypervisor (separate kernel)         |
| Kernel exploits         | Reach the host kernel directly                                       | Contained to the guest kernel            |
| Filesystem sharing      | Bind mount (raw host directory)                                      | `virtiofs`, loop-image-backed by default |
| Guest→host network      | Reachable via the `docker0`/bridge gateway                           | Blocked by default (iptables)            |
| Default user privileges | Root in container = root-equivalent on host (absent user namespaces) | Configurable via cloud-init              |
| Escape impact           | A namespace/cgroup escape lands on the host directly                 | An escape must still cross KVM           |
| Dependency footprint    | Docker Engine                                                        | libvirt + QEMU (standard Linux stack)    |
| Config format           | Dockerfile + `docker run`/Compose YAML                               | Bash (Migrantfile) + YAML (cloud-init)   |

A container is a set of restrictions applied to processes that still run on the
host kernel; a VM is a separate kernel running on virtualized hardware. That
distinction matters most for an agent that can execute arbitrary code: a
container-escape or kernel-exploit bug turns "restricted process on the host"
into "process on the host" with no additional boundary to cross, whereas the
same bug against a `migrant` VM still has to clear the KVM hypervisor. Docker's
default bind mount also shares a raw host directory with the container — no
`nosymfollow`, no size cap — so a malicious workload can plant a symlink that a
host process later follows outside the shared tree, or fill the host disk. And
containers can typically reach the host over the bridge gateway
(`172.17.0.1`-style addresses) without any additional configuration, unlike
`migrant`'s default-deny network isolation.

None of this means Docker is unsuitable for its actual use case — packaging and
running trusted, known workloads with fast startup and low overhead. It means
container isolation was never designed to hold an adversarial or unpredictable
workload, which is exactly the threat model `migrant` targets.

# Why not Docker Sandboxes?

[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) is Docker's own answer
to the "run a coding agent" problem, and it starts from a similar premise: a
container isn't enough isolation for an agent, so give each agent a microVM
instead. The resulting design overlaps with `migrant` in the broad strokes
(VM-per-agent, host-side network enforcement) but differs in scope and
mechanism:

|                        | Docker Sandboxes                                             | migrant + KVM                                  |
| ---------------------- | ------------------------------------------------------------ | ---------------------------------------------- |
| Isolation boundary     | microVM (KVM on Linux)                                       | KVM hypervisor                                 |
| Default network egress | Deny-by-default, host proxy + domain allowlist               | Deny-by-default toward host/LAN; open Internet |
| Filesystem sharing     | Direct passthrough at same path (or read-only via `--clone`) | `virtiofs`, loop-image-backed by default       |
| Credential handling    | Injected into HTTP headers by host proxy; never enters VM    | Whatever guest/cloud-init provides; no proxy   |
| Target workload        | One Docker daemon/agent session per sandbox                  | Any VM workload; not Docker- or agent-specific |
| Runs locally           | Yes, requires Docker account sign-in                         | Yes, no account of any kind                    |
| Dependency footprint   | Docker Sandboxes runtime (`sbx`)                             | libvirt + QEMU (standard Linux stack)          |
| Config format          | `sbx` templates/kits                                         | Bash (Migrantfile) + YAML (cloud-init)         |

The most notable design difference is *what* each tool restricts by default.
Docker Sandboxes' proxy is domain-allowlisted: the agent can reach nothing on
the open Internet except hosts an admin or default policy has approved, all
routed and credential-injected through the host. `migrant`'s network isolation
(see [Network isolation](security/network-isolation.md)) instead blocks the path
back toward the host and the local network — private, shared, and link-local
address ranges — while leaving general Internet egress open unless the operator
layers on their own firewalling or a [WireGuard tunnel](security/wireguard.md).
Docker Sandboxes' model gives tighter control over *what the agent can reach on
the Internet*; `migrant`'s gives tighter control over *the guest's ability to
pivot toward the host or LAN*, which is the direction of attack this project's
threat model is built around.

The other practical differences follow from Docker Sandboxes being a product
rather than a script: the `sbx` CLI runs the microVM locally, but requires
signing in with a Docker account, and defaults to sharing the workspace at the
same absolute path as the host (an explicit `--clone` mode is needed for a
read-only, in-VM copy). `migrant` is a single self-contained script with no
account of any kind, and its shared folder is isolated (loop image,
`nosymfollow`, size cap) by default rather than as an opt-in mode.
