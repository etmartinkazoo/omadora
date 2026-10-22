#!/usr/bin/env bash
# omadora check: catch a broken desktop before it reaches anyone.
#
#   tests/check.sh                     static checks + full shell run
#   tests/check.sh --quick             static checks + shell load in each mode (pre-commit)
#   tests/check.sh --screenshots DIR   also save a screenshot of every panel, per theme and mode
#   tests/check.sh --themes "a b"      themes for the shell run (default: candor candor-light)
#
# The shell run boots a headless sway inside a throwaway home folder, runtime
# folder and D-Bus session, applies every built-in theme, then loads the
# Quickshell config from this checkout in each desktop mode and opens every
# panel. Any QML error, sway config error or failed theme fails the check.
# Nothing touches the running desktop.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
QS_DIR="$ROOT/dotfiles/quickshell/.config/quickshell"
QUICK=0
SHOTS=""
THEMES="candor candor-light"

while [ $# -gt 0 ]; do
    case $1 in
        --quick) QUICK=1 ;;
        --screenshots) SHOTS=$(realpath -m "$2"); shift ;;
        --themes) THEMES=$2; shift ;;
        -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "check: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

red=$'\e[31m' green=$'\e[32m' dim=$'\e[2m' off=$'\e[0m'
[ -t 1 ] || { red=""; green=""; dim=""; off=""; }
failures=0
pass() { printf '%s ok%s %s\n' "$green" "$off" "$*"; }
fail() { printf '%sFAIL%s %s\n' "$red" "$off" "$*"; failures=$((failures + 1)); }

