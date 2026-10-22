#!/usr/bin/env bash
# [user] Phone panel: build omadora-phone (texts + calls) and start its service
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# The Atomic image ships a prebuilt /usr/bin/omadora-phone. A build here
# (from a checkout, with Go installed) goes to ~/.local/bin, which the unit
# prefers, so hacking on the daemon works on the image too.
if command -v go >/dev/null 2>&1 && [ -d "$OMADORA_ROOT/.git" -o ! -x /usr/bin/omadora-phone ]; then
    info "Building omadora-phone"
    mkdir -p "$HOME/.local/bin"
    ( cd "$OMADORA_ROOT/phone" && go build -trimpath -o "$HOME/.local/bin/omadora-phone" ./cmd/omadora-phone )
    ok "omadora-phone installed to ~/.local/bin"
elif [ -x /usr/bin/omadora-phone ]; then
    ok "omadora-phone comes with the omadora image"
else
    warn "Go isn't installed: skipping the phone panel (install Go, then: ./install.sh phone)"
    exit 0
fi

systemctl --user daemon-reload
systemctl --user enable omadora-phone.service >/dev/null
if [ -n "${SWAYSOCK:-}" ]; then
    # --no-block: this step also runs from omadora-setup.service at login.
    systemctl --user --no-block restart omadora-phone.service
fi
ok "omadora-phone.service enabled"

if [ ! -f "${XDG_STATE_HOME:-$HOME/.local/state}/omadora/phone/session.json" ]; then
    info "Pair your phone: open \"Pair Phone\" from the launcher"
fi
