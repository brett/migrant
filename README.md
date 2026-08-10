# migrant

A lightweight, Vagrant-like VM management tool for Linux, built on **libvirt +
QEMU/KVM**. Define a VM in a `Migrantfile` file, drop a `cloud-init.yml`
alongside it, and use a single script to create, start, stop, and destroy
virtual machines — each with its own kernel, isolated from the host.

Designed as a replacement for Vagrant when running ephemeral agent VMs (e.g.
[Claude Code](https://docs.anthropic.com/en/docs/claude-code)) on Linux hosts.

---

## LLM Warning

The script itself (and all of the README other than this section) was
[written by an isolated Claude Code agent](https://en.wikipedia.org/wiki/Eating_your_own_dog_food),
but I would not call it, as The Kids say, "vibe-coded". Design decisions were
made by me (a [real human being](https://www.youtube.com/watch?v=-DSVDcw6iW8)).
I am hyper-critical of Claude's shell scripting abilities. I read and question
every line, often redirecting it down another path.

---

## Why not Vagrant?

The most important difference is isolation. `migrant` offers shared folder and
networking isolation that is superior to VirtualBox. Combined with KVM's smaller
hypervisor attack surface, this makes `migrant` a better fit for running
untrusted or autonomous workloads.

See [docs/comparison.md](docs/comparison.md) for the full comparison, including
Docker and Docker Sandboxes.

---

## How it works

Each project directory contains these files:

- **`Migrantfile`** — a sourced bash file declaring VM name, resources, image,
  and shared folders
- **`cloud-init.yml`** — a standard
  [cloud-init](https://cloudinit.readthedocs.io/) user-data file that handles
  first-boot system setup: creating users, configuring SSH keys, and mounting
  shared folders
- **`playbook.yml`** (optional) — an [Ansible](https://docs.ansible.com/)
  playbook for ongoing configuration management: installing packages, deploying
  dotfiles, and anything that may change over the VM's lifetime

The `migrant` script lives in your `PATH` and reads these files from the current
directory by default, just like `vagrant` reads a `Vagrantfile`. Alternatively,
set the `MIGRANT_DIR` environment variable to point at the project directory and
run `migrant` from anywhere (see [docs/usage.md](docs/usage.md#migrant_dir)).

See [docs/architecture.md](docs/architecture.md) for what happens under the hood
on `up`/`destroy`, and how disk images are cached.

---

## Installation (Arch Linux)

### Prerequisites: verify KVM support

`migrant` relies on KVM hardware acceleration. Without it, VMs are created via
software emulation and are impractically slow. Verify that your CPU supports
virtualization and that it is enabled in BIOS before continuing:

```bash
lscpu | grep Virtualization
ls /dev/kvm
```

`lscpu` should show `VT-x` (Intel) or `AMD-V` (AMD). `/dev/kvm` should exist. If
either is missing, enter your BIOS/UEFI settings and enable Intel VT-x / AMD-V
(sometimes labelled "Virtualization Technology" or "SVM Mode").

### 1. Install dependencies

```bash
sudo pacman -S qemu-base libvirt virt-install dnsmasq libisoburn
```

`dnsmasq` must be installed so libvirt can use its binary for guest DHCP/DNS,
but do not enable the dnsmasq systemd service — libvirt manages its own dnsmasq
process internally.

If you plan to use Ansible provisioning (`playbook.yml`), also install:

```bash
sudo pacman -S ansible
```

Ansible runs on the host and connects to the VM over SSH. An SSH key must be
configured in `cloud-init.yml` (see
[Managed SSH key](docs/usage.md#managed-ssh-key-recommended)) before running
Ansible.

### 2. Install migrant

```bash
ln -s ~/src/migrant/migrant ~/bin/migrant
```

`cmd_setup` reads its installer assets (libvirt hooks, network definition, zsh
completion) from a `setup/` directory next to `migrant`'s real file — symlinking
instead of copying is what lets `migrant setup` find `setup/` automatically. If
you'd rather copy `migrant` standalone, set
`MIGRANT_SETUP_DIR=~/src/migrant/setup` before running `migrant setup`.

Make sure `~/bin` is in your `PATH`. Add this to your `~/.bashrc` or `~/.zshrc`
if needed:

```bash
export PATH="$PATH:$HOME/bin"
```

### 3. Run one-time host setup

```bash
migrant setup
```

This configures everything needed to use migrant: enables the libvirtd and
virtlogd sockets, adds your user to the `libvirt` group, detects the host
firewall backend (iptables or nftables) and updates `/etc/libvirt/network.conf`
to match, defines the `migrant` NAT network, creates the images directory
(`/var/lib/libvirt/images`, or `LIBVIRT_IMAGES_DIR` if set) with group-writable
permissions, installs libvirt hooks (network isolation and WireGuard tunnel
management, shared folder loop image mount/unmount, and `rp_filter` for the
`linux-hardened` kernel), loads `br_netfilter` and sets the
`bridge-nf-call-ip*tables` sysctls that the isolation rules depend on —
persisting both — creates `/etc/migrant/` for managed VM configs, and installs
ZSH completions if the destination directory (`/usr/share/zsh/site-functions`,
or `MIGRANT_ZSH_SITE_FUNCTIONS` if set) exists.

If your user was not already in the `libvirt` group, setup will add it and then
fail — the group change is not live in the current session. Log out and back in
(or run `newgrp libvirt`) and re-run `migrant setup` to complete the remaining
steps.

`setup` is idempotent — re-run it after upgrading migrant to update the hooks.

#### Firewall caveats

If you run an nftables firewall or Docker alongside libvirt, there are a couple
of gotchas to know about — see
[docs/installation-firewall.md](docs/installation-firewall.md).

---

## Example: Claude Code agent VMs

The `examples/` subdirectory contains ready-to-use examples for running
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) in an isolated VM
on Arch Linux, Ubuntu, and Debian Trixie. They use both provisioning methods:

- **`cloud-init.yml`** handles system bootstrap: creating the `migrant` user,
  configuring SSH, and mounting the shared folder
- **`playbook.yml`** handles software setup: installing packages, claude-code,
  uv, and bash aliases

The `cloud-init.yml` also contains the equivalent cloud-init-only setup
commented out, as a reference for using either approach.

First, generate the managed SSH key and add it to `cloud-init.yml` (required for
Ansible provisioning):

```bash
cd examples/ubuntu
migrant pubkey    # generates ~/.ssh/migrant if needed; prints the public key
```

Paste the output into `cloud-init.yml` under `ssh_authorized_keys`. The comment
must remain `migrant` so migrant recognises it. Then:

```bash
migrant up        # creates VM, runs cloud-init + Ansible; blocks until ready
migrant ssh
```

---

## Usage

Run commands from the project directory containing `Migrantfile`, or set
`MIGRANT_DIR` to run from anywhere (see
[MIGRANT_DIR](docs/usage.md#migrant_dir)).

```bash
# Setup
migrant setup              # One-time host setup: configures libvirt networking and installs firewall hooks

# Lifecycle
migrant up                 # Create the VM if it does not exist, or start it if stopped; runs Ansible provisioning (if playbook.yml exists) on first create; waits until the VM is fully ready; connects automatically if AUTOCONNECT is set in the Migrantfile
migrant halt               # Gracefully shut down the VM
migrant destroy            # Stop and permanently delete the VM, its disk, and any snapshots
migrant status             # Show the VM's current state and snapshot availability
migrant provision          # Run the Ansible playbook (playbook.yml) against the running VM
migrant snapshot           # Shut down the VM and save a snapshot of its disk; VM stays down afterward
migrant reset              # Destroy the VM and rebuild it from the last snapshot
migrant resize             # Grow the VM's disk to match DISK_GB in the Migrantfile; requires the VM to be running

# Shared folder
migrant mount              # Mount the shared folder loop image for host-side access; creates the image if it does not exist
migrant unmount            # Unmount the shared folder loop image

# Access
migrant ssh [-- cmd...]    # SSH into the VM as the configured user; optionally run a remote command (e.g. migrant ssh -- sudo cloud-init status)
migrant tunnel [PORT...]   # Open SSH local-forwards from host to VM. Without args, uses TUNNEL_PORTS from Migrantfile.
migrant console            # Open a serial console session (exit with Ctrl+])
migrant ip [-6]            # Print the VM's IPv4 address (what SSH uses). With -6, print the IPv6 (ULA) address when NETWORK_IPV6=nat is set
migrant pubkey             # Generate the managed SSH key if needed and print its public key
migrant tz [zone]          # Sync the host timezone to the VM, or set an explicit zone (e.g. America/New_York); defaults to the host timezone

# Diagnostics
migrant storage            # List IMAGES_DIR contents grouped by base images and VMs, with file sizes; works without a Migrantfile
migrant wg                 # Show live WireGuard interface status, including transfer stats and latest handshake; requires sudo
migrant dominfo            # Show detailed libvirt domain info for the VM
```

### Typical workflow

```bash
# First time
cd ~/my-agent-vm
migrant up          # creates VM, runs cloud-init + Ansible; blocks until ready
migrant ssh         # connect and do any manual one-time setup (e.g. auth)
migrant snapshot    # save this known-good state

# Day-to-day
migrant up       # start
migrant halt     # stop when done

# Restore to snapshot
migrant reset    # wipe and rebuild from snapshot; Ansible does not re-run

# Update provisioning after changing playbook.yml
migrant up
migrant provision   # re-run the Ansible playbook; VM stays running

# Start completely fresh
migrant destroy
migrant up
```

---

## Documentation

Further detail lives in [docs/](docs/):

- [docs/comparison.md](docs/comparison.md) — Why not Vagrant, Docker, or Docker
  Sandboxes?
- [docs/architecture.md](docs/architecture.md) — How `migrant up`/`destroy`
  work, disk image caching, firmware (BIOS vs UEFI)
- [docs/usage.md](docs/usage.md) — `MIGRANT_DIR`, waiting-for-ready semantics,
  network lifecycle, SSH key management, port tunneling, `storage`
- [docs/resize.md](docs/resize.md) — Growing the VM's disk with `migrant resize`
- [docs/hooks.md](docs/hooks.md) — Lifecycle hooks (`pre-up`, `post-up`,
  `pre-down`, `post-down`)
- [docs/migrating.md](docs/migrating.md) — Migrating existing VMs to the loop
  image or to IPv6 (NAT66)
- [docs/installation-firewall.md](docs/installation-firewall.md) — nftables and
  Docker firewall caveats
- [docs/security/README.md](docs/security/README.md) — Security model overview
  - [docs/security/network-isolation.md](docs/security/network-isolation.md) —
    Default network isolation and `HOST_ACCESS` rules
  - [docs/security/ipv6-nat66.md](docs/security/ipv6-nat66.md) — Opt-in IPv6
    (NAT66) egress
  - [docs/security/wireguard.md](docs/security/wireguard.md) — Routing VM
    traffic through a WireGuard VPN
  - [docs/security/shared-folder-isolation.md](docs/security/shared-folder-isolation.md)
    — Loop-image-backed shared folder
