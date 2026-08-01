# migrant

A single-file bash VM management tool built on libvirt/QEMU/KVM. The `setup/`
directory holds installer assets (libvirt hooks, network definition, zsh
completion) needed only by the `setup` subcommand — every VM lifecycle command
(`up`, `halt`, `destroy`, etc.) remains fully self-contained in the single
script. `examples/` holds ready-to-use example VMs (see "Example VM sync"
below); `test/` and `tools/` are unrelated to VM lifecycle.

## Purpose

The primary goal is a **secure, ephemeral environment for running coding agents**
(e.g. Claude Code). The design assumes the agent may be malicious or compromised.
Changes should preserve or strengthen the isolation boundary between the VM and
the host — do not introduce features that widen the attack surface without
careful consideration. Key containment properties to preserve:

- KVM hypervisor boundary between guest and host
- Network isolation (on by default) blocks the VM from reaching the host or LAN; set `NETWORK_ISOLATION=false` to opt out. Forwarded traffic to private, shared (`100.64.0.0/10`) and link-local destinations is rejected; guest→host is the per-VM INPUT chain, not those rejects
- IPv6 egress has no routable path by default (dropped at the FORWARD chain); `NETWORK_IPV6=nat` opts a VM in to NAT66 egress and is refused alongside WireGuard (IPv6 is not tunnel-routed). Guest→host IPv6 is blocked at INPUT in *every* IPv6 mode: the bridge always carries a ULA and that traffic is delivered locally, so the egress drop never sees it
- Rules match with `-m physdev`, which only sees bridge ports, and the MAC gate matches a source address the guest can change; neither is a substitute for the rules themselves
- The shared folder is the only intentional host↔guest data channel; its scope
  should remain narrow
- The VM is designed to be destroyed and rebuilt, not patched in place

## Code style

- Run `shellcheck migrant` after every change — must be clean
- Run `shellcheck setup/qemu-hook setup/loop-hook setup/network-hook` after
  changes to any of them — must be clean (`setup/network.xml` and
  `setup/_migrant` are not shell and are not shellchecked)
- Run `uvx ansible-lint examples/arch/playbook.yml examples/ubuntu/playbook.yml examples/debian/playbook.yml` after changes to any playbook
- The script uses `set -euo pipefail`; follow these patterns:
  - Empty array expansion: `"${ARRAY[@]+"${ARRAY[@]}"}"`
  - Arithmetic that may evaluate to 0: `(( expr )) || true`
  - Pipelines that may fail: `cmd | other || true`
- Be DRY, but not at the cost of meaningful complexity — discuss trade-offs
  before refactoring

## sudo discipline

VM lifecycle commands (`up`, `halt`, `destroy`, `snapshot`, `status`, etc.) must
not call `sudo`. All privileged operations belong in `cmd_setup`, which runs once
and persists results via sentinel files or installed artifacts so lifecycle
commands can operate unprivileged.

`sudo` is permitted only in convenience wrapper subcommands unrelated to VM
lifecycle: `mount`, `unmount`, `wg`, and similar helpers.

## cmd_setup output format

`cmd_setup` uses the same aligned `key: value` pairs as `cmd_status`. Key design
rules:

- **`sudo -v` must run before the first `printf`** — this pre-authenticates sudo
  so the password prompt never appears mid-output; the explanatory message
  immediately before `sudo -v` tells the user why elevation is needed
- **`[changed]` marker**: append to any line where an action was taken; increment
  the `changes` counter with `(( changes++ )) || true`
- **Informational rows** (e.g. `firewall backend:`) report a plain value with no
  `[changed]` marker — they describe detected state, not an action taken

## cmd_status output format

`cmd_status` uses aligned `key: value` pairs with indented sub-fields for
grouped data (tunnel details, loop mount point). Key design rules:

- **Field order**: name → state → ip → tunnel → snapshot → loop
  (most operationally important first)
- **Markers**: append `[ERROR]` for broken states, `[WARNING]` for transient
  or degraded states; never use colors (breaks pipes/scripts)
- **Hints**: only the `crashed` state includes a recovery hint (`note:` sub-field)
  because the steps are non-obvious; all other action hints are omitted

## Exit codes

Non-zero exits follow sysexits.h semantics. Reserve `1` for runtime state
errors with no sharper category (e.g. VM not running, VM not created).

## README sync

- Command descriptions in `usage()` and in the README command list must be
  **word-for-word identical**
- When adding a subcommand: update `usage()`, the `case` statement, the
  README command list, and the `_migrant` ZSH completion function in `cmd_setup`

