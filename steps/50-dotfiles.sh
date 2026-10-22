#!/usr/bin/env bash
# [user] Link the dotfiles into $HOME with GNU stow.
#
# --no-folding links individual files (never whole directories), so files that
# programs generate next to them (e.g. sway/config.d/99-theme.conf, foot's
# theme.ini, your own config.d/80-local.conf) stay out of the repo.
# Anything already in the way is moved to ~/.local/state/omadora/backup-*.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

PACKAGES=(sway quickshell kitty foot swappy autostart systemd bin applications)
DOTFILES="$OMADORA_ROOT/dotfiles"
need_cmd stow

backup="$OMADORA_STATE/backup-$(date +%Y%m%d-%H%M%S)"
moved=0

for pkg in "${PACKAGES[@]}"; do
    while IFS= read -r -d '' rel; do
        rel=${rel#./}
        src="$DOTFILES/$pkg/$rel"
        target="$HOME/$rel"
        if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$src")" ]; then
            continue  # already linked to us
        fi
        if [ -e "$target" ] || [ -L "$target" ]; then
            mkdir -p "$backup/$(dirname "$rel")"
            mv "$target" "$backup/$rel"
            moved=$((moved + 1))
        fi
    done < <(cd "$DOTFILES/$pkg" && find . \( -type f -o -type l \) -print0)

    stow --no-folding --dir "$DOTFILES" --target "$HOME" --restow "$pkg"
    ok "linked $pkg"
done

if [ "$moved" -gt 0 ]; then
    info "moved $moved existing file(s) to $backup"
fi
