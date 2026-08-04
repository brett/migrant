# Lifecycle hooks

Place executable scripts in a `hooks/` directory alongside the `Migrantfile` to
run host-side actions at VM state transitions:

```
examples/ubuntu/
├── Migrantfile
├── cloud-init.yml
├── playbook.yml
└── hooks/
    ├── pre-up        ← runs before the VM starts
    ├── post-up       ← runs after the VM is fully ready
    ├── pre-down      ← runs before the VM shuts down
    └── post-down     ← runs after the VM has stopped
```

Hooks are executable files — any language works. They run as the invoking user
(not root), so they follow the same privilege model as `migrant` itself. Missing
or non-executable hooks are silently skipped.

## Hook semantics

Hooks are tied to **state transitions**, not commands. `pre-down` and
`post-down` fire from every code path that stops the VM — `halt`, `snapshot`,
`destroy`, and `reset` — so host-side cleanup always happens regardless of which
command initiated the shutdown.

| Hook        | When it fires                                                    | Abort on failure? |
| ----------- | ---------------------------------------------------------------- | ----------------- |
| `pre-up`    | Before `virsh start` or `virt-install`                           | Yes               |
| `post-up`   | After the VM is fully ready (IP, SSH, provisioning all complete) | No (warning)      |
| `pre-down`  | Before graceful shutdown or force-stop                           | Graceful only     |
| `post-down` | After the VM has fully stopped                                   | No (warning)      |

A `pre-up` hook that exits non-zero aborts `up` before the VM starts. A
`pre-down` hook that exits non-zero aborts `halt` and `snapshot`, but not
`destroy` or `reset` — intentional destruction is not blockable by a hook.

## Environment variables

Each hook receives these variables in its environment:

| Variable          | Description                                                                            |
| ----------------- | -------------------------------------------------------------------------------------- |
| `MIGRANT_VM_NAME` | VM name from the Migrantfile                                                           |
| `MIGRANT_VM_DIR`  | Absolute path to the VM directory                                                      |
| `MIGRANT_HOOK`    | Hook name (`pre-up`, `post-up`, `pre-down`, `post-down`)                               |
| `MIGRANT_TRIGGER` | Command that caused this hook (`up`, `halt`, `snapshot`, `destroy`, `reset`, `resize`) |
| `MIGRANT_VM_IP`   | VM IP address (set when available; empty for `pre-up` and console-only `post-up`)      |

All `Migrantfile` variables (`VM_NAME`, `RAM_MB`, `NETWORKS`, etc.) are also
present in the environment, since the `Migrantfile` is sourced before hooks run.

## Example: host-side service lifecycle

Start an inference server on the host before the VM boots, stop it when the VM
shuts down:

```bash
#!/usr/bin/env bash
# hooks/pre-up — start lemonade server for NPU workloads
systemctl --user start lemonade.service
```

```bash
#!/usr/bin/env bash
# hooks/post-down — stop lemonade when no VM needs it
systemctl --user stop lemonade.service
```

## Security notes

Hooks run as the user who invoked `migrant`, not as root. If a hook needs
privileged operations (e.g. managing firewall rules, binding devices), use
`sudo` within the hook script — this is the same model as `migrant mount` and
`migrant wg`.

Hooks are stored in the VM directory alongside the `Migrantfile`. Because the
`Migrantfile` itself is sourced as bash with no sandboxing, hooks do not widen
the trust boundary — any code in `hooks/` could equally be placed in the
`Migrantfile`.
