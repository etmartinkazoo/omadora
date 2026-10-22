#!/usr/bin/env bash
# [user] Tela icon theme from its GitHub release (pinned + verified).
# One color set (Tela, Tela-dark, Tela-light): omadora-theme picks the dark or
# light variant to match the theme. omadora uses Tela everywhere; the shell
# pins it too (shell.qml).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

VERSION="2026-07-07"
SHA256="6b8c28f637067a15551459ab90e6720c5aba1215b777b6f1f506fea188a1ddf9"
URL="https://github.com/vinceliuice/Tela-icon-theme/archive/refs/tags/${VERSION}.tar.gz"
COLORS=(standard)
DEST="${OMADORA_ICON_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/icons}"
STAMP="$DEST/.omadora-tela-version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION ${COLORS[*]}" ]; then
    ok "Tela icon theme $VERSION already installed"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
info "Downloading Tela icon theme $VERSION"
download_verified "$URL" "$SHA256" "$tmp/tela.tar.gz"
tar -xzf "$tmp/tela.tar.gz" -C "$tmp"

mkdir -p "$DEST"
info "Installing Tela (${COLORS[*]}) to $DEST"
(cd "$tmp/Tela-icon-theme-$VERSION" && ./install.sh -d "$DEST" "${COLORS[@]}" >/dev/null)
# Remove color sets an earlier omadora version installed but no longer uses.
for old in blue grey; do
    rm -rf "$DEST/Tela-$old" "$DEST/Tela-$old-dark" "$DEST/Tela-$old-light"
done
echo "$VERSION ${COLORS[*]}" > "$STAMP"
ok "Tela icon theme $VERSION installed"
