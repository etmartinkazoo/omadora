---
title: Updates
description: How omadora stays current, and what to do when an update goes wrong.
section: Running it
order: 2
---

omadora runs on regular Fedora 45, so there are two things to keep current: Fedora's packages,
and omadora's own configuration.

## Fedora

- **Security updates install automatically.** The installer enables `dnf5-automatic` for
  security updates only (`dnf5-automatic.timer`).
- **Everything else** updates with dnf, when you choose. Quick Settings → **Updates**
  (<kbd>U</kbd>) shows what's available and opens a terminal running `sudo dnf upgrade`, so you
  see and confirm the changes.
- **Never a surprise reboot:** nothing restarts your machine on its own.

| Task | Command |
|------|---------|
| Update everything now | `sudo dnf upgrade` |
| See what changed recently | `dnf history list` |
| Undo the last transaction | `sudo dnf history undo last` |

omadora targets Fedora 45. Moving to a newer Fedora release is never done for you.

## omadora

```bash
cd ~/omadora && git pull && ./install.sh
```

Whenever the installer replaces one of your files, the previous version is kept in
`~/.local/state/omadora/backup-*`.
