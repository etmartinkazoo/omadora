---
title: First steps
description: The shortcuts that cover most of your day, and a tour of the bar.
section: Using omadora
order: 1
---

<kbd>Super</kbd> is the Windows/Command key. Press <kbd>Super</kbd>+<kbd>.</kbd> (or <kbd>Super</kbd>+<kbd>/</kbd>)
at any time to see every keybinding on one screen, generated live from your sway configuration. Type to filter.

Coming from [Omarchy](https://omarchy.org)? Most of its shortcuts work here too: <kbd>Super</kbd>+<kbd>Space</kbd>,
<kbd>Super</kbd>+<kbd>T</kbd>, <kbd>Super</kbd>+<kbd>Escape</kbd>, <kbd>Super</kbd>+<kbd>M</kbd>,
<kbd>Alt</kbd>+<kbd>Tab</kbd> and the <kbd>Super</kbd>+<kbd>Ctrl</kbd> panel keys. The exception is
<kbd>Super</kbd>+<kbd>H</kbd>/<kbd>J</kbd>/<kbd>K</kbd>/<kbd>L</kbd>, which omadora keeps for vim-style movement.

## The essentials

| Shortcut | Action |
|----------|--------|
| <kbd>Super</kbd>+<kbd>Space</kbd> or <kbd>Super</kbd>+<kbd>D</kbd> | App launcher. Type to fuzzy-search; type `=` to use it as a calculator. |
| <kbd>Super</kbd>+<kbd>Return</kbd> | Terminal (kitty) |
| <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>Return</kbd> | Firefox |
| <kbd>Super</kbd>+<kbd>Q</kbd> | Close the focused window |
| <kbd>Super</kbd>+<kbd>1</kbd> … <kbd>0</kbd> | Switch to workspace 1–10 |
| <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>1</kbd> … <kbd>0</kbd> | Move the window to workspace 1–10 |
| <kbd>Super</kbd>+<kbd>H</kbd>/<kbd>J</kbd>/<kbd>K</kbd>/<kbd>L</kbd> or arrows | Move focus left/down/up/right |
| <kbd>Super</kbd>+<kbd>Tab</kbd> | Switch apps (hold <kbd>Super</kbd>, tap <kbd>Tab</kbd>, release) |
| <kbd>Alt</kbd>+<kbd>Tab</kbd> | Switch between the current app's windows (hold <kbd>Alt</kbd>, tap <kbd>Tab</kbd>, release) |
| <kbd>Super</kbd>+<kbd>Ctrl</kbd>+<kbd>←</kbd>/<kbd>→</kbd> | Previous / next workspace |
| <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>V</kbd> | Clipboard history |
| <kbd>Super</kbd>+<kbd>A</kbd> | Chat: a side conversation for ideas (select text anywhere to bring it in) |
| <kbd>Print</kbd> or <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd> | Screenshot and screen recording |
| <kbd>Super</kbd>+<kbd>N</kbd> | Notification center |
| <kbd>Super</kbd>+<kbd>Escape</kbd> or <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>E</kbd> | System panel: battery, power profiles, lock, suspend, log out, reboot, power off |
| <kbd>Super</kbd>+<kbd>Ctrl</kbd>+<kbd>L</kbd> | Lock the screen |
| <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>T</kbd> | Theme picker |

## Windows and layouts

sway tiles windows automatically: a new window takes half the space of the focused one.

| Shortcut | Action |
|----------|--------|
| <kbd>Super</kbd>+<kbd>F</kbd> | Fullscreen |
| <kbd>Super</kbd>+<kbd>T</kbd> or <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>Space</kbd> | Toggle floating |
| <kbd>Super</kbd>+<kbd>O</kbd> | Pop a window out: floating, and shown on every workspace |
| <kbd>Super</kbd>+<kbd>B</kbd> / <kbd>V</kbd> | Next window splits horizontally / vertically |
| <kbd>Super</kbd>+<kbd>W</kbd> / <kbd>S</kbd> / <kbd>E</kbd> | Tabbed / stacked / split layout |
| <kbd>Super</kbd>+<kbd>R</kbd> | Resize mode: arrows or H/J/K/L, then <kbd>Esc</kbd> |
| <kbd>Super</kbd>+<kbd>Minus</kbd> | Show/hide the scratchpad (a hidden floating window) |
| <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>Minus</kbd> | Send the window to the scratchpad |
| Hold <kbd>Super</kbd> and drag | Move a window with the left mouse button, resize with the right |

## A tour of the bar

The bar runs along the bottom of every screen.

**Left:** `LAUNCH`, your workspaces (urgent ones glow red), the current media track, and a red
`● REC` timer while you're recording the screen.

**Center:** the date and time.

**Right**, from left to right:

| Item | Click | Other |
|------|-------|-------|
| App tray icons | Activate | Right-click for the app's menu |
| **Quick settings** (cog) | Theme, brightness, warmth (night light: off/auto/on), keep awake, Do Not Disturb, and the screenshot, clipboard and shortcut tools | Shows a cup while keep awake is on, and a crossed bell in Do Not Disturb |
| Volume | Audio mixer | Right-click mutes · scroll to adjust · shows a crossed mic when the microphone is muted |
| Wi-Fi | Networks & DNS | |
| Bluetooth | Devices | Right-click toggles power |
| Bell | Notification center | Right-click toggles Do Not Disturb |
| **System** (battery · power) | Battery, CPU/memory/temperature, power profiles, lock, suspend, log out, reboot, power off | Turns red when the battery is low |

Every popup is keyboard driven: its bottom line shows the keys, and <kbd>Esc</kbd> closes it.
