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
- Run `ansible-lint claude/playbook.yml` after changes to the playbook
- The script uses `set -euo pipefail`; follow these patterns:
  - Empty array expansion: `"${ARRAY[@]+"${ARRAY[@]}"}"`
  - Arithmetic that may evaluate to 0: `(( expr )) || true`
  - Pipelines that may fail: `cmd | other || true`
- Be DRY, but not at the cost of meaningful complexity — discuss trade-offs
  before refactoring

## README sync

- Command descriptions in `usage()` and in the README command list must be
  **word-for-word identical**
- When adding a subcommand: update `usage()`, the `case` statement, and the
  README command list together

## Provisioning architecture

- **cloud-init** (`cloud-init.yml`): required — `migrant.sh up` will error
  without it. Must define at least one user and handle virtiofs mounting.
  Runs on first boot only, before SSH is available. Using it for additional
  provisioning (packages, etc.) is optional — that can be left to Ansible
  instead. cloud-init does not re-run on an existing VM, but the
  `destroy` + `up` workflow effectively replaces it.
- **Ansible** (`playbook.yml`): fully optional. Runs after SSH is up and can
  be re-run at any time with `migrant.sh provision`. Use for packages, config
  files, dotfiles, and anything that may need updating over the VM's lifetime.

If a provisioning task can be deferred to Ansible, it should be — cloud-init
is harder to iterate on since it requires a full rebuild to re-run.

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
which waits for the hook. The qemu hook reads
`/etc/libvirt/qemu/{name}.xml` directly as a workaround. Any future hook code
must follow the same pattern.

## How VMs are identified

- libvirt domains are tagged with `--description "managed-by=migrant.sh"` at
  `virt-install` time; use `virsh desc <name>` to check
- VM files follow a strict naming convention in `IMAGES_DIR`
  (`/var/lib/libvirt/images/`):
  - `{name}.qcow2` — VM disk
  - `{name}-seed.iso` — cloud-init seed ISO
  - `{name}-snapshot.qcow2` — snapshot

## Target platform

Primary target is Arch Linux with the `linux-hardened` kernel. Other Linux
distros are supported but secondary.
