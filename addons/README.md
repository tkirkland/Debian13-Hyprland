# addons/ — drop in what apt can't give you

This directory is for installation artifacts that do not exist in the
Debian archive. Drop them here before running the installer:

## Vendor .deb packages — `addons/*.deb`

Brave, 1Password, VS Code, Discord — download the vendor's `.deb`, drop
it here. Each one is installed into the target during the system phase
with `apt`, which resolves its dependencies from the enabled Debian
sources. Services they ship are enabled but not started inside the
install chroot (the policy-rc.d guard); they start normally on first
boot.

Note for offline installs: the `.deb` itself installs from this
directory, but its *dependencies* must be resolvable — online that is
automatic; offline they must already be in the cache closure.

## Vendor runfiles — `addons/*.run`

VMware Workstation and friends. Runfiles are **staged, not executed**:
they are copied executable to `/opt/addons/` in the installed system,
and the installer log reminds you to run them after first boot. This is
deliberate — runfile installers compile kernel modules and start
services against the running system, which a chroot cannot honestly
provide.

```bash
# after first boot:
sudo /opt/addons/VMware-Workstation-Full-XX.x.x.run
```

## Convenience: archive package lists — `addons/*.list`

For packages that DO exist in the Debian archive, a `.list` file (one
package name per line, `#` comments allowed — same convention as
live-build's package lists) appends to the installer's base set. This is
secondary to the artifact mechanism above: if you find yourself listing
many archive packages, consider whether they belong in
`TARGET_BASE_PACKAGES` instead.

`example.list.sample` is an inert template; copy it to `<name>.list` to
activate.

Preflight logs a count of everything it picked up (packages, debs,
runfiles) before any destructive step, so you can confirm the pickup.
