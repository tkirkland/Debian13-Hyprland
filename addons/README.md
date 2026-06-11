# addons/ — your packages, no fork required

Create a file here named anything ending in `.pkgs` — for example
`my-tools.pkgs` — with one Debian package name per line:

```
# editors and shell comforts
htop
ncdu
tmux
firefox-esr
```

Blank lines and `#` comments are ignored. Every `.pkgs` file in this
directory is loaded at installer startup and its packages are installed
into the target system during the system phase, alongside the base set.

Rules of the road:

- Package names must exist in the apt sources the installer enables
  (Debian trixie `main contrib non-free-firmware` by default). A typo or
  unavailable package fails the system phase loudly — by design.
- Services installed by addon packages are enabled per Debian policy but
  are NOT started inside the install chroot (the installer's policy-rc.d
  guard); they start normally on first boot.
- `example.pkgs.sample` is a template: only the `.pkgs` suffix is loaded,
  so copy it to `something.pkgs` to activate it.
- Preflight logs how many addon packages it picked up, and the full list
  lands in the installer log with the apt transaction.
