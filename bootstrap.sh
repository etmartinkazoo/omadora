#!/usr/bin/env bash
# omadora bootstrap: turn a fresh Fedora 45 install into omadora.
#
#   curl -fsSL https://raw.githubusercontent.com/etmartinkazoo/omadora/main/bootstrap.sh | bash
#
# Installs git, clones the repo to ~/omadora (or updates it), and runs
# ./install.sh, which asks for sudo for its [root] steps. Then log into the
# Sway session. Your own data comes over separately: omadora-migrate.
#
#   OMADORA_REPO=...   clone from a fork instead
#   OMADORA_DIR=...    clone somewhere other than ~/omadora
#
# Everything sits inside main(), so a download cut off halfway runs nothing.
set -euo pipefail

main() {
    local repo=${OMADORA_REPO:-https://github.com/etmartinkazoo/omadora}
    local dir=${OMADORA_DIR:-$HOME/omadora}

    [ -r /etc/fedora-release ] || { echo "omadora needs Fedora 45" >&2; exit 1; }
    if [ -e /run/ostree-booted ]; then
        echo "Fedora Atomic isn't supported: install regular Fedora 45 (e.g. the Sway spin)" >&2
        exit 1
    fi
    [ "$(id -u)" -ne 0 ] || { echo "run as your normal user; the installer uses sudo where needed" >&2; exit 1; }

    command -v git >/dev/null 2>&1 || sudo dnf install -y git
    if [ -d "$dir/.git" ]; then
        git -C "$dir" pull --ff-only
    else
        git clone "$repo" "$dir"
    fi

    # The installer reads its sudo prompt from the terminal, not this pipe.
    if [ -r /dev/tty ]; then
        "$dir/install.sh" </dev/tty
    else
        "$dir/install.sh"
    fi

    cat <<EOF

omadora is installed. Next:
  1. Log out and into the Sway session (or reboot).
  2. Bring your data over from another machine (separate on purpose):
       omadora-migrate --dry-run you@old-laptop
       omadora-migrate you@old-laptop
  3. Pair the phone: "Pair Phone" in the launcher.
EOF
}

main "$@"
