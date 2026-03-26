# migrant.sh

A lightweight, Vagrant-like VM management tool for Linux, built on
**libvirt + QEMU/KVM**. Define a VM in a `Migrantfile` file, drop a
`cloud-init.yml` alongside it, and use a single script to create, start,
stop, and destroy virtual machines — each with its own kernel, isolated
from the host.

Designed as a replacement for Vagrant when running ephemeral agent VMs
(e.g. [Claude Code](https://docs.anthropic.com/en/docs/claude-code)) on
Linux hosts.

---

## LLM Warning

The script itself (and all of the README other than this section) was [written
by an isolated Claude Code
agent](https://en.wikipedia.org/wiki/Eating_your_own_dog_food), but I would not
call it, as The Kids say, "vibe-coded". Design decisions were made by me (a
[real human being](https://www.youtube.com/watch?v=-DSVDcw6iW8)). I am
hyper-critical of Claude's shell scripting abilities. I read and question
every line, often redirecting it down another path.

---

## Why not Vagrant?

Vagrant is a solid tool, but has some drawbacks for this use case:

|                         | Vagrant + VirtualBox             | migrant.sh + KVM                         |
| ----------------------- | -------------------------------- | ---------------------------------------- |
| Hypervisor              | VirtualBox (userspace)           | KVM (Linux kernel native)                |
| Shared folders          | `vboxsf` via guest kernel module | `virtiofs` via host daemon               |
| Default user privileges | Passwordless sudo (vagrant user) | Configurable via cloud-init              |
| Rebuild speed           | Slow (full image copy)           | Fast (qcow2 backing file, copy-on-write) |
| Dependency footprint    | Vagrant + VirtualBox             | libvirt + QEMU (standard Linux stack)    |
| Config format           | Ruby (Vagrantfile)               | Bash (Migrantfile) + YAML (cloud-init)   |

The most important difference is isolation. VirtualBox shared folders
require a kernel module running inside the guest (`vboxsf`), which
increases the attack surface between the guest and host. `virtiofs`
instead uses a daemon on the host side; the guest interacts with it over
a virtio channel without any special kernel module. Combined with KVM's
smaller hypervisor attack surface compared to VirtualBox, this makes
`migrant.sh` a better fit for running untrusted or autonomous workloads.

---

## How it works

Each project directory contains these files:

- **`Migrantfile`** — a sourced bash file declaring VM name, resources,
  image, and shared folders
- **`cloud-init.yml`** — a standard
  [cloud-init](https://cloudinit.readthedocs.io/) user-data file that
  handles first-boot system setup: creating users, configuring SSH keys,
  and mounting shared folders
- **`playbook.yml`** (optional) — an [Ansible](https://docs.ansible.com/)
  playbook for ongoing configuration management: installing packages,
  deploying dotfiles, and anything that may change over the VM's lifetime

The `migrant.sh` script lives in your `PATH` and reads these files from
the current directory by default, just like `vagrant` reads a `Vagrantfile`.
Alternatively, set the `MIGRANT_DIR` environment variable to point at the
project directory and run `migrant.sh` from anywhere (see [MIGRANT_DIR](#migrant_dir)).

On first `migrant.sh up`, the script:

1. Downloads the base cloud image (once, cached in `/var/lib/libvirt/images/`)
2. Creates a qcow2 disk using the base image as a backing file
   (copy-on-write — fast, no full copy)
3. Packages your `cloud-init.yml` into a seed ISO
4. Calls `virt-install` to define and start the VM
5. cloud-init runs inside the VM on first boot to create users, configure
   SSH keys, and mount shared folders
6. If `playbook.yml` is present, waits for cloud-init to finish, then runs
   `ansible-playbook` to complete provisioning; `up` blocks until done and
   the VM is fully ready when it returns

On subsequent `migrant.sh up` calls, the VM already exists so the script
simply starts it with `virsh start`.

Destroying the VM with `migrant.sh destroy` removes the libvirt domain
and deletes the VM's disk, seed ISO, and any snapshot, leaving the
cached base image intact so the next `migrant.sh up` is fast.

---

## Installation (Arch Linux)

### Prerequisites: verify KVM support

`migrant.sh` relies on KVM hardware acceleration. Without it, VMs are
created via software emulation and are impractically slow. Verify that
your CPU supports virtualization and that it is enabled in BIOS before
continuing:

```bash
lscpu | grep Virtualization
ls /dev/kvm
```

`lscpu` should show `VT-x` (Intel) or `AMD-V` (AMD). `/dev/kvm` should
exist. If either is missing, enter your BIOS/UEFI settings and enable
Intel VT-x / AMD-V (sometimes labelled "Virtualization Technology" or
"SVM Mode").

### 1. Install dependencies

```bash
sudo pacman -S qemu-base libvirt virt-install dnsmasq xorriso
```

`dnsmasq` must be installed so libvirt can use its binary for guest
DHCP/DNS, but do not enable the dnsmasq systemd service — libvirt
manages its own dnsmasq process internally.

If you plan to use Ansible provisioning (`playbook.yml`), also install:

```bash
sudo pacman -S ansible
```

Ansible runs on the host and connects to the VM over SSH. An SSH key must
be configured in `cloud-init.yml` (see [Managed SSH key](#managed-ssh-key-recommended))
before running Ansible.

### 2. Install migrant.sh

```bash
cp migrant.sh ~/bin/migrant.sh
chmod +x ~/bin/migrant.sh
```

Make sure `~/bin` is in your `PATH`. Add this to your `~/.bashrc` or
`~/.zshrc` if needed:

```bash
export PATH="$PATH:$HOME/bin"
```

### 3. Run one-time host setup

```bash
migrant.sh setup
```

This performs all remaining configuration automatically:

- **KVM check**: warns if `/dev/kvm` is not available
- **libvirtd**: enables and starts `libvirtd.socket` and `virtlogd.socket` for
  on-demand socket activation (libvirtd starts when first needed, not at boot)
- **libvirt group**: adds the current user to the `libvirt` group (log out
  and back in, or run `newgrp libvirt`, for this to take effect)
- **Firewall backend**: detects whether the host uses legacy iptables or
  nftables and configures `/etc/libvirt/network.conf` accordingly — the
  backend must match, or VMs will boot but get no DHCP lease
- **Default network**: creates and starts the `default` NAT network
  (`virbr0`, 192.168.122.0/24) if it does not already exist
- **Images directory**: creates `/var/lib/libvirt/images/` if it does not
  exist, and grants the `libvirt` group write access so VM disks can be
  created without `sudo`
- **VM firewall hook** (`/etc/libvirt/hooks/qemu.d/migrant`): adds iptables rules
  when a VM with `NETWORK_ISOLATION=true` starts, blocking it from
  initiating new connections to the host and from reaching other hosts on
  the local network; removes the rules when the VM stops
- **rp_filter hook** (`/etc/libvirt/hooks/network.d/migrant`): sets `rp_filter=0`
  on `virbr0` when the default network starts; only installed if
  `net.ipv4.conf.default.rp_filter` is non-zero (the case on the
  `linux-hardened` kernel, where the default causes DHCP to fail)

`setup` is idempotent — it can be re-run to update the hooks after
upgrading migrant.sh.

#### Firewall caveats

If you run an **nftables firewall** (`nftables.service` active with a
custom ruleset), be aware of two issues with standard Arch example
configurations:

- The Workstation and Server example configs both include a `forward`
  chain with `policy drop`. This drops all packets routed between
  interfaces, blocking VM traffic on `virbr0`. Any nftables config
  must either omit the `forward` chain or add explicit accept rules
  for `virbr0` traffic.

- Both example configs start with `flush ruleset`. Reloading
  `nftables.service` will wipe libvirt's rules until libvirt restarts.
  Avoid reloading nftables while VMs are running, or use the
  [atomic reload](https://wiki.archlinux.org/title/Nftables#Atomic_reloading)
  technique to prepend libvirt's rules to your config.

If you also run **Docker on the host**, Docker and libvirt both modify
firewall rules at startup. If they use the same backend, reloading
either service can disrupt the other's networking. The Arch nftables
wiki recommends running Docker in a separate network namespace to avoid
this conflict. See the
[Working with Docker](https://wiki.archlinux.org/title/Nftables#Working_with_Docker)
section for the drop-in configuration.

---

## Example: Claude Code agent VM

The `claude/` subdirectory contains a ready-to-use example for running
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) in an
isolated VM. It uses both provisioning methods:

- **`cloud-init.yml`** handles system bootstrap: creating the `agent` user,
  configuring SSH, and mounting the shared folder
- **`playbook.yml`** handles software setup: installing packages, claude-code,
  uv, and bash aliases

The `cloud-init.yml` also contains the equivalent cloud-init-only setup
commented out, as a reference for using either approach.

First, generate or print the managed SSH key (required for Ansible provisioning):

```bash
cd claude
migrant.sh pubkey    # generates ~/.ssh/migrant if needed; prints the public key
```

Paste the output into `cloud-init.yml` under `ssh_authorized_keys`, then:

```bash
migrant.sh up        # creates VM, runs cloud-init + Ansible; blocks until ready
migrant.sh ssh
```

---

## Usage

Run commands from the project directory containing `Migrantfile`, or set
`MIGRANT_DIR` to run from anywhere (see [MIGRANT_DIR](#migrant_dir)).

```bash
migrant.sh setup              # One-time host setup: configures libvirt networking and installs firewall hooks
migrant.sh up                 # Create or start the VM; runs Ansible on first create; waits until ready
migrant.sh halt               # Gracefully shut down the VM
migrant.sh destroy            # Stop and permanently delete the VM, its disk, and any snapshots
migrant.sh provision          # Run the Ansible playbook (playbook.yml) against the running VM
migrant.sh snapshot           # Shut down the VM and save a snapshot of its disk; VM stays down afterward
migrant.sh reset              # Destroy the VM and rebuild it from the last snapshot
migrant.sh status             # Show the VM's current state and snapshot availability
migrant.sh ssh                # SSH into the VM as the configured user
migrant.sh ssh -- <cmd>       # Run a command over SSH without an interactive shell
migrant.sh console            # Open a serial console session (exit with Ctrl+])
migrant.sh ip                 # Print the VM's IP address
migrant.sh pubkey             # Print the managed SSH public key (requires MANAGED_SSH_KEY=true)
migrant.sh storage            # List IMAGES_DIR contents grouped by base images and VMs, with file sizes; works without a Migrantfile
```

### Typical workflow

```bash
# First time
cd ~/my-agent-vm
migrant.sh up          # creates VM, runs cloud-init + Ansible; blocks until ready
migrant.sh ssh         # connect and do any manual one-time setup (e.g. auth)
migrant.sh snapshot    # save this known-good state

# Day-to-day
migrant.sh up       # start
migrant.sh halt     # stop when done

# Restore to snapshot
migrant.sh reset    # wipe and rebuild from snapshot; Ansible does not re-run
                    # (the snapshot already contains its output)

# Update provisioning after changing playbook.yml
migrant.sh up
migrant.sh provision   # re-run the Ansible playbook; VM stays running

# Start completely fresh
migrant.sh destroy
migrant.sh up
```

### MIGRANT_DIR

Set `MIGRANT_DIR` to the path of a project directory to run any command
without `cd`-ing into it first:

```bash
MIGRANT_DIR=~/migrant/claude migrant.sh up
MIGRANT_DIR=~/migrant/claude migrant.sh halt
```

The typical use is to define a shell alias:

```bash
alias cm="MIGRANT_DIR=$HOME/migrant/claude migrant.sh"
```

After which you can manage the VM from anywhere:

```bash
cm up
cm halt
cm ssh
```

Note: use `$HOME` rather than `~` when defining the alias, since `~` inside
quotes is not expanded by the shell and would be passed to the script
literally.

Shared folder paths in `Migrantfile` that do not begin with `/` are always
resolved relative to the `Migrantfile`'s directory, regardless of where
`migrant.sh` is invoked from.

### Waiting for the VM to be ready

`migrant.sh up` blocks until the VM obtains a DHCP lease rather than
returning immediately after the VM starts. If the VM stops running
while waiting (e.g. due to a crash or misconfiguration), `up` exits
with an error rather than waiting indefinitely.

Note that a DHCP lease signals that the network stack is up, not that
cloud-init has finished provisioning. On a first boot, packages may
still be installing when `up` returns.

### Serial console vs SSH

`migrant.sh console` opens a serial console via `virsh console`. This is
not SSH — it connects directly to the VM's serial port, like a physical
terminal. To exit the console, press `Ctrl+]`.

To log in via the console, the user defined in `cloud-init.yml` must
have a password set. cloud-init locks passwords by default for users
defined in the `users:` list. Add `lock_passwd: false` and either a
plaintext or hashed password to enable console login:

```yaml
users:
  - name: agent
    lock_passwd: false
    plain_text_passwd: "yourpassword"
```

For production use, prefer a pre-hashed password (generated with
`openssl passwd -6`) so the plaintext never appears in the config file:

```yaml
users:
  - name: agent
    lock_passwd: false
    passwd: "$6$..."   # openssl passwd -6 yourpassword
```

`migrant.sh ssh` looks up the VM's IP address and SSHes in as the first
user defined in `cloud-init.yml`.

Host key verification is disabled (`StrictHostKeyChecking=no`,
`UserKnownHostsFile=/dev/null`) because these VMs are ephemeral —
rebuilding a VM generates a new host key at the same IP, which would
cause a standard SSH client to refuse the connection.

#### Managed SSH key (recommended)

Setting `MANAGED_SSH_KEY=true` in `Migrantfile` tells migrant.sh to
manage a dedicated passphrase-less SSH key at `~/.ssh/migrant`. The key
is shared across all VMs that have this option enabled. On first use,
the key is generated automatically.

First-time setup:

```bash
migrant.sh pubkey    # generates the key if needed; prints the public key
```

Paste the output into `cloud-init.yml` under `ssh_authorized_keys`, then
create the VM:

```yaml
users:
  - name: agent
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... migrant
```

```bash
migrant.sh up
migrant.sh ssh       # uses ~/.ssh/migrant automatically
```

Only the managed key is offered to the server (`IdentitiesOnly=yes`) —
keys from the SSH agent and default identity files are not tried.

#### Manual key management

Without `MANAGED_SSH_KEY=true`, migrant.sh expects you to have added
your own public key to `cloud-init.yml` and will error if
`ssh_authorized_keys` is absent. SSH will use whichever keys are
available in your agent or default identity files:

```yaml
users:
  - name: agent
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... you@host
```

#### Remote commands

Arguments after `--` are passed through as a remote command:

```bash
migrant.sh ssh -- sudo cloud-init status --wait
migrant.sh ssh -- sudo tail -f /var/log/cloud-init-output.log
```

`migrant.sh ip` prints the VM's IP address, which is useful for
scripting or for connecting with tools other than SSH.

### storage

`migrant.sh storage` can be run from any directory, with or without a
`Migrantfile`. It lists everything in `IMAGES_DIR`, grouped by category:

```
$ migrant.sh storage
Directory: /var/lib/libvirt/images (4.7G)
Base Images:
    ubuntu-25.10-server-cloudimg-amd64.img (785M)
VMs:
    claude (4.1G):
        Disk:     claude.qcow2 (1.1G)
        Seed ISO: claude-seed.iso (372K)
        Snapshot: claude-snapshot.qcow2 (3.0G)
    old-vm (900M) (destroyed):
        Disk:     old-vm.qcow2 (528M)
        Seed ISO: old-vm-seed.iso (372K)
Other:
    someone-elses-vm.qcow2 (2.0G)
```

`(destroyed)` means the VM's files are still on disk but the VM no longer
exists in libvirt. `migrant.sh destroy` removes both the libvirt domain and
its image files, so this should not normally occur — it typically means the
VM was undefined directly with `virsh undefine`, or the files were left
behind after some other manual intervention. They are safe to remove.

Files in the **Other** category are not managed by migrant.sh — they may
belong to VMs defined outside of migrant.sh, or be leftover files from
other tools.

---

## Disk images and caching

All VM-related files are stored in `/var/lib/libvirt/images/`:

| File       | Example                                  | Purpose                                              |
| ---------- | ---------------------------------------- | ---------------------------------------------------- |
| Base image | `ubuntu-25.10-server-cloudimg-amd64.img` | Shared read-only backing file; downloaded once       |
| VM disk    | `claude.qcow2`                           | Per-VM qcow2 overlay (copy-on-write over base image) |
| Seed ISO   | `claude-seed.iso`                        | cloud-init data for first-boot provisioning          |
| Snapshot   | `claude-snapshot.qcow2`                  | Flattened disk image saved by `migrant.sh snapshot`  |

The qcow2 overlay means:

- Creating a VM is fast — only changed blocks are written to the VM's
  own disk
- The base image is never modified
- Multiple VMs can share the same base image simultaneously
- `migrant.sh destroy` deletes the VM's disk, seed ISO, and snapshot;
  the base image remains
- `migrant.sh reset` also deletes the disk and seed ISO but preserves
  the snapshot, then calls `up` to rebuild from it

To free the base image:

```bash
rm /var/lib/libvirt/images/ubuntu-25.10-server-cloudimg-amd64.img
```

It will be re-downloaded next time a VM using that image is created.

---

## Security notes

The isolation guarantee in this setup comes from the KVM hypervisor
boundary, not from Linux user permissions inside the guest. The guest
`agent` user having passwordless sudo is acceptable because:

- Privilege escalation inside the guest cannot cross the KVM boundary
- The VM is ephemeral and designed to be destroyed and rebuilt
- The shared folder is served by `virtiofsd` on the host side — the
  guest cannot influence the host filesystem beyond the shared directory

### Network isolation

Setting `NETWORK_ISOLATION=true` in a `Migrantfile` enables additional
network restrictions for that VM. When the VM starts, iptables rules are
added that:

- Block the VM from initiating new connections to the host (DNS and DHCP
  responses from the host are still delivered, as those are tracked as
  existing connections)
- Block the VM from reaching RFC 1918 addresses on the local network,
  other than the libvirt subnet itself (192.168.122.0/24)

The rules are removed automatically when the VM stops or is destroyed.
This requires `migrant.sh setup` to have been run to install the libvirt
hook.

That said, the shared folder is a real path on your host machine. Be
aware that anything the agent writes to `/home/agent/workspace` inside
the VM (the mount point in the example configuration) lands on your
host disk. Scope the shared folder to only what the agent needs.
