---
title: Updates & rollback
description: How omadora stays current without ever leaving you with a broken machine.
section: Running it
order: 2
---

## On Fedora Atomic

Your OS is a single image. An update is a **new image**, downloaded and prepared next to the
running one, that becomes active the next time you reboot. The update either applies in full or
not at all, and the previous image stays installed.

- **Automatic:** `rpm-ostreed-automatic.timer` stages new images in the background.
- **Daily builds:** CI rebuilds omadora every day on Fedora's latest base, so security fixes arrive promptly.
- **Never a surprise reboot:** a staged update waits until you choose to restart.

| Task | Command |
|------|---------|
| See what's booted and what's staged | `rpm-ostree status` |
| Update right now | `rpm-ostree upgrade && systemctl reboot` |
| **Roll back** to the previous image | `rpm-ostree rollback && systemctl reboot` |
| Roll back without a working desktop | Choose the previous entry in the boot menu |
| Pin the current image (keep it forever) | `sudo ostree admin pin 0` |

### Choosing a channel

| Tag | Follows |
|-----|---------|
| `:latest` | The newest Fedora release omadora supports |
| `:45` | Fedora 45 only. Upgrade to the next release deliberately. |
| `:45-YYYYMMDD` | One exact build. Useful for testing or fleet pinning (see [For teams](../teams/)). |

Switch channels with `rpm-ostree rebase ostree-image-signed:docker://ghcr.io/etmartinkazoo/omadora:<tag>`.

## On Fedora Workstation

- Fedora updates through dnf as usual; **security updates install automatically**
  (`dnf5-automatic.timer`).
- Update omadora itself with `cd ~/omadora && git pull && ./install.sh`.
- Your previous dotfiles are kept in `~/.local/state/omadora/backup-*` whenever the installer replaces something.
