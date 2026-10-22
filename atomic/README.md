# omadora on Fedora Atomic

The omadora desktop as a **bootable container image** on top of
[Fedora Sway Atomic](https://fedoraproject.org/atomic-desktops/sway/). Everything in this repo
is baked into one image, and the OS updates as a whole:

- **Atomic updates**: an update is a new image, staged in the background and applied on reboot.
  It never half-applies.
- **Rollback**: the previous image stays installed. Pick it in the boot menu, or run
  `rpm-ostree rollback`.
- **Signed**: CI signs every image with cosign, and the image only accepts signed updates.
- **Read-only `/usr`**: the dotfiles live in `/usr/share/omadora` and are symlinked into your
  home on login, so an image update updates your desktop too.

## Install

1. Install **Fedora Sway Atomic 45** from the ISO, with disk encryption enabled.
   (Any Fedora Atomic edition works as the starting point.)
2. Run the bootstrap, then reboot when it asks:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/etmartinkazoo/omadora/main/bootstrap.sh | bash
   ```

   It trusts the omadora signing key (so even the first download is verified), rebases onto
   `ghcr.io/etmartinkazoo/omadora:latest` and clones the repo to `~/omadora`.
   `OMADORA_TAG=45` pins a Fedora release; `OMADORA_CHECKOUT=0` skips the clone.
3. Log into the **Sway** session. On first login, `omadora-setup.service` links the dotfiles
   and enables the services, and Quickshell and the phone daemon start.
4. Bring your own data over from the old machine, as a separate step:

   ```bash
   omadora-migrate --dry-run you@old-laptop   # see what would come over
   omadora-migrate you@old-laptop             # theme, settings, models, Firefox, SSH/GPG keys
   ```

   The phone pairing stays on the old machine unless you add `--phone` (which moves it); otherwise
   pair fresh with "Pair Phone" in the launcher.

The image ships `omadora-phone` and `whisper-cli` prebuilt (built in throwaway stages of the
Containerfile), so no compilers are installed. Building either from `~/omadora` puts it in
`~/.local/bin`, which takes precedence.

Without `bootstrap.sh`, the manual route is an unverified rebase, then a signed one:

```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/etmartinkazoo/omadora:latest
systemctl reboot
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/etmartinkazoo/omadora:latest
systemctl reboot
```

## Day to day

| Task | Command |
|------|---------|
| Status / pending update | `rpm-ostree status` |
| Update now (instead of waiting for the timer) | `rpm-ostree upgrade && systemctl reboot` |
| Roll back | `rpm-ostree rollback && systemctl reboot` |
| Add a package locally | `rpm-ostree install <pkg>` (better: add it to `packages/fedora.txt`) |
| GUI apps | Flatpak (`flatpak install flathub <app>`) |
| Dev tools | `toolbox create && toolbox enter` |

Updates are downloaded and staged automatically by `rpm-ostreed-automatic.timer`.

## Customizing

- Per-machine sway settings: `~/.config/sway/config.d/80-local.conf`.
- To hack on the desktop itself, work in `~/omadora` (bootstrap.sh clones it). The first login
  links from the checkout; after that, re-run `./install.sh --user-only dotfiles session phone`
  there yourself, and image updates leave your links alone.

## Building and publishing (maintainers)

CI (`.github/workflows/build-image.yml`) builds on every push to `main` and daily, to pick up
Fedora's base image updates. It pushes `ghcr.io/etmartinkazoo/omadora:{latest,45,45-YYYYMMDD}`
and signs the digest.

One-time setup:

```bash
cosign generate-key-pair                        # creates cosign.key + cosign.pub
mv cosign.pub atomic/cosign.pub && git add atomic/cosign.pub
gh secret set COSIGN_PRIVATE_KEY < cosign.key   # then delete cosign.key, or keep it offline
gh secret set COSIGN_PASSWORD                   # the password you chose
```

Then make the GHCR package public: GitHub → Packages → omadora → Package settings.

Local build (podman is preinstalled on Atomic):

```bash
podman build -f atomic/Containerfile -t localhost/omadora .
sudo bootc switch --transport containers-storage localhost/omadora   # test it on a spare machine/VM
```
