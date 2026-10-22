#!/usr/bin/env bash
# omadora bootstrap: turn a fresh Fedora Atomic install into omadora.
#
#   curl -fsSL https://raw.githubusercontent.com/etmartinkazoo/omadora/main/bootstrap.sh | bash
#
# 1. Trusts the omadora image signing key (atomic/cosign.pub), so even the
#    first download is verified, and every update after it.
# 2. Rebases the OS onto ghcr.io/etmartinkazoo/omadora (packages, fonts,
#    icons, Firefox extension, omadora-phone, whisper-cli, user services).
# 3. Clones the repo to ~/omadora, so you can hack on the desktop.
# Then reboot and log into Sway: the first login links the dotfiles and
# starts everything. Your own data comes over separately: omadora-migrate.
#
#   OMADORA_TAG=45          pin a Fedora release (default: latest)
#   OMADORA_CHECKOUT=0      don't clone ~/omadora (use the image's copy)
#   OMADORA_REBOOT=1        reboot without asking
set -euo pipefail

IMAGE=${OMADORA_IMAGE:-ghcr.io/etmartinkazoo/omadora}
TAG=${OMADORA_TAG:-latest}
REPO=${OMADORA_REPO:-https://github.com/etmartinkazoo/omadora}
RAW=${OMADORA_RAW:-https://raw.githubusercontent.com/etmartinkazoo/omadora/main}

if [ -t 1 ]; then b=$'\033[1;34m' g=$'\033[1;32m' y=$'\033[1;33m' r=$'\033[1;31m' o=$'\033[0m'; else b="" g="" y="" r="" o=""; fi
info() { printf '%s==>%s %s\n' "$b" "$o" "$*"; }
ok()   { printf '%s ok%s %s\n' "$g" "$o" "$*"; }
warn() { printf '%swarn%s %s\n' "$y" "$o" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$r" "$o" "$*" >&2; exit 1; }

[ -e /run/ostree-booted ] || die "this isn't Fedora Atomic. On regular Fedora: git clone $REPO ~/omadora && ~/omadora/install.sh"
[ "$(id -u)" -ne 0 ] || die "run as your normal user; it uses sudo where needed"

booted_ref=$(rpm-ostree status --json | python3 -c '
import json, sys
for d in json.load(sys.stdin)["deployments"]:
    if d.get("booted"):
        print(d.get("container-image-reference", ""))')

# --- 1. Signing key ---------------------------------------------------------
key=$(mktemp)
trap 'rm -f "$key"' EXIT
if curl -fsSL --proto '=https' --tlsv1.2 -o "$key" "$RAW/atomic/cosign.pub" 2>/dev/null; then
    info "Trusting the omadora signing key for $IMAGE"
    sudo install -Dm644 "$key" /etc/pki/containers/omadora.pub
    printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "$IMAGE" \
        | sudo install -Dm644 /dev/stdin /etc/containers/registries.d/omadora.yaml
    policy=$(python3 - "$IMAGE" <<'PY'
import json, sys
try:
    with open("/etc/containers/policy.json") as f:
        p = json.load(f)
except FileNotFoundError:  # Fedora's default
    p = {"default": [{"type": "insecureAcceptAnything"}]}
p.setdefault("transports", {}).setdefault("docker", {})[sys.argv[1]] = [{
    "type": "sigstoreSigned",
    "keyPath": "/etc/pki/containers/omadora.pub",
    "signedIdentity": {"type": "matchRepository"},
}]
print(json.dumps(p, indent=4))
PY
)
    printf '%s\n' "$policy" | sudo install -m644 /dev/stdin /etc/containers/policy.json
    ref="ostree-image-signed:docker://$IMAGE:$TAG"
    ok "updates must be signed with this key"
else
    warn "the repo publishes no signing key (atomic/cosign.pub) yet: the image can't be verified"
    ref="ostree-unverified-registry:$IMAGE:$TAG"
fi

# --- 2. The omadora image -------------------------------------------------
if [ "$booted_ref" = "$ref" ]; then
    ok "already running $ref"
    rebased=0
else
    info "Rebasing onto $IMAGE:$TAG (downloads the whole OS image; takes a while)"
    sudo rpm-ostree rebase "$ref"
    rebased=1
fi

# --- 3. Checkout --------------------------------------------------------------
if [ "${OMADORA_CHECKOUT:-1}" = 1 ]; then
    if [ -d "$HOME/omadora/.git" ]; then
        ok "~/omadora already checked out"
    elif command -v git >/dev/null 2>&1; then
        info "Cloning $REPO to ~/omadora"
        git clone --quiet "$REPO" "$HOME/omadora"
        ok "cloned; the first login links the dotfiles from it"
    else
        warn "git isn't installed yet: after the reboot, run: git clone $REPO ~/omadora"
    fi
fi

cat <<EOF

${g}omadora is staged.${o} Next:
  1. Reboot and log into the ${b}Sway${o} session: the first login links the
     dotfiles and starts Quickshell and the phone daemon.
  2. Bring your data over from the old machine (separate on purpose):
       omadora-migrate --dry-run you@old-laptop
       omadora-migrate you@old-laptop
  3. Pair the phone: "Pair Phone" in the launcher.
EOF

[ "$rebased" = 1 ] || exit 0
if [ "${OMADORA_REBOOT:-0}" = 1 ]; then
    systemctl reboot
elif [ -r /dev/tty ]; then
    read -r -p "Reboot now? [Y/n] " answer </dev/tty || answer=n
    case "$answer" in [nN]*) echo "Reboot when ready: systemctl reboot" ;; *) systemctl reboot ;; esac
else
    echo "Reboot when ready: systemctl reboot"
fi
