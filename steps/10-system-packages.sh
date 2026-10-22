#!/usr/bin/env bash
# [root] Install the packages omadora depends on.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

if is_atomic; then
    info "Fedora Atomic detected: packages come from the omadora image, skipping dnf."
    info "To add one-off packages there, use: rpm-ostree install <pkg>"
    exit 0
fi

need_cmd dnf
mapfile -t pkgs < <(package_list; package_list build)
info "Installing ${#pkgs[@]} packages with dnf"
as_root dnf install -y "${pkgs[@]}"
ok "packages installed"
