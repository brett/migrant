# TODO

## Shared folder security

Two unresolved attack vectors from a malicious guest:

**Symlink traversal** — the guest can create symlinks inside the shared folder
pointing to arbitrary host paths (e.g. `~/.ssh`, `/etc/passwd`). The host
process accessing those symlinks (`virtiofsd`) may follow them, giving the
guest read or write access to paths outside the shared directory. Possible
mitigations to explore:
- `virtiofsd` sandboxing options — check whether current versions of
  `virtiofsd` have a `--no-follow-symlinks` flag or equivalent, and whether
  the `--sandbox` mode restricts symlink traversal to within the shared root
- Mount the shared folder on a dedicated filesystem (e.g. a fixed-size ext4
  image) on the host side and point virtiofsd at that, rather than pointing it
  at a plain host directory — this would also address the disk-fill issue below

**Disk exhaustion** — the guest can fill the host disk by writing large files
into the shared folder (or into the qcow2 overlay, which also grows on the
host). Possible mitigations to explore:
- Use a fixed-size ext4 or btrfs image file as the shared folder backing store;
  virtiofsd serves the mounted image rather than a host directory — the guest
  cannot write beyond the image size
- Set a qcow2 disk size cap (already done via `DISK_GB`) and verify that
  `qemu-img` enforces it as a hard limit rather than a soft advisory
- Explore whether `virtiofsd` or the host kernel supports per-share quota
  enforcement

## Ansible integration

Cloud-init is first-boot only. For ongoing configuration changes (adding
packages, updating config files, changing runcmd behaviour) the options are
currently: SSH in and run commands manually, or `destroy` + `up`. Neither
scales well.

Consider adding optional Ansible support as a configuration management layer
on top of cloud-init:
- Cloud-init handles the one-time bootstrap (user creation, shared folder
  mount, base packages)
- An Ansible playbook (e.g. `playbook.yml` alongside `Migrantfile`) handles
  everything that may need to change over the VM's lifetime
- `migrant.sh provision` could run `ansible-playbook` against the VM's IP,
  re-applying the playbook idempotently without a destroy/up cycle
- The pre-baked image snapshot workflow (below) could also run the playbook
  before snapshotting, so rebuilt VMs start fully configured

This would also make it easier to manage multiple VMs with different roles
from a shared set of roles/tasks.
