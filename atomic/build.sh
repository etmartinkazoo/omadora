#!/usr/bin/env bash
# Runs inside the image build (as root). Bakes packages, fonts, icons, user
# units and security defaults into the image (omadora-phone and whisper-cli
# arrive prebuilt from the Containerfile's build stages); per-user dotfiles are linked
# from /usr/share/omadora at login by omadora-setup.service.
set -euo pipefail

ROOT=/usr/share/omadora
IMAGE_REF=${IMAGE_REF:-ghcr.io/etmartinkazoo/omadora}
source "$ROOT/lib/common.sh"

info "Packages"
mapfile -t pkgs < <(package_list)
dnf5 -y install --setopt=install_weak_deps=False "${pkgs[@]}"
# Quickshell is the notification daemon, bar and polkit agent: remove what
# would compete for the same D-Bus names or duplicate the bar.
for p in mako dunst swaync waybar lxqt-policykit; do
    if rpm -q "$p" >/dev/null 2>&1; then dnf5 -y remove "$p"; fi
done
dnf5 clean all

info "Fonts and icons (system-wide)"
OMADORA_FONT_DIR=/usr/share/fonts/0xProto bash "$ROOT/steps/30-fonts.sh"
OMADORA_ICON_DIR=/usr/share/icons bash "$ROOT/steps/40-icons.sh"
fc-cache -f >/dev/null

info "Firefox theme extension"
OMADORA_FIREFOX_PREFIX=/usr bash "$ROOT/steps/25-firefox.sh"

info "User units"
install -Dm644 "$ROOT/dotfiles/systemd/.config/systemd/user/quickshell.service" \
    /usr/lib/systemd/user/quickshell.service
install -Dm644 "$ROOT/dotfiles/systemd/.config/systemd/user/omadora-phone.service" \
    /usr/lib/systemd/user/omadora-phone.service
install -Dm644 "$ROOT/atomic/omadora-setup.service" /usr/lib/systemd/user/omadora-setup.service
systemctl --global enable quickshell.service omadora-phone.service omadora-setup.service

# Installs from before the rename track ghcr.io/.../fedcandor: move them over.
install -Dm644 "$ROOT/atomic/omadora-rename-image.service" /usr/lib/systemd/system/omadora-rename-image.service
systemctl enable omadora-rename-image.service

info "Security defaults"
# Image updates are downloaded and staged automatically, applied on reboot;
# the previous image stays bootable for rollback.
sed -i 's/^#\?AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=stage/' /etc/rpm-ostreed.conf
systemctl enable rpm-ostreed-automatic.timer firewalld.service
zone=$(firewall-offline-cmd --get-default-zone)
firewall-offline-cmd --zone="$zone" --remove-service=ssh >/dev/null 2>&1 || true

# Only accept updates for this image when they're signed with our key.
if [ -f "$ROOT/atomic/cosign.pub" ]; then
    install -Dm644 "$ROOT/atomic/cosign.pub" /etc/pki/containers/omadora.pub
    install -Dm644 /dev/stdin /etc/containers/registries.d/omadora.yaml <<YAML
docker:
  ${IMAGE_REF}:
    use-sigstore-attachments: true
YAML
    tmp=$(mktemp)
    jq --arg ref "$IMAGE_REF" \
        '.transports.docker[$ref] = [{"type": "sigstoreSigned", "keyPath": "/etc/pki/containers/omadora.pub", "signedIdentity": {"type": "matchRepository"}}]' \
        /etc/containers/policy.json > "$tmp"
    install -m644 "$tmp" /etc/containers/policy.json
    rm -f "$tmp"
else
    warn "atomic/cosign.pub missing: image signature verification not configured"
fi

echo "${IMAGE_VERSION:-dev}" > "$ROOT/IMAGE_VERSION"
ok "omadora image build done (${IMAGE_VERSION:-dev})"
