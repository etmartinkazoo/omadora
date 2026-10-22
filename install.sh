#!/usr/bin/env bash
# omadora installer: a stable, secure sway + Quickshell desktop for Fedora.
#
#   ./install.sh                run every step (asks for sudo for [root] steps)
#   ./install.sh --user-only    skip the [root] steps (packages, security)
#   ./install.sh fonts icons    run only the named steps
#   ./install.sh --list         show the steps
#
# Every step is idempotent: re-running is safe and is how you update.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

steps=()
while IFS= read -r -d '' f; do steps+=("$f"); done \
    < <(find "$OMADORA_ROOT/steps" -name '[0-9][0-9]-*.sh' -print0 | sort -z)

step_name() { basename "$1" .sh | sed 's/^[0-9]*-//'; }
step_desc() { sed -n '2s/^# //p' "$1"; }
is_root_step() { step_desc "$1" | grep -q '^\[root\]'; }

user_only=0
selected=()
for arg in "$@"; do
    case "$arg" in
        --user-only) user_only=1 ;;
        --list)
            for s in "${steps[@]}"; do printf '  %-18s %s\n' "$(step_name "$s")" "$(step_desc "$s")"; done
            exit 0 ;;
        -h|--help) sed -n '2,10s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) die "unknown option: $arg" ;;
        *) selected+=("$arg") ;;
    esac
done

[ -r /etc/fedora-release ] || warn "this doesn't look like Fedora; continuing anyway"
[ "$(id -u)" -ne 0 ] || die "run as your normal user; [root] steps use sudo themselves"

ran=0
for s in "${steps[@]}"; do
    name=$(step_name "$s")
    if [ ${#selected[@]} -gt 0 ]; then
        printf '%s\n' "${selected[@]}" | grep -qx "$name" || continue
    fi
    if [ "$user_only" = 1 ] && is_root_step "$s"; then
        info "skipping $name (root step)"
        continue
    fi
    info "step: $name — $(step_desc "$s")"
    bash "$s"
    ran=$((ran + 1))
done

[ "$ran" -gt 0 ] || die "no matching steps (see --list)"
ok "omadora: $ran step(s) done"
