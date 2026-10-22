#!/usr/bin/env bash
# [root] Baseline hardening: automatic security updates, firewall, status checks.
#
#   OMADORA_KEEP_SSH=1    keep the ssh service open in the firewall
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# --- Automatic security updates -------------------------------------------
need_cmd dnf
if ! rpm -q dnf5-plugin-automatic >/dev/null 2>&1; then
    info "Installing dnf5-plugin-automatic"
    as_root dnf install -y dnf5-plugin-automatic
fi
info "Configuring automatic *security* updates (/etc/dnf/automatic.conf)"
if [ -f /etc/dnf/automatic.conf ] && ! grep -q 'omadora' /etc/dnf/automatic.conf; then
    as_root cp /etc/dnf/automatic.conf "/etc/dnf/automatic.conf.bak-$(date +%Y%m%d%H%M%S)"
fi
as_root tee /etc/dnf/automatic.conf >/dev/null <<'CONF'
# Managed by omadora (steps/20-system-security.sh).
# Security updates only, applied automatically; never reboots on its own.
[commands]
upgrade_type = security
random_sleep = 300
download_updates = yes
apply_updates = yes
reboot = never

[emitters]
emit_via = stdio
CONF
as_root systemctl enable --now dnf5-automatic.timer
ok "dnf5-automatic.timer enabled (security updates)"
if dnf repolist --enabled 2>/dev/null | grep -q '^updates-testing'; then
    warn "updates-testing is enabled: automatic updates will include testing packages."
fi

# --- Firewall ---------------------------------------------------------------
if command -v firewall-cmd >/dev/null 2>&1; then
    as_root systemctl enable --now firewalld
    zone=$(as_root firewall-cmd --get-default-zone)
    if [ "${OMADORA_KEEP_SSH:-0}" != 1 ] && ! systemctl is-enabled --quiet sshd 2>/dev/null \
        && as_root firewall-cmd --zone="$zone" --query-service=ssh >/dev/null 2>&1; then
        info "Closing ssh in firewall zone '$zone' (sshd isn't enabled; OMADORA_KEEP_SSH=1 to keep it)"
        as_root firewall-cmd --permanent --zone="$zone" --remove-service=ssh >/dev/null
        as_root firewall-cmd --reload >/dev/null
    fi
    ok "firewalld active, zone '$zone': $(as_root firewall-cmd --zone="$zone" --list-services)"
else
    warn "firewalld not installed"
fi

# --- Status checks (report only) ---------------------------------------------
if command -v getenforce >/dev/null 2>&1; then
    [ "$(getenforce)" = Enforcing ] && ok "SELinux enforcing" || warn "SELinux is $(getenforce); expected Enforcing"
fi
if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
        ok "Secure Boot enabled"
    else
        warn "Secure Boot is disabled: enable it in your firmware settings"
    fi
fi
root_src=$(findmnt -no SOURCE / | sed 's/\[.*//')
if [ "$(lsblk -no TYPE "$root_src" 2>/dev/null | head -n1)" = crypt ]; then
    ok "root filesystem is on LUKS"
else
    warn "root filesystem isn't encrypted: full-disk encryption (LUKS) is strongly recommended"
fi
