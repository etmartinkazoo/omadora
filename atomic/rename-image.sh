#!/usr/bin/env bash
# omadora was called fedcandor, and so was its image. A machine still booted
# from ghcr.io/<owner>/fedcandor rebases onto .../omadora (same transport and
# tag); the switch applies on the next reboot. Run at boot by
# omadora-rename-image.service; does nothing once the machine has moved.
set -euo pipefail

# The booted image, and a staged one if there is one.
read -r ref staged < <(rpm-ostree status --json | python3 -c '
import json, sys
deps = json.load(sys.stdin)["deployments"]
ref = lambda d: d.get("container-image-reference") or "-"
booted = next((ref(d) for d in deps if d.get("booted")), "-")
staged = next((ref(d) for d in deps if d.get("staged")), "-")
print(booted, staged)')

case "$ref" in
    */fedcandor:*) ;;
    *) exit 0 ;;
esac
new=${ref/\/fedcandor:/\/omadora:}
if [ "$staged" = "$new" ]; then
    echo "omadora: $new is already staged for the next reboot"
    exit 0
fi
echo "omadora: rebasing $ref -> $new (applies on the next reboot)"
rpm-ostree rebase "$new"
