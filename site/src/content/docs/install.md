---
title: Install
description: Install omadora on Fedora 45 (the Sway spin or any Fedora 45 install) with one script.
section: Start here
order: 2
---

omadora installs on top of **Fedora 45**: the [Fedora Sway spin](https://fedoraproject.org/spins/sway/)
is the natural starting point, but any Fedora 45 install works. Choose full-disk encryption when
you install Fedora; it can't be added later without reinstalling.

The installer is an idempotent script. Running it again is safe, and it's also how you update.

## Install

One command installs git, clones the repository to `~/omadora` and runs the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/etmartinkazoo/omadora/main/bootstrap.sh | bash
```

Or do the same by hand:

```bash
sudo dnf install -y git
git clone https://github.com/etmartinkazoo/omadora ~/omadora
cd ~/omadora && ./install.sh
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
See [Updates](../updates/).

## Moving from another machine

Your personal data doesn't live in the repository. To bring it over from an old omadora machine,
run this on the new one:

```bash
omadora-migrate user@old-host
```

It copies your theme and settings, dictation models, Firefox profile, and SSH and GPG keys over
SSH (rsync). Add `--phone` to move the phone pairing too; otherwise pair the new machine fresh.
`omadora-migrate --help` lists the options, including `--dry-run`.
