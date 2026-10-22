<p align="center"><img src="site/public/logo.svg" width="96" alt="omadora logo"></p>

# omadora

**Stable. Secure. Beautiful. No compromises.** A desktop for people who want to get things done:
Fedora 45 for stability and security, sway for productivity, and Quickshell for beauty.

*Formerly **fedcandor**: re-running `./install.sh` moves an existing install over
(see [Renamed from fedcandor](#renamed-from-fedcandor)).*

**Website & docs: <https://etmartinkazoo.github.io/omadora/>**

- **Fedora** with fixed releases, SELinux enforcing, LUKS and firewalld, instead of a rolling distro.
- **sway**: a mature, i3-compatible compositor that changes slowly.
- **Quickshell**: one themed shell providing the bar, launcher (with calculator), notifications,
  clipboard history, screenshots and screen recording, Wi-Fi, Bluetooth, audio mixer, battery
  and power profiles, night light, lock screen, polkit dialog, system tray and a keybind cheatsheet.

## Install (Fedora 45: the Sway spin, Workstation, Server or Everything)

One command on a fresh install (installs git, clones to `~/omadora`, runs `./install.sh`):

```bash
curl -fsSL https://raw.githubusercontent.com/etmartinkazoo/omadora/main/bootstrap.sh | bash
```

Or by hand:

```bash
git clone https://github.com/etmartinkazoo/omadora ~/omadora
cd ~/omadora
./install.sh
```

Fedora Atomic isn't supported. Bring your settings, speech models, Firefox profile and keys over
from another machine with `omadora-migrate you@old-laptop` (`--dry-run` first).

| Step              | Runs as | What it does |
|-------------------|---------|--------------|
| `rename`          | user    | one time: moves a fedcandor install over to the omadora names (see below) |
| `system-packages` | sudo    | `dnf install` everything in `packages/fedora.txt` |
| `system-security` | sudo    | automatic security updates, closes unused ssh in the firewall, reports SELinux/Secure Boot/LUKS status |
| `firefox`         | sudo    | installs the omadora Theme extension system-wide (the one place Fedora's Firefox runs an unsigned add-on), so Firefox follows theme switches live |
| `fonts`           | user    | 0xProto Nerd Font from its GitHub release (pinned version, SHA-256 verified) |
| `icons`           | user    | Tela icon theme from its GitHub release (pinned version, SHA-256 verified) |
| `dotfiles`        | user    | links `dotfiles/*` into `$HOME` with GNU stow (`--no-folding`); anything in the way goes to `~/.local/state/omadora/backup-*` |
| `session`         | user    | enables `quickshell.service`, reloads sway |
| `phone`           | user    | builds `omadora-phone` (texts and calls) and enables its service |
| `dictation`       | user    | builds whisper.cpp and fetches the speech model |

`./install.sh --list` shows the steps. `./install.sh fonts icons` runs just those, and
`./install.sh --user-only` skips the sudo steps. Every step is idempotent, so re-running is how you update.

## Layout

```
install.sh           entry point
bootstrap.sh         fresh Fedora 45 -> omadora (installs git, clones, runs install.sh)
lib/common.sh        shared helpers (logging, verified downloads)
steps/NN-*.sh        install steps, run in order
themes/              built-in themes (Omarchy-compatible colors.toml + wallpapers)
templates/           theme templates: rendered for Quickshell, sway, foot, GTK, Firefox
firefox/             Firefox theme extension + its native messaging host (live theme switching)
packages/fedora.txt  dnf package list
dotfiles/<pkg>/      stow packages: sway, quickshell, foot, swappy, autostart, systemd, bin
site/                website and docs (Astro); deployed to GitHub Pages
```

## Customizing

- **Per-machine sway settings** (wallpaper, keyboard options, output scaling) go in
  `~/.config/sway/config.d/80-local.conf`. It isn't tracked; `install.sh` creates a template.
- **Themes**: seven built in (`themes/`), plus any [Omarchy](https://github.com/omacom/omarchy)
  theme via `omadora-theme install omarchy:<name>`. Switch with <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>T</kbd>
  or `omadora-theme set <name>`. See [themes/README.md](themes/README.md).
- **Generated files** aren't tracked: `sway/config.d/99-theme.conf`, `foot/theme.ini`,
  `gtk-*/settings.ini`, `kitty/theme.conf`, `nvim/colors/omadora.lua` and Firefox's
  `chrome/userChrome.css` are rendered from `templates/` by `omadora-theme` on every theme
  change, and applied live (kitty and Neovim included). Firefox's colors come from
  `~/.local/state/omadora/theme/rendered/firefox-theme.json`, streamed to the omadora Theme
  extension, and tern follows `rendered/colors.toml` there.
- **Everything else** is a symlink into this repo: edit it here, then commit.

## Operating

- Quickshell runs as a systemd user service and restarts if it crashes.
  Logs: `journalctl --user -u quickshell -f`
- Lock: `loginctl lock-session` (or Super+Shift+E → L). `omadora-lock` waits until the lock
  is confirmed before allowing suspend, and falls back to swaylock.
- IPC: `qs ipc show` lists everything you can bind, e.g. `qs ipc call launcher toggle`.

## Checking changes

`tests/check.sh` boots a headless sway in a throwaway session (its own home folder and D-Bus), applies
every theme, loads the shell from this checkout in each desktop mode, opens every panel, and drives a
virtual mouse through window resizing, double-click maximize and drag-to-snap. Nothing touches the
running desktop. `--screenshots DIR` saves every panel per theme and mode for a visual review.
`git config core.hooksPath .githooks` runs the quick version (`--quick`, a few seconds) before
each commit that touches the desktop.

## Security notes

- Bluetooth pairing is deny-by-default: only devices you pair from the Bluetooth menu are accepted,
  and the adapter is only pairable while the menu is open.
- Clipboard history (cliphist) is capped at 200 entries, and skips entries that password managers mark sensitive.
- Apps launched from the shell run in their own systemd scopes, so a shell restart never takes them down.

## Renamed from fedcandor

omadora used to be called fedcandor. The `rename` install step (`steps/05-rename.sh`) moves an
existing install over once: `~/.local/state`, `~/.config`, `~/.local/share` and `~/.cache`
folders, the `~/fedcandor` checkout (to `~/omadora`, with its `origin` updated), the dotfile
links, the phone service, and nvim's colorscheme name.
