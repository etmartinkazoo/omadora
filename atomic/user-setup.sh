#!/usr/bin/env bash
# Per-user setup on omadora Atomic, run at login by omadora-setup.service.
# Links the dotfiles into $HOME (stow, no folding) and enables the user
# services: from /usr/share/omadora the first time and again whenever the
# image ships a new omadora version, or from a ~/omadora checkout (as
# bootstrap.sh clones) once, after which you re-run ./install.sh there
# yourself. Customize via ~/.config/sway/config.d/80-local.conf.
set -euo pipefail

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omadora"
mkdir -p "$STATE"

if [ -d "$HOME/omadora/.git" ]; then
    root="$HOME/omadora"
    version=checkout
else
    root=/usr/share/omadora
    version=$(cat "$root/IMAGE_VERSION" 2>/dev/null || echo unknown)
fi
if [ "$(cat "$STATE/linked-version" 2>/dev/null)" = "$version" ]; then
    exit 0
fi

"$root/install.sh" --user-only rename dotfiles session phone
echo "$version" > "$STATE/linked-version"
