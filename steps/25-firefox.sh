#!/usr/bin/env bash
# [root] Firefox theme extension: follows the omadora theme live
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Firefox release only runs signed add-ons, except from the system-wide
# extension directory, which Fedora's build leaves open to unsigned ones. The
# extension lives there; its native messaging host (also system-wide) streams
# each user's current theme to it.

PREFIX=/usr/local
LIBDIR=/usr/lib64
[ -d "$LIBDIR" ] || LIBDIR=/usr/lib
FIREFOX_ID="{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
EXT_ID="theme@omadora"
SRC="$OMADORA_ROOT/firefox"
HOST="$PREFIX/libexec/omadora/omadora-firefox-host"
EXT_DIR="$LIBDIR/mozilla/extensions/$FIREFOX_ID/$EXT_ID"

manifest=$(mktemp)
trap 'rm -f "$manifest"' EXIT
cat > "$manifest" <<JSON
{
  "name": "omadora_theme",
  "description": "Streams the current omadora theme to the omadora Theme extension",
  "path": "$HOST",
  "type": "stdio",
  "allowed_extensions": ["$EXT_ID"]
}
JSON

# What the old name (fedcandor) installed.
as_root rm -rf "$PREFIX/libexec/fedcandor" "$LIBDIR/mozilla/native-messaging-hosts/fedcandor_theme.json" \
    "$LIBDIR/mozilla/extensions/$FIREFOX_ID/theme@fedcandor"

as_root install -Dm755 "$SRC/omadora-firefox-host" "$HOST"
as_root install -Dm644 "$manifest" "$LIBDIR/mozilla/native-messaging-hosts/omadora_theme.json"
as_root rm -rf "$EXT_DIR"
for f in manifest.json background.js icon.svg; do
    as_root install -Dm644 "$SRC/extension/$f" "$EXT_DIR/$f"
done
ok "Firefox theme extension installed (restart Firefox once to load it)"
