#!/usr/bin/env bash
# [root] Install the packages omadora depends on.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

need_cmd dnf
mapfile -t pkgs < <(package_list)
info "Installing ${#pkgs[@]} packages with dnf"
as_root dnf install -y "${pkgs[@]}"
ok "packages installed"
