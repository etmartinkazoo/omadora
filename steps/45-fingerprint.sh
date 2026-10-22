#!/usr/bin/env bash
# [root] Fingerprint for admin prompts (polkit) and sudo, when a reader exists.
# The lock screen needs nothing here: it ships its own fingerprint PAM stack
# and offers it whenever fingers are enrolled. Enroll with `fprintd-enroll`.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

user="${SUDO_USER:-$USER}"
if ! command -v fprintd-list >/dev/null || fprintd-list "$user" 2>&1 | grep -q 'No devices available'; then
    info "No fingerprint reader found; skipping."
    exit 0
fi

if command -v authselect >/dev/null; then
    as_root authselect enable-feature with-fingerprint
    ok "Fingerprint enabled for admin prompts and sudo (enroll with: fprintd-enroll)"
else
    warn "authselect not found; enable pam_fprintd for polkit-1 and sudo by hand."
fi
