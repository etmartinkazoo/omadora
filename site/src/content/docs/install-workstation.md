---
title: Install on Fedora Workstation
description: Install the omadora desktop on a regular (non-Atomic) Fedora system with one script.
section: Start here
order: 3
---

Already running regular Fedora? The same desktop installs with an idempotent script. Running it
again is safe, and it's also how you update.

## Install

```bash
sudo dnf install -y git
git clone https://github.com/etmartinkazoo/omadora ~/omadora
cd ~/omadora
./install.sh
```

Then log out, and log into the **Sway** session.

## What the installer does

| Step | Runs as | What it does |
|------|---------|--------------|
| `system-packages` | sudo | Installs everything in `packages/fedora.txt` with dnf. |
| `system-security` | sudo | Enables automatic **security** updates, closes ssh in the firewall if sshd isn't enabled, and reports SELinux, Secure Boot and disk encryption status. |
| `firefox` | sudo | Installs the omadora Theme extension system-wide, the one place Fedora's Firefox runs an unsigned add-on, so Firefox follows theme switches live. |
| `fonts` | user | Installs 0xProto Nerd Font from its GitHub release, at a pinned version with a verified SHA-256 checksum. |
| `icons` | user | Installs the Tela icon theme from its GitHub release, at a pinned version with a verified checksum. |
| `dotfiles` | user | Links the configuration into your home directory with GNU stow. Anything in the way is moved to `~/.local/state/omadora/backup-*`. |
| `session` | user | Enables the shell's systemd service and reloads sway. |

Useful flags:

```bash
./install.sh --list          # show the steps
./install.sh fonts icons     # run only some steps
./install.sh --user-only     # skip the sudo steps
```

## Updating

```bash
cd ~/omadora && git pull && ./install.sh
```

Fedora itself keeps updating through dnf as usual. Security updates install automatically.
