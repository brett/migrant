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

## SSH is optional

A user may not define `ssh_authorized_keys` in `cloud-init.yml`. New features
should work without SSH where possible — `vm_has_ssh()` can be used to check.
When SSH is genuinely required (as with Ansible provisioning), document that
clearly and fail with a helpful error rather than silently misbehaving.

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
