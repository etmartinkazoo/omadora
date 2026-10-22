#!/usr/bin/env bash
# Regenerate public/og.png (1200x630 social card) from scripts/og-art.svg.
# Needs ImageMagick and 0xProto Nerd Font (installed by the omadora `fonts` step).
set -euo pipefail
cd "$(dirname "$0")/.."
F="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/0xProto"
magick -density 96 scripts/og-art.svg \
  -font "$F/0xProtoNerdFont-Bold.ttf" -pointsize 70 -fill '#f4f8ff' -annotate +470+262 'omadora' \
  -pointsize 27 -fill '#f4f8ff' -annotate +474+336 'Stable. Secure. Beautiful.' \
  -fill '#6f9cf2' -annotate +474+380 'No compromises.' \
  -font "$F/0xProtoNerdFont-Regular.ttf" -pointsize 19 -fill '#6b82a6' -annotate +474+452 'Fedora · sway · Quickshell' \
  public/og.png
echo "wrote public/og.png"
