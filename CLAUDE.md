# migrant.sh

A single-file bash VM management tool built on libvirt/QEMU/KVM. One script
(`migrant.sh`), one example VM config (`claude/`).

## Purpose

The primary goal is a **secure, ephemeral environment for running coding agents**
(e.g. Claude Code). The design assumes the agent may be malicious or compromised.
Changes should preserve or strengthen the isolation boundary between the VM and
the host — do not introduce features that widen the attack surface without
careful consideration. Key containment properties to preserve:

- KVM hypervisor boundary between guest and host
- `NETWORK_ISOLATION=true` blocks the VM from reaching the host or LAN
- The shared folder is the only intentional host↔guest data channel; its scope
  should remain narrow
- The VM is designed to be destroyed and rebuilt, not patched in place

## Code style

- Run `shellcheck migrant.sh` after every change — must be clean
- Run `uvx ansible-lint arch/playbook.yml ubuntu/playbook.yml debian/playbook.yml` after changes to any playbook
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

`cloud-init.yml` is required; `playbook.yml` is optional. cloud-init runs
before SSH is available and cannot be re-run without a full `destroy` + `up`.
Ansible runs after SSH is up and can be re-run at any time. Prefer Ansible for
anything that doesn't need to happen before SSH.

## SSH is optional

A user may not define `ssh_authorized_keys` in `cloud-init.yml`. New features
should work without SSH where possible — `vm_has_ssh()` can be used to check.
When SSH is genuinely required (as with Ansible provisioning), document that
clearly and fail with a helpful error rather than silently misbehaving.

## Migrantfile is sourced as bash

`require_config` sources the Migrantfile directly into the script's shell
process. This gives users full bash — variables, functions, conditionals — but
also means the Migrantfile runs as the invoking user with no sandboxing. Do not
add features that encourage putting untrusted content in a Migrantfile.

## libvirt hook gotcha: never call virsh from within a hook

libvirtd holds a per-domain lock when invoking hooks. Calling `virsh` against
that domain from inside a hook will deadlock — the hook waits for libvirtd,
which waits for the hook. The hook reads the domain XML from stdin (`xml=$(cat)`);
libvirt pipes it for every operation. Do not read from `/etc/libvirt/qemu/{name}.xml`
— that file may not exist during initial `virt-install` and reading it was the
source of a previous bug. Any future hook code must read from stdin.

## iptables in the hook: always use physdev, never -i

VM traffic arrives on the bridge device (`virbr-migrant`), not the tap port
(`vnet0`, `vnet6`, etc.). In every iptables chain — PREROUTING, FORWARD,
INPUT — the kernel reports `iif=virbr-migrant` for bridged packets. Using
`-i vnetN` never matches. Every rule targeting a specific VM's tap must use
`-m physdev --physdev-in vnetN` instead. This applies to all tables (filter,
mangle, nat) and ip6tables.

## How VMs are identified

- libvirt domains are tagged with `--description "managed-by=migrant.sh"` at
  `virt-install` time; use `virsh desc <name>` to check
- VM files follow a strict naming convention in `IMAGES_DIR`
  (`/var/lib/libvirt/images/`):
  - `{name}.qcow2` — VM disk
  - `{name}-seed.iso` — cloud-init seed ISO
  - `{name}-snapshot.qcow2` — snapshot

## Example VM sync

The `arch/`, `ubuntu/`, and `debian/` directories are sibling examples and should
be kept in parity. When updating one — adding a package, changing a bash alias,
adjusting a masking rationale — apply the equivalent change to all three.
Distro-specific differences (package manager, systemd unit names) are expected;
structural or behavioural divergence is not.

Known parity exceptions:

- **tmp.mount masked** (`debian/playbook.yml` only): Debian 13 uses tmpfs for
  `/tmp`; Ubuntu and Arch do not.

## Target platform

Primary target is Arch Linux with the `linux-hardened` kernel. Other Linux
distros are supported but secondary.
