# Usage

See the main [README](../README.md#usage) for the full command reference and
typical workflow. This page covers the details behind specific commands and
options.

## MIGRANT_DIR

Set `MIGRANT_DIR` to the path of a project directory to run any command without
`cd`-ing into it first:

```bash
MIGRANT_DIR=~/migrant/ubuntu migrant up
MIGRANT_DIR=~/migrant/ubuntu migrant halt
```

The typical use is to define a shell alias:

```bash
alias mig-a="MIGRANT_DIR=$HOME/migrant/examples/arch migrant"
alias mig-d="MIGRANT_DIR=$HOME/migrant/examples/debian migrant"
alias mig-u="MIGRANT_DIR=$HOME/migrant/examples/ubuntu migrant"
```

After which you can manage the VM from anywhere:

```bash
mig-u up
mig-u halt
mig-u ssh
```

Note: use `$HOME` rather than `~` when defining the alias, since `~` inside
quotes is not expanded by the shell and would be passed to the script literally.

Shared folder paths in `Migrantfile` that do not begin with `/` are always
resolved relative to the `Migrantfile`'s directory, regardless of where
`migrant` is invoked from.

## Waiting for the VM to be ready

`migrant up` blocks until the VM obtains a DHCP lease. Setting
`AUTOCONNECT=console` skips this wait and attaches the console immediately after
the VM starts — except when creating the VM for the first time (not from a
snapshot) with a `playbook.yml` present, where the normal wait still applies so
Ansible provisioning can run first. If the VM stops running while waiting (e.g.
due to a crash or misconfiguration), `up` exits with an error rather than
waiting indefinitely.

If SSH is configured in `cloud-init.yml` (`ssh_authorized_keys` present), `up`
additionally waits until SSH is available before returning. This applies both
when starting a stopped VM and when creating one with `playbook.yml`.

If `playbook.yml` is present, `up` goes further still: it waits for cloud-init
to finish and then runs Ansible, returning only when the VM is fully
provisioned. Setting `CLOUD_INIT_WAIT=false` in the Migrantfile skips the
cloud-init wait. This is useful for images where provisioning is baked in rather
than handled by cloud-init at boot. Ansible still runs if `playbook.yml` is
present.

Without `playbook.yml`, the IP and SSH waits are the only signals that the VM is
ready. On a first boot, packages may still be installing in the background when
`up` returns.

Setting `AUTOCONNECT` in the Migrantfile causes `up` to connect automatically
once the VM is ready, without needing a separate `migrant ssh` or
`migrant console` invocation:

```bash
AUTOCONNECT=ssh      # connect via SSH after up completes
AUTOCONNECT=console  # attach serial console immediately after the VM starts
```

`AUTOCONNECT=console` skips the IP and SSH waits and attaches as soon as the VM
starts, so the boot output is visible — see
[Waiting for the VM to be ready](#waiting-for-the-vm-to-be-ready) above for the
one case (first creation with `playbook.yml` present) where provisioning still
runs before the console attaches.

## Network lifecycle

`migrant up` starts the `migrant` libvirt network (`virbr-migrant`,
192.168.200.0/24) automatically if it exists but is not currently active.
`migrant setup` only creates (defines) the network — starting it is left to `up`
so the network is not running unnecessarily when no VMs are in use.

`migrant halt` shuts down any libvirt networks listed in the `NETWORKS` config
that are no longer in use. If other running VMs are still attached to a network,
it is left running; otherwise it is stopped. This keeps the libvirt bridge
interfaces off the host when idle.

## Serial console vs SSH

`migrant console` opens a serial console via `virsh console`. This is not SSH —
it connects directly to the VM's serial port, like a physical terminal. To exit
the console, press `Ctrl+]`.

To log in via the console, the user defined in `cloud-init.yml` must have a
password set. cloud-init locks passwords by default for users defined in the
`users:` list. Add `lock_passwd: false` and either a plaintext or hashed
password to enable console login:

```yaml
users:
  - name: migrant
    lock_passwd: false
    plain_text_passwd: "yourpassword"
```

For production use, prefer a pre-hashed password (generated with
`openssl passwd -6`) so the plaintext never appears in the config file:

```yaml
users:
  - name: migrant
    lock_passwd: false
    passwd: "$6$..."   # openssl passwd -6 yourpassword
```

`migrant ssh` looks up the VM's IP address and SSHes in as the first user
defined in `cloud-init.yml`.

Host key verification is disabled (`StrictHostKeyChecking=no`,
`UserKnownHostsFile=/dev/null`) because these VMs are ephemeral — rebuilding a
VM generates a new host key at the same IP, which would cause a standard SSH
client to refuse the connection.

### Managed SSH key (recommended)

migrant can manage a dedicated passphrase-less SSH key at `~/.ssh/migrant`,
shared across all VMs that use it. This is detected automatically: if
`cloud-init.yml` contains a key whose comment is `migrant`, migrant uses
`~/.ssh/migrant` exclusively for SSH connections (`IdentitiesOnly=yes`). Set
`MIGRANT_KEY_PATH` to use a different path.

First-time setup:

```bash
migrant pubkey    # generates ~/.ssh/migrant if needed; prints the public key
```

Paste the output into `cloud-init.yml` under `ssh_authorized_keys`:

```yaml
users:
  - name: migrant
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... migrant
```

Then create the VM:

```bash
migrant up
migrant ssh       # uses ~/.ssh/migrant automatically
```

migrant verifies at `up` time that the key in `cloud-init.yml` matches
`~/.ssh/migrant.pub` and errors early if not, since a mismatch would mean the VM
boots with a key the host cannot use. If `~/.ssh/migrant` is ever lost, run
`migrant pubkey` to regenerate it, update `cloud-init.yml`, and rebuild with
`migrant destroy && migrant up`.

### Manual key management

Without a `migrant`-commented key, migrant expects you to have added your own
public key to `cloud-init.yml` and will error if `ssh_authorized_keys` is
absent. SSH uses whichever keys are available in your agent or default identity
files:

```yaml
users:
  - name: migrant
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... you@host
```

### Remote commands

Arguments after `--` are passed through as a remote command:

```bash
migrant ssh -- sudo cloud-init status --wait
migrant ssh -- sudo tail -f /var/log/cloud-init-output.log
```

`migrant ip` prints the VM's IPv4 address (the one SSH uses), which is useful
for scripting or connecting with tools other than SSH. When `NETWORK_IPV6=nat`
is set, `migrant ip -6` prints the VM's IPv6 (ULA) address, and `migrant status`
shows an `ipv6:` line alongside `ip:`.

## Port tunneling (host → VM)

Services running inside the VM are reachable from the host at the VM's bridge
IP, but apps that hardcode `http://127.0.0.1:PORT` (e.g. compiled client
bundles) won't find them. `migrant tunnel` opens SSH local-forwards so
`127.0.0.1:PORT` on the host routes into the VM.

```
migrant tunnel 3000 5432           # one-off
```

Configure defaults per-VM in `Migrantfile`:

```bash
TUNNEL_PORTS=(3000 5432 6379)
```

Then `migrant tunnel` with no args opens all of them. Ctrl-C closes the session
and removes the forwards — no persistent state, no firewall rules, no cleanup.
Internally this just runs `ssh -N -L PORT:127.0.0.1:PORT` using the same base
connection settings as `migrant ssh`, plus a few options suited to a long-lived
background tunnel: connection timeout, keepalives, and exiting if a forward
fails to bind.

## storage

`migrant storage` can be run from any directory, with or without a
`Migrantfile`. It lists everything in `IMAGES_DIR`, grouped by category:

```console
$ migrant storage
Directory: /var/lib/libvirt/images (16.1G)
Base Images:
  Arch-Linux-x86_64-cloudimg.qcow2 (519M)
  debian-13-generic-amd64.qcow2 (648M)
  ubuntu-25.10-server-cloudimg-amd64.img (785M)
VMs:
  arch-claude (2.4G):
    disk:     arch-claude.qcow2 (911M)
    seed iso: arch-claude-seed.iso (372K)
    snapshot: arch-claude-snapshot.qcow2 (1.5G)
  debian-claude (3.8G):
    disk:     debian-claude.qcow2 (987M)
    seed iso: debian-claude-seed.iso (372K)
    snapshot: debian-claude-snapshot.qcow2 (2.9G)
  ubuntu-claude (4.1G):
    disk:     ubuntu-claude.qcow2 (1.1G)
    seed iso: ubuntu-claude-seed.iso (372K)
    snapshot: ubuntu-claude-snapshot.qcow2 (3.1G)
Other:
  someone-elses-vm.qcow2 (2.0G)
```

`(destroyed)` means the VM's files are still on disk but the VM no longer exists
in libvirt. `migrant destroy` removes both the libvirt domain and its image
files, so this should not normally occur — it typically means the VM was
undefined directly with `virsh undefine`, or the files were left behind after
some other manual intervention. They are safe to remove.

Files in the **Other** category are not managed by migrant — they may belong to
VMs defined outside of migrant, or be leftover files from other tools.
