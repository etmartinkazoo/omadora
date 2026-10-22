#!/usr/bin/env bash
# [user] One-time move of a fedcandor install (the old name) over to omadora
#
# Moves state, settings, data and cache folders to their omadora names, drops
# links into the old checkout or image copy (the dotfiles step relinks them),
# retires the old phone service and build, points nvim at the renamed
# colorscheme, and moves a ~/fedcandor checkout to ~/omadora. Does nothing on
# an install that never had the old name.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

OLD=fedcandor
changed=0

# merge_dir OLD NEW: rename OLD to NEW, or move its entries into an existing
# NEW (never overwriting).
merge_dir() {
    local old=$1 new=$2 e
    [ -d "$old" ] && [ ! -L "$old" ] || return 0
    if [ ! -e "$new" ]; then
        mkdir -p "$(dirname "$new")"
        mv "$old" "$new"
    else
        for e in "$old"/* "$old"/.[!.]*; do
            [ -e "$e" ] || [ -L "$e" ] || continue
            if [ -e "$new/${e##*/}" ]; then
                warn "kept ${e/#$HOME/~}: ${new/#$HOME/~} already has one"
            else
                mv "$e" "$new/"
            fi
        done
        rmdir "$old" 2>/dev/null || true
    fi
    ok "moved ${old/#$HOME/~} to ${new/#$HOME/~}"
    changed=$((changed + 1))
}

# --- The old phone daemon: stop it before its state moves ---------------------
if systemctl --user cat "$OLD-phone.service" >/dev/null 2>&1; then
    systemctl --user disable --now "$OLD-phone.service" >/dev/null 2>&1 || true
    changed=$((changed + 1))
fi
find "$HOME/.config/systemd/user" -name "$OLD-*" \( -type l -o -type f \) -delete 2>/dev/null || true
rm -f "$HOME/.local/bin/$OLD-phone"   # steps/70-phone.sh's old build

# --- Folders ------------------------------------------------------------------
merge_dir "${XDG_STATE_HOME:-$HOME/.local/state}/$OLD" "${XDG_STATE_HOME:-$HOME/.local/state}/omadora"
merge_dir "${XDG_CONFIG_HOME:-$HOME/.config}/$OLD" "${XDG_CONFIG_HOME:-$HOME/.config}/omadora"
merge_dir "${XDG_DATA_HOME:-$HOME/.local/share}/$OLD" "${XDG_DATA_HOME:-$HOME/.local/share}/omadora"
merge_dir "${XDG_CACHE_HOME:-$HOME/.cache}/$OLD" "${XDG_CACHE_HOME:-$HOME/.cache}/omadora"

# --- The checkout ---------------------------------------------------------------
# Not while running from it: the remaining steps would vanish mid-run.
if [ -d "$HOME/$OLD/.git" ] && [ ! -e "$HOME/omadora" ]; then
    if [ "$(cd "$OMADORA_ROOT" && pwd -P)" = "$(cd "$HOME/$OLD" && pwd -P)" ]; then
        warn "running from ~/$OLD: move it, then run the installer from there:"
        warn "  mv ~/$OLD ~/omadora && ~/omadora/install.sh"
    else
        mv "$HOME/$OLD" "$HOME/omadora"
        ok "moved ~/$OLD to ~/omadora"
        changed=$((changed + 1))
    fi
fi
if [ -d "$HOME/omadora/.git" ]; then
    url=$(git -C "$HOME/omadora" remote get-url origin 2>/dev/null || true)
    case "$url" in
        *"/$OLD" | *"/$OLD.git")
            git -C "$HOME/omadora" remote set-url origin "${url%"$OLD"*}omadora${url##*"$OLD"}"
            ok "~/omadora's origin now points at the renamed repo" ;;
    esac
fi

# --- Links into the old dotfiles (checkout or image copy) -----------------------
n=$(find "$HOME/.config" "$HOME/.local" -type l -lname "*$OLD/dotfiles/*" 2>/dev/null | wc -l)
if [ "$n" -gt 0 ]; then
    find "$HOME/.config" "$HOME/.local" -type l -lname "*$OLD/dotfiles/*" -delete 2>/dev/null
    ok "removed $n links into the old $OLD dotfiles (the dotfiles step relinks them)"
    changed=$((changed + 1))
fi

# --- nvim follows the desktop theme under the new colorscheme name -------------
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/nvim/colors/$OLD.lua"
init="${XDG_CONFIG_HOME:-$HOME/.config}/nvim/init.lua"
if [ -f "$init" ] && [ ! -L "$init" ] && grep -q "\"$OLD\"\|$OLD-theme" "$init"; then
    sed -i "s/\"$OLD\"/\"omadora\"/g; s/$OLD-theme/omadora-theme/g" "$init"
    ok "nvim: init.lua now loads the omadora colorscheme"
    changed=$((changed + 1))
fi

if [ "$changed" -eq 0 ]; then
    ok "nothing from $OLD to move"
fi
