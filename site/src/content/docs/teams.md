---
title: For teams
description: Setting up omadora across a business, from a two-person office to a fleet.
section: Running it
order: 4
---

The same properties that make omadora calm for one person make it manageable for many: every
machine is set up by the same script from the same repository, so laptops installed months apart
end up the same.

## Why it works for organizations

- **Identical machines.** The repository is the configuration. Everyone runs the same installer.
- **Low support load.** Employees get a consistent desktop with a built-in cheatsheet
  (<kbd>Super</kbd>+<kbd>/</kbd>).
- **Security by default.** Encryption, automatic security updates, firewall, deny-by-default
  Bluetooth. See [Security](../security/).

## Rolling out

1. **Pick a repository.** Use omadora's own, or fork it to add your company's packages and
   settings.
2. **Install Fedora 45** on each machine, with disk encryption.
3. **Run the installer** from that repository. See [Install](../install/). With a fork, clone
   your fork instead of omadora's.
4. **Customize per machine** in `~/.config/sway/config.d/80-local.conf` (displays, keyboard
   layout, extra bindings). Updates never touch it. See [Customizing](../customizing/).

## Keeping machines in sync

```bash
cd ~/omadora && git pull && ./install.sh
```

The installer is idempotent, so running it on every machine after a change is safe. Fedora's
security updates install automatically; other package updates go through `sudo dnf upgrade`.
See [Updates](../updates/).

## Day-to-day administration

| Task | Command |
|------|---------|
| Which omadora version is this? | `git -C ~/omadora log -1 --oneline` |
| Undo the last package update | `sudo dnf history undo last` |
| Shell logs for a support ticket | `journalctl --user -u quickshell --since today` |
