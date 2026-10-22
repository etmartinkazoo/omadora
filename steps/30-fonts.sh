#!/usr/bin/env bash
# [user] 0xProto Nerd Font from the Nerd Fonts GitHub release (pinned + verified).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

VERSION="v3.5.1"
SHA256="3f2d36e4fa8b3af2f97b14b57c5b0f57f4c1bda5a59533fb913a9ff3344db7ce"
URL="https://github.com/ryanoasis/nerd-fonts/releases/download/${VERSION}/0xProto.tar.xz"
DEST="${OMADORA_FONT_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fonts/0xProto}"
STAMP="$DEST/.omadora-version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION" ]; then
    ok "0xProto Nerd Font $VERSION already installed"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
info "Downloading 0xProto Nerd Font $VERSION"
download_verified "$URL" "$SHA256" "$tmp/0xProto.tar.xz"

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xJf "$tmp/0xProto.tar.xz" -C "$DEST" --wildcards '*.ttf' 'LICENSE*' 2>/dev/null \
    || tar -xJf "$tmp/0xProto.tar.xz" -C "$DEST"
echo "$VERSION" > "$STAMP"
fc-cache -f "$DEST" >/dev/null
ok "0xProto Nerd Font $VERSION installed to $DEST"
