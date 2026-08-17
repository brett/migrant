# migrant

A single-file bash VM management tool built on libvirt/QEMU/KVM. The `setup/`
directory holds installer assets (libvirt hooks, network definition, zsh
completion) needed only by the `setup` subcommand — every VM lifecycle command
(`up`, `halt`, `destroy`, etc.) remains fully self-contained in the single
script. `examples/` holds ready-to-use example VMs (see "Example VM sync"
below); `test/` and `tools/` are unrelated to VM lifecycle.

## Purpose

The primary goal is a **secure, ephemeral environment for running coding
agents** (e.g. Claude Code). The design assumes the agent may be malicious or
compromised. Changes should preserve or strengthen the isolation boundary
between the VM and the host — do not introduce features that widen the attack
surface without careful consideration. Read `docs/security/README.md` and the
pages it links before touching networking, firewall, or shared-folder code —
this file only summarizes what's at stake, not the enforcement mechanism:

- The KVM hypervisor boundary between guest and host
- Network isolation, on by default (`docs/security/network-isolation.md`)
- IPv6 egress, blocked by default; opt-in only via `NETWORK_IPV6=nat`
  (`docs/security/ipv6-nat66.md`), refused alongside WireGuard
- The shared folder (`docs/security/shared-folder-isolation.md`), the only
  intentional host↔guest data channel — its scope should remain narrow
- The VM being destroyed and rebuilt, not patched in place

## Code style

- Run `shellcheck migrant` after every change — must be clean
- Run `shellcheck setup/qemu-hook setup/loop-hook setup/network-hook` after
  changes to any of them — must be clean (`setup/network.xml` and
  `setup/_migrant` are not shell and are not shellchecked)
- Run
  `uvx ansible-lint examples/arch/playbook.yml examples/ubuntu/playbook.yml examples/debian/playbook.yml`
  after changes to any playbook
- Run `tools/mdformat.sh` after changes to any Markdown file
- The script uses `set -euo pipefail`; follow these patterns:
  - Empty array expansion: `"${ARRAY[@]+"${ARRAY[@]}"}"`
  - Arithmetic that may evaluate to 0: `(( expr )) || true`
  - Pipelines that may fail: `cmd | other || true`
- Be DRY, but not at the cost of meaningful complexity — discuss trade-offs
  before refactoring

## sudo discipline

VM lifecycle commands (`up`, `halt`, `destroy`, `snapshot`, `status`, etc.) must
not call `sudo`. All privileged operations belong in `cmd_setup`, which runs
once and persists results via sentinel files or installed artifacts so lifecycle
commands can operate unprivileged.

`sudo` is permitted only in convenience wrapper subcommands unrelated to VM
lifecycle: `mount`, `unmount`, `wg`, and similar helpers.

## cmd_setup output format

`cmd_setup` uses the same aligned `key: value` pairs as `cmd_status`. Key design
rules:

- **`sudo -v` must run before the first `printf`** — this pre-authenticates sudo
  so the password prompt never appears mid-output; the explanatory message
  immediately before `sudo -v` tells the user why elevation is needed
- **`[changed]` marker**: append to any line where an action was taken;
  increment the `changes` counter with `(( changes++ )) || true`
- **Plain vs. `[changed]`**: the same row prints a plain value (`ok`, or a
  detected setting like `firewall backend: iptables`) when host state already
  matches what's wanted, and switches to `<action> [changed]` only when that
  row's check actually took action — e.g. `firewall backend:` stays plain when
  the backend is already `iptables`, but reports
  `set to iptables (was nftables) [changed]` when it has to fix it.
  `rp_filter hook: skipped (rp_filter=0)` is the one row that is inherently
  action-less, since a disabled `rp_filter` means there is nothing to install

## cmd_status output format

`cmd_status` uses aligned `key: value` pairs with indented sub-fields for
grouped data (tunnel details, loop mount point). Key design rules:

- **Field order**: name → state → ip → resources → tunnel → snapshot → loop
  (most operationally important first)
- **Markers**: append `[ERROR]` for broken states, `[WARNING]` for transient or
  degraded states; never use colors (breaks pipes/scripts)
