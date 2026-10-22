#!/usr/bin/env bash
# [user] Phone panel: build omadora-phone (texts + calls) and start its service
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

if ! command -v go >/dev/null 2>&1; then
    warn "Go isn't installed: skipping the phone panel (install Go, then: ./install.sh phone)"
    exit 0
fi
info "Building omadora-phone"
mkdir -p "$HOME/.local/bin"
( cd "$OMADORA_ROOT/phone" && go build -trimpath -o "$HOME/.local/bin/omadora-phone" ./cmd/omadora-phone )
ok "omadora-phone installed to ~/.local/bin"

systemctl --user daemon-reload
systemctl --user enable omadora-phone.service >/dev/null
if [ -n "${SWAYSOCK:-}" ]; then
    systemctl --user restart omadora-phone.service
fi
ok "omadora-phone.service enabled"

if [ ! -f "${XDG_STATE_HOME:-$HOME/.local/state}/omadora/phone/session.json" ]; then
    info "Pair your phone: open \"Pair Phone\" from the launcher"
fi
