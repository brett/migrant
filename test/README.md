# test/

Integration tests for migrant. All tests require a working `migrant setup` and
KVM support on the host.

---

## Shell test scripts

Run from `test/vm`, a bare VM directory kept for these scripts (e.g.
`cd test/vm && ../test-hooks.sh`).

Do **not** run them from `examples/`. Every example sets `AUTOCONNECT`, which
leaves `migrant up` sitting in an interactive session — each script calls `up`
and then keeps going, so the run hangs. The examples also provision a full
toolchain over Ansible, which adds minutes to a test that only needs SSH.

Replace the key in `test/vm/cloud-init.yml` with the output of `migrant pubkey`
before the first run; migrant refuses to start when it does not match
`~/.ssh/migrant.pub`.

- **test-hooks.sh** — lifecycle hook execution, ordering, and environment
  variables
- **test-managed-config.sh** — managed config files, HOST_ACCESS validation,
  iptables rule creation and cleanup, `allow-host-port` DNAT scoping, and the
  `route_localnet` refcount. The last of these creates a second, short-lived VM
  named `<VM_NAME>-rl2` in a temp directory
- **test-wireguard.sh** — WireGuard mode against a peer in a network namespace,
  with keys generated per run. Proves the tunnel carries the traffic by having
  the peer report the source address it saw, checks the per-tap marks and DNS
  interception, the allow-lan-host exclusion, teardown, and that a bad key
  leaves nothing behind. Needs `sudo`, wireguard-tools, and working DNS. The VM
  must not order sshd behind `time-sync.target`: a tunnelled guest never
  completes an NTP sync, so `systemd-time-wait-sync` blocks the whole boot past
  migrant's SSH wait. `test/vm/cloud-init.yml` masks the NTP units in `bootcmd`
  to prevent this — it cannot be done from a playbook, which runs after SSH
- **test-multi-nic.sh** — a VM with two NICs: every per-tap rule reaches every
  tap, the shared per-VM chain is filled once rather than once per tap, and
  teardown clears both. Needs `sudo` to read the rules
- **test-forward-port.sh** — the `forward-port` directive: the mapping reaches
  the target through the gateway and by no other route. Needs `sudo` to stand up
  a routed target in a network namespace
- **test-shared-folder.sh** — shared folder isolation: the loop image is mounted
  with `nosymfollow` and recorded, and the VM refuses to start when the image
  will not mount or the mount point is backed by something else. Needs `sudo` to
  stage a foreign mount
- **test-extra-args.sh** — `$VM_DIR/.virt-install-extra-args` file convention:
  pre-up hook contributes args to virt-install on first create, file is consumed
  on read, absent file is a no-op

### `vm/` — the directory the scripts run from

A bare VM (`test-vm`): no `AUTOCONNECT`, no shared folder, one NIC, and no
`playbook.yml`, so Ansible never runs. The scripts probe with bash's `/dev/tcp`
rather than `netcheck.py`, so nothing needs installing in the guest.

Scripts that need a different shape — extra NICs, a shared folder, HOST_ACCESS
entries — back this Migrantfile up and write their own over it, restoring it on
exit. Keep the fixture minimal so they have a predictable base.

---

## VM test configs

Self-contained VM directories that verify HOST_ACCESS and network isolation
end-to-end. Each runs netcheck.py inside the VM to confirm connectivity matches
the Migrantfile configuration.

```bash
cd test/<config>
../../migrant up      # creates VM, runs hooks, verifies via netcheck
../../migrant halt    # clean shutdown
../../migrant destroy # remove VM when done
```

| Config                 | What it tests                                                                                                                                                                      |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tcp-host-port/`       | `allow-host-port tcp/9999` against a listener bound to `0.0.0.0` — covers the easy case, and that the port is mapped from the gateway only rather than hijacked from every address |
| `udp-host-port/`       | `allow-host-port udp/9999` — UDP listener on host, VM sends datagram through isolation                                                                                             |
| `localhost-host-port/` | `allow-host-port tcp/9998` against a listener bound to **`127.0.0.1`** — exercises the DNAT leg                                                                                    |
| `lan-host/`            | `allow-lan-host` — VM reaches the host's default router (auto-detected)                                                                                                            |
| `multi-rule/`          | Combined `allow-host-port tcp/9999` + `allow-lan-host` in a single config                                                                                                          |
| `isolation-only/`      | Default isolation with no HOST_ACCESS — verifies the VM cannot reach the host                                                                                                      |
| `no-isolation/`        | `NETWORK_ISOLATION=false` — verifies the VM can reach the host freely                                                                                                              |
| `ipv6-nat/`            | `NETWORK_IPV6=nat` — verifies NAT66 egress works while the host stays unreachable over IPv6                                                                                        |

### Hook pattern

Configs that start a host-side service use this hook layout:

| Hook       | Purpose                                             |
| ---------- | --------------------------------------------------- |
| `pre-up`   | Start a listener on the host before the VM boots    |
| `post-up`  | Run netcheck.py inside the VM and verify the result |
| `pre-down` | Kill the listener before the VM stops               |

Configs without a host-side service (`lan-host/`, `isolation-only/`,
`no-isolation/`) only have a `post-up` hook.

### File delivery via Ansible

Each config's `playbook.yml` copies `tools/netcheck.py` into the VM home
directory. Migrant.sh runs the playbook automatically once SSH and cloud-init
are ready, so the post-up hook can assume `~/netcheck.py` exists and just runs
it.

### Shared cloud-init

All configs use a copy of `test/cloud-init.yml` (Arch Linux, python3, uv).
