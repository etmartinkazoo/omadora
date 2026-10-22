---
title: Install on Fedora Atomic
description: The recommended setup. Rebase a Fedora Atomic install onto the omadora image.
section: Start here
order: 2
---

On Fedora Atomic, omadora ships as a **bootable container image**: the operating system, the
desktop, fonts, icons and security defaults, all built and tested together. Your machine runs
exactly that image, and updates replace it as a whole.

## 1. Install Fedora Sway Atomic

Download **Fedora Sway Atomic** from [fedoraproject.org/atomic-desktops/sway](https://fedoraproject.org/atomic-desktops/sway/)
and install it as usual.

> **Turn on disk encryption** in the installer. It's the single most important protection for a
> laptop that might be lost or stolen. Also enable **Secure Boot** in your firmware settings.

Any Fedora Atomic edition (Silverblue, Kinoite, and so on) works as a starting point, since the
rebase replaces the OS image.

## 2. Rebase to omadora

The first rebase fetches the image, including the key that verifies future updates. The second
switches to signature-verified updates, so from then on your machine only accepts images signed
by the omadora project.

```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/etmartinkazoo/omadora:latest
systemctl reboot
```

After the reboot:

```bash
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/etmartinkazoo/omadora:latest
systemctl reboot
```

To stay on one Fedora release instead of moving to new ones automatically, use the `:45` tag
instead of `:latest`.

## 3. Log in

Choose the **Sway** session at the login screen. On first login, `omadora-setup.service` links
the desktop configuration into your home directory, and the shell starts. Press <kbd>Super</kbd>+<kbd>/</kbd>
for the keybinding cheatsheet, or continue with [First steps](../first-steps/).

## Check that it worked

```bash
rpm-ostree status          # the booted image should be ghcr.io/etmartinkazoo/omadora
systemctl --user status quickshell
```

## Installing apps

On an image-based system, apps don't go into the OS image:

| Kind | How |
|------|-----|
| Desktop apps | **Flatpak**: `flatpak install flathub org.mozilla.Thunderbird`. Sandboxed, and updated independently. |
| Developer tools | **Toolbox**: `toolbox create && toolbox enter`, a mutable Fedora container sharing your home directory. |
| A system package you really need | `rpm-ostree install <package>` and reboot. Prefer asking for it to be added to the image. |