# ---------------------------------------------------------------- static ----
if [ -z "${OMADORA_CHECK_INNER:-}" ]; then
    bad=0
    while IFS= read -r -d '' f; do
        if head -1 "$f" | grep -q 'bash\|/sh'; then
            bash -n "$f" 2>/dev/null || { fail "shell syntax: ${f#$ROOT/}"; bad=1; }
        elif head -1 "$f" | grep -q python; then
            python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" 2>/dev/null \
                || { fail "python syntax: ${f#$ROOT/}"; bad=1; }
        fi
    done < <(find "$ROOT/dotfiles/bin" "$ROOT/steps" "$ROOT/tests" "$ROOT/firefox" "$QS_DIR/scripts" \
                 -type f \( -perm -u+x -o -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null)
    [ $bad -eq 0 ] && pass "scripts parse"
    bash -n "$ROOT/bootstrap.sh" "$ROOT/install.sh" 2>/dev/null \
        && pass "bootstrap and installer parse" || fail "shell syntax: bootstrap.sh or install.sh"

    if out=$(sway -C -c "$ROOT/dotfiles/sway/.config/sway/config" 2>&1 | grep -i 'error' ); then
        fail "sway config:"; echo "$out" | sed 's/^/    /'
    else
        pass "sway config"
    fi

    for tool in sway qs grim dbus-run-session; do
        command -v "$tool" >/dev/null || { fail "missing $tool: can't run the shell check"; exit 1; }
    done

    # Everything below runs in its own D-Bus session and environment.
    set +e
    args=(--themes "$THEMES")
    [ $QUICK = 1 ] && args+=(--quick)
    [ -n "$SHOTS" ] && args+=(--screenshots "$SHOTS")
    OMADORA_CHECK_INNER=1 OMADORA_CHECK_FAILURES=$failures REAL_HOME=$HOME \
        dbus-run-session -- "$0" "${args[@]}" 2>/dev/null
    exit $?
fi

failures=${OMADORA_CHECK_FAILURES:-0}

# ----------------------------------------------------- isolated session ----
T=$(mktemp -d "${TMPDIR:-/tmp}/omadora-check.XXXXXX")
cleanup() {
    local status=$?
    set +e
    [ -n "${QS_PID:-}" ] && kill "$QS_PID" 2>/dev/null
    [ -n "${SWAY_PID:-}" ] && kill "$SWAY_PID" 2>/dev/null
    # Anything else started from the sandbox (helpers, test windows)
    pkill -f "$T/" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$T"
    exit $status
}
trap cleanup EXIT

export HOME="$T/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
export XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
export XDG_RUNTIME_DIR="$T/run"
# Icons and fonts from the real home (read only), so screenshots look right
export XDG_DATA_DIRS="$REAL_HOME/.local/share:/usr/local/share:/usr/share"
export OMADORA_ROOT="$ROOT"
unset WAYLAND_DISPLAY SWAYSOCK DISPLAY I3SOCK
mkdir -p "$HOME/.local/bin" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME/omadora"
mkdir -m 700 "$XDG_RUNTIME_DIR"
[ -d "$REAL_HOME/.local/share/fonts" ] && ln -s "$REAL_HOME/.local/share/fonts" "$XDG_DATA_HOME/fonts"
# Not the Bluetooth pairing agent: it registers with the real system bus.
for f in "$ROOT"/dotfiles/bin/.local/bin/*; do
    [ "$(basename "$f")" = quickshell-bluez-agent ] || ln -s "$f" "$HOME/.local/bin/"
done
export PATH="$HOME/.local/bin:$PATH"

cat >"$T/sway.conf" <<'EOF'
output HEADLESS-1 resolution 1280x800 scale 1
default_border pixel 1
EOF
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    sway -c "$T/sway.conf" >"$T/sway.log" 2>&1 &
SWAY_PID=$!
for _ in $(seq 50); do
    SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -1) && [ -n "$SWAYSOCK" ] && break
    sleep 0.1
done
[ -n "${SWAYSOCK:-}" ] || { fail "headless sway didn't start"; sed 's/^/    /' "$T/sway.log" | tail -5; exit 1; }
export SWAYSOCK
export WAYLAND_DISPLAY=$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* | grep -v lock | head -1)")
pass "headless sway ($WAYLAND_DISPLAY)"

# ------------------------------------------------------------- themes ----
bad=0
for d in "$ROOT"/themes/*/; do
    t=$(basename "$d")
    omadora-theme set "$t" >"$T/theme.log" 2>&1 || { fail "theme $t:"; sed 's/^/    /' "$T/theme.log" | tail -3; bad=1; }
done
[ $bad -eq 0 ] && pass "every built-in theme applies"

# A couple of windows for the taskbar, dock, switcher and overview
if command -v foot >/dev/null; then
    for title in one two; do foot --title "check $title" sleep 600 >/dev/null 2>&1 & done
    sleep 1
fi

# -------------------------------------------------------------- shell ----
first_theme=${THEMES%% *}
omadora-theme set "$first_theme" >/dev/null 2>&1
echo tiling >"$XDG_STATE_HOME/omadora/mode"
qs -p "$QS_DIR" >"$T/qs.log" 2>&1 &
QS_PID=$!
for _ in $(seq 100); do
    grep -q 'Configuration Loaded\|Failed to load' "$T/qs.log" && break
    sleep 0.1
done
if ! grep -q 'Configuration Loaded' "$T/qs.log"; then
    fail "shell didn't load:"; grep -A3 'ERROR' "$T/qs.log" | sed 's/^/    /' | head -12; exit 1
fi
pass "shell loads"

ipc() { qs ipc --pid "$QS_PID" call "$@" >/dev/null 2>&1 || true; }
shot() { [ -n "$SHOTS" ] && grim "$SHOTS/$1.png" 2>/dev/null; true; }
[ -n "$SHOTS" ] && mkdir -p "$SHOTS"

# target:open function:close function, per panel
PANELS="launcher:open:hide keybinds:open:hide theme:picker:picker quick:open:hide
notifications:open:hide system:open:hide audio:open:hide wifi:open:hide bluetooth:open:hide
overview:open:hide switcher:apps:hide start:open:hide updates:open:hide displays:open:hide chat:open:hide"

for theme in $THEMES; do
    omadora-theme set "$theme" >/dev/null 2>&1 || fail "theme $theme"
    sleep 0.5
    for mode in tiling windows macos; do
        echo "$mode" >"$XDG_STATE_HOME/omadora/mode"
        sleep 0.8
        shot "$theme-$mode"
        [ $QUICK = 1 ] && continue
        for p in $PANELS; do
            IFS=: read -r target open close <<<"$p"
            [ "$target" = start ] && [ "$mode" != windows ] && continue
            ipc "$target" "$open"
            sleep 0.5
            shot "$theme-$mode-$target"
            ipc "$target" "$close"
            sleep 0.2
        done
    done
    [ $QUICK = 1 ] && break
done

# ------------------------------------------------ mode switch layouts ----
# Windows keep their place: tiled -> floating starts where they were tiled,
# and a floating layout survives a trip through tiling mode.
frames() {
    swaymsg -r -t get_tree | python3 -I -c '
import json, sys
def walk(n):
    if n.get("pid"):
        r = n["rect"]; t = n["deco_rect"]["height"] if n["type"] == "floating_con" else 0
        print(n["id"], n["type"], r["x"], r["y"] - t, r["width"], r["height"] + t)
    for c in n.get("nodes", []) + n.get("floating_nodes", []): walk(c)
walk(json.load(sys.stdin))'
}
if [ $QUICK = 0 ] && [ "$(frames | wc -l)" -ge 2 ]; then
    echo tiling >"$XDG_STATE_HOME/omadora/mode"
    mode_to() { local out; out=$(omadora-mode set "$1" 2>&1) || { fail "omadora-mode set $1:"; echo "$out" | sed "s/^/    /"; return 1; }; }
    mode_to tiling; sleep 0.3
    before=$(frames | awk '{print $1, $3, $4, $5, $6}')
    mode_to windows; sleep 0.5
    floated=$(frames | awk '$2 == "floating_con" {print $1, $3, $4, $5, $6}')
    # Within a few pixels: terminals size themselves in whole character cells
    close() { paste -d' ' <(echo "$1") <(echo "$2") | awk '{ for (i = 2; i <= 5; i++) { d = $i - $(i + 5); if (d < -12 || d > 12) bad = 1 } } END { exit bad }'; }
    if close "$before" "$floated"; then
        pass "tiled -> floating keeps each window where it was"
    else
        fail "tiled -> floating moved windows:"; { diff <(echo "$before") <(echo "$floated") || true; } | sed 's/^/    /'
    fi
    id=$(frames | awk 'NR == 1 {print $1}')
    swaymsg -q "[con_id=$id] resize set 500 300, move absolute position 120 90"; sleep 0.3
    moved=$(frames | awk '{print $1, $3, $4, $5, $6}')
    mode_to tiling; sleep 0.5
    mode_to windows; sleep 0.5
    again=$(frames | awk '{print $1, $3, $4, $5, $6}')
    if close "$moved" "$again"; then
        pass "floating layout survives a trip through tiling"
    else
        fail "floating layout lost:"; { diff <(echo "$moved") <(echo "$again") || true; } | sed 's/^/    /'
    fi

    # ---- Pointer: resize handle, double-click, drag-to-snap, tooltip ----
    # sway's virtual cursor drives the shell like a mouse would.
    mouse() { python3 -I "$ROOT/tests/vpointer.py" 1280 800 "$@"; }
    focused() { frames_full | awk '$7 == "F" {print $1, $3, $4, $5, $6}'; }
    frames_full() {
        swaymsg -r -t get_tree | python3 -I -c '
import json, sys
def walk(n):
    if n.get("pid"):
        r = n["rect"]; t = n["deco_rect"]["height"] if n["type"] == "floating_con" else 0
        print(n["id"], n["type"], r["x"], r["y"] - t, r["width"], r["height"] + t, "F" if n.get("focused") else "-", t)
    for c in n.get("nodes", []) + n.get("floating_nodes", []): walk(c)
walk(json.load(sys.stdin))'
    }
    within() { local d=$(( $1 - $2 )); [ ${d#-} -le "$3" ]; }

    sleep 0.6
    read -r fid fx fy fw fh <<<"$(focused)"
    if [ -n "${fid:-}" ]; then
        swaymsg -q "[con_id=$fid] resize set 600 400, move absolute position 200 150"; sleep 0.6
        read -r fid fx fy fw fh <<<"$(focused)"
        # Right-edge handle: drag 100px right
        y=$((fy + fh / 2))
        mouse move $((fx + fw + 3)) $y sleep 0.2 press move $((fx + fw + 53)) $y move $((fx + fw + 103)) $y sleep 0.2 release
        sleep 0.6
        read -r _ _ _ nw _ <<<"$(focused)"
        if within "$nw" $((fw + 100)) 16; then pass "resize handle (width $fw -> $nw)"; else fail "resize handle: width $fw -> $nw, expected about $((fw + 100))"; fi

        # Double-click the title bar: maximize, and again to restore
        read -r fid fx fy fw fh <<<"$(focused)"
        mouse move $((fx + 60)) $((fy + 8)) sleep 0.2 dclick
        sleep 0.8
        read -r _ mx my mw mh <<<"$(focused)"
        if [ "$mw" -ge 1270 ] && [ "$mh" -ge 700 ]; then pass "double-click maximizes (${mw}x${mh})"; else fail "double-click: ${mw}x${mh}, expected the whole screen"; fi
        mouse move $((mx + 60)) $((my + 8)) sleep 0.2 dclick
        sleep 0.8
        read -r _ rx ry rw rh <<<"$(focused)"
        if [ "$rw" -lt 1200 ]; then pass "double-click again restores (${rw}x${rh})"; else fail "second double-click didn't restore (${rw}x${rh})"; fi

        # Drag the title bar to the left edge: snap to the left half
        read -r fid fx fy fw fh <<<"$(focused)"
        mouse move $((fx + 60)) $((fy + 8)) sleep 0.2 press move 300 300 move 150 300 move 40 300 move 0 300 sleep 0.4 release &
        mp=$!
        sleep 1.1
        shot "drag-snap-preview"
        wait $mp
        sleep 0.8
        read -r _ sx sy sw sh <<<"$(focused)"
        if [ "$sx" -le 2 ] && within "$sw" 640 16; then pass "drag to the left edge snaps (${sw}x${sh} at $sx,$sy)"; else fail "drag-snap: ${sw}x${sh} at $sx,$sy, expected the left half"; fi
        shot "snapped-left"

        # Tooltip on the Start button (hover while the screenshot is taken)
        mouse move 24 $((800 - 22)) sleep 1.6 &
        mp=$!
        sleep 1.3
        shot "tooltip-start"
        wait $mp
    else
        fail "no focused window for the pointer tests"
    fi

    mode_to tiling || true
fi

# ------------------------------------------------------------ search ----
if [ $QUICK = 0 ]; then
    for q in "blue" "check" "dark"; do
        ipc launcher search "$q"
        sleep 0.8
        shot "search-$q"
        ipc launcher hide
        sleep 0.3
    done
fi

# ------------------------------------------- chat: selection chip ----
if [ $QUICK = 0 ] && command -v wl-copy >/dev/null; then
    # The pointer rests where a selection would end; the chip should appear
    # just above it
    mouse move 700 500 sleep 3 &
    mp=$!
    sleep 0.3
    wl-copy --primary "Selected text: café ünïcode, with a second line" &
    wlcopy=$!
    sleep 1.6
    shot "chat-chip"
    wait $mp
    mouse move 700 470 sleep 0.2 click
    sleep 0.8
    shot "chat-from-selection"
    ipc chat hide
    kill "$wlcopy" 2>/dev/null || true
    sleep 0.3
fi

# ------------------------------------------------- display profiles ----
if [ $QUICK = 0 ]; then
    pos() { swaymsg -r -t get_outputs | python3 -I -c 'import json,sys; o=[x for x in json.load(sys.stdin) if x["name"]==sys.argv[1]]; print(o[0]["rect"]["x"], o[0]["rect"]["y"]) if o else print("none")' "$1"; }
    swaymsg -q create_output; sleep 0.5
    second=$(swaymsg -r -t get_outputs | python3 -I -c 'import json,sys; print([o["name"] for o in json.load(sys.stdin) if o["name"] != "HEADLESS-1"][0])')
    omadora-displays apply "[{\"name\": \"HEADLESS-1\", \"enabled\": true, \"mode\": \"\", \"scale\": 1, \"transform\": \"normal\", \"x\": 0, \"y\": 0},
        {\"name\": \"$second\", \"enabled\": true, \"mode\": \"\", \"scale\": 1, \"transform\": \"normal\", \"x\": 1280, \"y\": 0}]"
    sleep 0.3
    [ "$(pos "$second")" = "1280 0" ] && pass "displays: apply arranges screens" || fail "displays: $second at $(pos "$second"), expected 1280 0"
    omadora-displays save
    swaymsg -q output "$second" position 0 800; sleep 0.3
    omadora-displays restore; sleep 0.3
    [ "$(pos "$second")" = "1280 0" ] && pass "displays: profile restores the saved layout" || fail "displays: restore left $second at $(pos "$second")"
    if omadora-displays apply '[{"name": "HEADLESS-1", "enabled": false}]' 2>/dev/null; then
        fail "displays: allowed turning every screen off"
    else
        pass "displays: refuses to turn every screen off"
    fi
    shot "displays-two-screens"
    swaymsg -q output "$second" unplug; sleep 0.3
fi

# Anything the shell complained about (minus noise from the environment)
NOISE='desktopentry|propertyCache|Could not load icon|portal|socket disconnected|Failed to register|polkit|Polkit|bluez|NetworkManager|QDBusError|wl_registry|xdg-desktop|pipewire|settings.json failed: File does not exist'
if errors=$(grep -E 'ERROR|WARN.*(scene|qml)|TypeError|ReferenceError|is not a type|Binding loop|Unable to assign|is not defined' "$T/qs.log" | grep -Ev "$NOISE"); then
    fail "shell reported problems:"
    echo "$errors" | sed 's/\x1b\[[0-9;]*m//g' | sort | uniq -c | sort -rn | head -20 | sed 's/^/    /'
else
    pass "no shell errors ($( [ $QUICK = 1 ] && echo 3 modes || echo "$(wc -w <<<"$THEMES") themes × 3 modes, every panel"))"
fi
[ -n "$SHOTS" ] && printf '%s   screenshots: %s%s\n' "$dim" "$SHOTS" "$off"

[ "$failures" -eq 0 ] || { printf '%s%d check(s) failed%s\n' "$red" "$failures" "$off"; exit 1; }
printf '%sall checks passed%s\n' "$green" "$off"
