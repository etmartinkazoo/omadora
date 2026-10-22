# Shared helpers for omadora install steps. Sourced, not executed.
# shellcheck shell=bash

OMADORA_ROOT="${OMADORA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OMADORA_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omadora"

if [ -t 1 ]; then
    _c_info=$'\033[1;34m' _c_ok=$'\033[1;32m' _c_warn=$'\033[1;33m' _c_err=$'\033[1;31m' _c_off=$'\033[0m'
else
    _c_info="" _c_ok="" _c_warn="" _c_err="" _c_off=""
fi

info() { printf '%s==>%s %s\n' "$_c_info" "$_c_off" "$*"; }
ok()   { printf '%s ok%s %s\n' "$_c_ok" "$_c_off" "$*"; }
warn() { printf '%swarn%s %s\n' "$_c_warn" "$_c_off" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$_c_err" "$_c_off" "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (run the system-packages step first)"
}

# True on rpm-ostree based systems (Fedora Atomic / bootc images).
is_atomic() {
    [ -e /run/ostree-booted ]
}

# Run a command as root, prompting via sudo when needed.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# download_verified URL SHA256 OUTFILE
# Downloads over HTTPS and refuses to continue unless the checksum matches.
download_verified() {
    local url=$1 sha=$2 out=$3
    need_cmd curl
    need_cmd sha256sum
    curl -fsSL --proto '=https' --tlsv1.2 -o "$out" "$url" || die "download failed: $url"
    echo "$sha  $out" | sha256sum -c --quiet - || die "checksum mismatch for $url"
}

# Package list without comments/blank lines: packages/fedora.txt, or the
# named list (e.g. `package_list build`).
package_list() {
    grep -Ev '^\s*(#|$)' "$OMADORA_ROOT/packages/${1:-fedora}.txt" | awk '{print $1}'
}
