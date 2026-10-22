#!/usr/bin/env bash
# [user] Enable the user services and (if inside sway) apply everything live.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Per-machine sway settings live in an untracked file.
local_conf="$HOME/.config/sway/config.d/80-local.conf"
if [ ! -e "$local_conf" ]; then
    mkdir -p "$(dirname "$local_conf")"
    cat > "$local_conf" <<'CONF'
# Per-machine sway settings (not tracked by omadora). Examples:
# (wallpaper: use `omadora-theme wallpaper PATH`; sway's own bg is off)
# output eDP-1 scale 1.5
# input "type:keyboard" { xkb_layout us; xkb_options ctrl:nocaps }
CONF
    ok "created $local_conf"
fi

# Render the current theme (candor on first run) for sway, foot, GTK, Quickshell.
"$HOME/.local/bin/omadora-theme" refresh || warn "omadora-theme refresh failed"
ok "theme: $("$HOME/.local/bin/omadora-theme" current)"

systemctl --user daemon-reload
systemctl --user enable quickshell.service >/dev/null
ok "quickshell.service enabled (starts with the sway session)"

if [ -n "${SWAYSOCK:-}" ] && command -v swaymsg >/dev/null 2>&1; then
    info "Inside sway: reloading config and restarting Quickshell"
    swaymsg reload >/dev/null || warn "swaymsg reload failed"
    # A Quickshell started some other way (e.g. a bare `exec qs`) would clash.
    if ! systemctl --user is-active --quiet quickshell.service; then
        qs kill >/dev/null 2>&1 || true
    fi
    # --no-block: this step also runs from omadora-setup.service, which is
    # ordered before quickshell.service; waiting here would deadlock.
    systemctl --user --no-block restart quickshell.service
    ok "session updated"
else
    info "Not inside sway: log into a sway session to start using omadora."
fi
