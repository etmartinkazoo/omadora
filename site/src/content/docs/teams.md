---
title: For teams
description: Rolling omadora out across a business, from a two-person office to a fleet.
section: Running it
order: 4
---

The same properties that make omadora calm for one person make it manageable for many: every
machine runs **the same signed image**, updates are atomic, and any machine can roll back in one
reboot.

## Why it works for organizations

- **Identical machines.** The image is the configuration. There's no drift between laptops set
  up months apart.
- **Safe updates.** A bad update costs one reboot to undo, not a day of reinstalling.
- **Low support load.** Employees get a consistent desktop with a built-in cheatsheet
  (<kbd>Super</kbd>+<kbd>/</kbd>), and no system settings to break.
- **Security by default.** Encryption, automatic patches, firewall, deny-by-default Bluetooth.
  See [Security](../security/).

## Rolling out

1. **Pick a channel.** Most teams should follow the `:45` tag: security fixes daily, Fedora
   release upgrades only when you decide.
2. **Pilot first.** Put one or two machines on a dated build (`:45-YYYYMMDD`), use them for a
   week, then move everyone to that tag.
3. **Install.** Fedora Sway Atomic with encryption → rebase to the image → reboot. See
   [Install on Fedora Atomic](../install-atomic/).
4. **Hand over.** The employee logs in, and the desktop configures itself on first login.

## Your own company image

For company-specific software, certificates, VPN profiles or settings, build a thin image on
top of omadora. You keep all of its updates, plus your own layer:

```dockerfile
# Containerfile in your company's repository
FROM ghcr.io/etmartinkazoo/omadora:45

# Company packages
RUN dnf5 -y install openconnect && dnf5 clean all

# Internal CA certificate
COPY company-ca.pem /etc/pki/ca-trust/source/anchors/
RUN update-ca-trust

# Default Flatpaks, wallpaper, etc. go here too
```

Build it in CI (omadora's own `.github/workflows/build-image.yml` is a working template),
sign it with your own key, and point your machines at it with `rpm-ostree rebase`.

For bare-metal installs or VMs without a manual setup step,
[bootc-image-builder](https://github.com/osbuild/bootc-image-builder) turns any of these images
into an installer ISO or a disk image.

## Day-to-day administration

| Task | Command |
|------|---------|
| What is this machine running? | `rpm-ostree status` |
| Is an update staged? | `rpm-ostree status` (look for a "staged" deployment) |
| Undo the last update | `rpm-ostree rollback && systemctl reboot` |
| Move to a new build | `rpm-ostree rebase ostree-image-signed:docker://<image>:<tag>` |
| Shell logs for a support ticket | `journalctl --user -u quickshell --since today` |