## Provisioning architecture

cloud-init runs before SSH and cannot be re-run without `destroy` + `up`. Ansible
runs after SSH and can be re-run any time. Prefer Ansible for anything that doesn't
need to happen before SSH.

## SSH is optional

Not all VMs define `ssh_authorized_keys`. Use `vm_has_ssh()` to check; new features
should work without SSH where possible. When SSH is required, fail with a clear error.

## Migrantfile is sourced as bash

`require_config` sources the Migrantfile into the script's process — full bash, but
no sandboxing. Do not add features that encourage untrusted content in a Migrantfile.

## libvirt hook gotcha: never call virsh from within a hook

Calling `virsh` against a domain from its own hook deadlocks (libvirtd holds the
per-domain lock). Always read domain XML from stdin (`xml=$(cat)`) — the persistent
file at `/etc/libvirt/qemu/{name}.xml` may not exist during `virt-install`.

## iptables in the hook: always use physdev, never -i

Bridged VM traffic arrives on `virbr-migrant`, not the tap port, so `-i vnetN` never
matches. Use `-m physdev --physdev-in vnetN` for every rule targeting a specific VM's
tap, across all tables and ip6tables.

## Example VM sync

Keep all example VMs in `examples/` in parity — apply equivalent changes to
all of them. Distro-specific differences (package manager, unit names) are
expected; structural or behavioural divergence is not.

Known parity exceptions:
- **tmp.mount masked** (`examples/debian/playbook.yml` only): Debian 13 uses tmpfs for `/tmp`; Ubuntu and Arch do not.
- **`examples/nixos/`**: declarative image build with no `playbook.yml`; see
  its README for the full list of structural differences from the other
  examples.

## Lifecycle hooks

User hooks (`$VM_DIR/hooks/`) are state-transition-based, not command-based.
`pre-down`/`post-down` must fire from every code path that stops the VM — not
just `cmd_halt`. When adding a new code path that shuts down or force-stops a
VM, use `do_graceful_shutdown()` or fire hooks via `run_hook` directly.

Hooks run as the invoking user, not root. This is by design — same trust
boundary as the Migrantfile itself.

### Contributing to virt-install from a pre-up hook

On the first-create path only, `cmd_up` reads `$VM_DIR/.virt-install-extra-args`
after `pre-up` fires — one arg per line, appended to `virt-install` argv, then
deleted. Not read on the start-existing path. Hooks that need per-boot setup should
do that work unconditionally in `pre-up`; the args file is only for initial
`virt-install`.

## Managed config pattern

`/etc/migrant/${VM_NAME}/` is the data channel between unprivileged migrant
and the privileged qemu/loop hooks. `sync_managed_config()` validates and writes
all behavioral config (network isolation flag, IPv6/NAT66 flag, shared folder
isolation flag, HOST_ACCESS rules, WireGuard files) before the VM starts. The hooks read these
files at runtime.

The VM description tag carries only identity (`managed-by=migrant`). All
behavioral config comes from managed config files. The hooks fall back to the
description tag for VMs created before this pattern was introduced.

When adding a new feature that requires privileged enforcement:
1. Add the Migrantfile variable and validation to `sync_managed_config()`
2. Write the validated data to `/etc/migrant/${VM_NAME}/`
3. Read it in the appropriate hook (`apply_rules`, `remove_rules`, etc.)
4. Record what was installed in `.state` and tear down from that record

## The teardown record: `/run/migrant/<vm>.state`

`apply_rules` writes each fact — tap, MAC, isolation flag, IPv6 policy, refcount
taken, host-access entry, forward-port tuple — *before* installing the rule it
describes, and `remove_rules` undoes exactly what is recorded. Teardown must
never re-read `/etc/migrant/`: that holds the current Migrantfile, so a config
edited between `up` and `halt` would leave whatever the file no longer mentions
bound to a tap name libvirt hands to the next VM.

A rule with no record strands. A new key is added to `state_load`'s `case` and
bumps `STATE_VERSION_CURRENT`; keys are only ever added, never repurposed, so a
record from either side of a bump still parses.

## Rules are established, not inserted

Use `rule_set` and `rule_remove` rather than bare `-I`/`-D`. They delete every
copy before installing one, because a duplicate survives a single-delete
teardown and rebinds to whichever VM next receives that tap name. Leftover
REJECTs fail closed; leftover ACCEPTs fail open.

## Target platform

Primary target is Arch Linux with the `linux-hardened` kernel. Other Linux
distros are supported but secondary.
