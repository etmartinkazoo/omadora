---
title: Customizing
description: Change wallpaper, keyboard, displays, keybindings and themes without fighting updates.
section: Running it
order: 3
---

omadora separates **what it ships** from **what's yours**, so updates never overwrite your
changes and your changes never block updates.

## Per-machine settings: `80-local.conf`

For your own wallpaper, use `omadora-theme wallpaper ~/Pictures/wallpaper.jpg` rather than an
`output * bg` line: the shell draws the wallpaper, and sway's own wallpaper is turned off.

`~/.config/sway/config.d/80-local.conf` is yours and is never touched by updates. Use it for
anything specific to one machine or person:

```ini
# Displays: run `swaymsg -t get_outputs` for names
output eDP-1 scale 1.5
output DP-1 resolution 2560x1440 position 1920,0

# Keyboard
input "type:keyboard" {
    xkb_layout us,de
    xkb_options ctrl:nocaps,grp:alt_shift_toggle
}

## My apps
# Email
bindsym $mod+Shift+i exec thunderbird
```

Apply it with <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>C</kbd> (reload sway). New bindings show up in the
<kbd>Super</kbd>+<kbd>.</kbd> keybinds overlay automatically. A `## Heading` comment starts a section of the
overlay, and a `#` comment line just above a group of bindings becomes their description.

## Themes

Seven themes ship built in, and any Omarchy theme installs with one command. See [Themes](../themes/).

## Changing the desktop itself

The configuration is plain text in the [omadora repository](https://github.com/etmartinkazoo/omadora):

```
dotfiles/sway/        sway config and drop-ins
dotfiles/quickshell/  the shell (QML)
dotfiles/bin/         helper scripts
```

The installer already put a checkout in `~/omadora`, and your config files are symlinks into it.
Edit them there, and the shell reloads live. To re-link after changing the layout of the repository:

```bash
cd ~/omadora && ./install.sh --user-only dotfiles session
```

## What not to edit

Files that are **generated**: `omadora-theme` rewrites them whenever you switch theme.

- `~/.config/sway/config.d/99-theme.conf`
- `~/.config/kitty/theme.conf` (put your own kitty tweaks in `~/.config/kitty/local.conf`)
- `~/.config/nvim/colors/omadora.lua`
- `~/.config/foot/theme.ini`
- `~/.config/gtk-3.0/settings.ini` and `~/.config/gtk-4.0/settings.ini`

To change what they contain, override the template instead (see [Themes](../themes/#making-a-theme)).