- **Hints**: a `note:` sub-field appears wherever a row's state needs
  explanation the value alone doesn't give — `crashed` (recovery command), a
  WireGuard tunnel with an invalid key or that isn't actually routing traffic
  (`tunnel: active [ERROR]` / `tunnel: error [ERROR]`), hooks present but not
  executable, and `resources:` differing from the Migrantfile. Healthy states
  (`running`, `tunnel: active`, `isolation: enabled`, etc.) never get one

## Exit codes

Non-zero exits follow sysexits.h semantics. Reserve `1` for runtime state errors
with no sharper category (e.g. VM not running, VM not created).

## README sync

- Command descriptions in `usage()` and in the README command list must be
  **word-for-word identical**
- When adding a subcommand: update `usage()`, the `case` statement, the README
  command list, and the `_migrant` ZSH completion function in `cmd_setup`

## docs/ sync

When a change alters behavior documented in `docs/` — especially
`docs/security/*`, `docs/hooks.md`, and `docs/architecture.md` — update the
corresponding doc in the same change. These describe enforced behavior
(isolation guarantees, hook semantics, lifecycle internals), not just narrative,
so they go stale silently if left behind.

## Provisioning architecture

cloud-init runs before SSH and cannot be re-run without `destroy` + `up`.
Ansible runs after SSH and can be re-run any time. Prefer Ansible for anything
that doesn't need to happen before SSH.

## SSH is optional

Not all VMs define `ssh_authorized_keys`. Use `vm_has_ssh()` to check; new
features should work without SSH where possible. When SSH is required, fail with
a clear error.

## Migrantfile is sourced as bash

`require_config` sources the Migrantfile into the script's process — full bash,
but no sandboxing (same trust boundary applies to hooks in `$VM_DIR/hooks/`, see
`docs/hooks.md`). Do not add features that encourage untrusted content in a
Migrantfile.

## libvirt hooks are not the same as user lifecycle hooks

`setup/qemu-hook`, `setup/loop-hook`, and `setup/network-hook` are libvirt's own
hook mechanism — privileged, installed once by `cmd_setup` — unrelated to the
user-defined `$VM_DIR/hooks/` scripts described in `docs/hooks.md` and the
"Lifecycle hooks" section of this file. Two gotchas specific to these hooks:

### Never call virsh from within a hook

Calling `virsh` against a domain from its own hook deadlocks (libvirtd holds the
per-domain lock). Always read domain XML from stdin (`xml=$(cat)`) — the
persistent file at `/etc/libvirt/qemu/{name}.xml` may not exist during
`virt-install`.

### Always use physdev, never -i

Bridged VM traffic arrives on `virbr-migrant`, not the tap port, so `-i vnetN`
never matches. Use `-m physdev --physdev-in vnetN` for every rule targeting a
specific VM's tap, across all tables and ip6tables.

## Example VM sync

Keep all example VMs in `examples/` in parity — apply equivalent changes to all
of them. Distro-specific differences (package manager, unit names) are expected;
structural or behavioural divergence is not.

Known parity exceptions:

- **tmp.mount masked** (`examples/debian/playbook.yml` only): Debian 13 uses
  tmpfs for `/tmp`; Ubuntu and Arch do not.
- **`examples/nixos/`**: declarative image build with no `playbook.yml`; see its
  README for the full list of structural differences from the other examples.

## Lifecycle hooks

See `docs/hooks.md` for user-facing semantics (`$VM_DIR/hooks/`, state
transitions, environment variables, the extra-args file convention).
Implementation notes not covered there:

- Any new code path that shuts down a VM as part of `halt`/`snapshot`/
  `destroy`/`reset` must fire `pre-down`/`post-down` — use
  `do_graceful_shutdown()` or call `run_hook` directly
- The security-kill exception (docs: "security kills bypass hooks entirely") is
  implemented in `verify_shared_folder_mounts` and `verify_wireguard_tunnel` in
  `cmd_up`, which call `virsh destroy` directly
- `cmd_up` reads `$VM_DIR/.virt-install-extra-args` immediately after `pre-up`
  exits, on the first-create path only

## Managed config pattern

`/etc/migrant/${VM_NAME}/` is the data channel between unprivileged migrant and
the privileged qemu/loop hooks. `sync_managed_config()` validates and writes all
behavioral config (network isolation flag, IPv6/NAT66 flag, shared folder
isolation flag, HOST_ACCESS rules, WireGuard files) before the VM starts. The
hooks read these files at runtime.

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
