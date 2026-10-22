---
title: Troubleshooting
description: Fixes for the things most likely to go wrong, and where to look when something does.
section: Reference
order: 1
---

## The bar or popups disappeared

The shell runs as a systemd user service and restarts itself after a crash. To check it or
restart it by hand:

```bash
systemctl --user status quickshell
systemctl --user restart quickshell
journalctl --user -u quickshell -n 100    # logs, including QML errors
```

## The screen is locked and won't accept my password

Check the keyboard layout and Caps Lock first. If the lock screen itself is broken:

1. Switch to a text console with <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>F3</kbd> and log in.
2. Run `systemctl --user restart quickshell`. The session stays locked.
3. Switch back with <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>F1</kbd> (or <kbd>F2</kbd>) and unlock.
4. If that doesn't help: `WAYLAND_DISPLAY=wayland-1 swaylock` from the console starts the
   fallback locker.

## An update broke something

On Atomic, boot the previous image: choose it in the boot menu, or run
`rpm-ostree rollback && systemctl reboot`. Then please
[open an issue](https://github.com/etmartinkazoo/omadora/issues).

## A Bluetooth device won't pair

Open the Bluetooth menu **before** putting the device into pairing mode, keep the menu open, and
click the device. Pairing is only accepted for devices you click. The agent's log is at
`~/.cache/quickshell-bluez-agent.log`.

## No sound, or the wrong output

Open the audio mixer (click the volume in the bar) and pick the output device. For deeper issues:
`wpctl status`.

## Wi-Fi password not accepted

Forget the network (select it and press <kbd>F</kbd>), then connect again. NetworkManager's own log:
`journalctl -u NetworkManager --since "10 min ago"`.

## Fonts or icons look wrong

```bash
fc-list | grep -i 0xproto                         # the font is installed
gsettings get org.gnome.desktop.interface icon-theme
cd ~/omadora && ./install.sh fonts icons        # Workstation: reinstall them
omadora-theme refresh                           # re-apply the theme everywhere
```
