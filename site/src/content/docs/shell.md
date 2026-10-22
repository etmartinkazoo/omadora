---
title: The shell
description: Everything the Quickshell desktop shell does, feature by feature.
section: Using omadora
order: 2
---

The shell is one Quickshell program, themed as a whole and run as a systemd service that restarts
itself if it ever crashes. Only one popup is open at a time, and it opens on the screen you're using.

## Launcher

<kbd>Super</kbd>+<kbd>Space</kbd> or <kbd>Super</kbd>+<kbd>D</kbd> (the Start menu in Windows mode). One search
for everything: apps (the ones you launch often rise to the top), open windows, settings and actions
("bluetooth", "dark", "lock", "displays", "macos"…) and files in your home folder. Each result is
labeled. Other inputs:

- `= 1240 * 1.0825` evaluates arithmetic; <kbd>Enter</kbd> copies the result.
- If nothing matches, <kbd>Enter</kbd> runs what you typed as a shell command.

Launched apps run in their own systemd scope, so restarting the shell never closes your work.

## Chat

<kbd>Super</kbd>+<kbd>A</kbd> opens a chat on the left: a running conversation for thinking out loud about
ideas, plans and writing. It keeps going between sessions; **NEW** starts over. Replies stream in and
render Markdown. Select text in any app and an **Ask in chat** chip appears right above it for a few
seconds (turn it off with the chip toggle in the chat header); <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>A</kbd>
sends the selection directly.

Under the hood it's [opencode](https://opencode.ai) with the free DeepSeek model, through the opencode
service. The chat is conversation only: every tool the model asks for (running commands, reading
files) is refused, so it never touches your machine. Selections stay in memory and reach the chat
only when you click.

## Clipboard history

<kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>V</kbd>. The last 200 copies (text and images, with image previews),
searchable. <kbd>Enter</kbd> copies an entry back; <kbd>Del</kbd> or right-click removes one. Copies that a
password manager marks as sensitive are never recorded.

## Screenshots and recording

<kbd>Print</kbd>. Choose a **target** (area, window or screen) and an **action**:

| Action | Result |
|--------|--------|
| Copy | Image to the clipboard |
| Save | PNG in `~/Pictures/Screenshots` |
| Annotate | Opens in swappy to draw, highlight and blur |
| Record | MP4 screen recording. Stop it from the red `● REC` pill in the bar. |

<kbd>D</kbd> cycles a 3, 5 or 10 second delay.

## Notifications

Pop-ups appear at the top right and pause while you hover over them. Clicking a notification runs its
default action (usually opening the app it came from), and right-click dismisses it. Action buttons (Reply, Open, and so on) work.
**Do Not Disturb** (<kbd>D</kbd> in the center, or right-click the bell) silences everything except
critical alerts, such as low battery. History is kept in the notification center
(<kbd>Super</kbd>+<kbd>N</kbd>).

## Wi-Fi and DNS

Connect, disconnect and forget networks; passwords are passed to NetworkManager privately, never
on a command line. The DNS row switches the current connection between automatic, **Cloudflare**
(1.1.1.1, IPv4 and IPv6) and **custom** servers.

## Bluetooth

Scan, pair, connect and forget devices, with battery levels where available. Pairing is
**deny-by-default**: see [Security](../security/#bluetooth).

## Audio

Output and input volume, device switching (speakers, headphones, HDMI, Bluetooth, …), per-application volume and
mute, and a microphone mute indicator. Volume, mic and brightness keys show an on-screen display.

## Quick settings

The cog in the bar gathers appearance and everyday toggles in one place: the current theme (click
for the [theme picker](../themes/)), screen brightness, **warmth** (night light: Off, Auto or On,
with a slider), **keep awake** (stops the screen sleeping during a presentation), **Do Not Disturb**, and
one-click access to the screenshot tool, clipboard history and the shortcut cheatsheet.

**Auto** warmth follows the sun: warm from sunset to sunrise, neutral by day. The times are worked
out from your timezone's coordinates in the system's timezone database, so no location service is
involved and nothing leaves your machine. If the timezone can't be mapped, Auto uses 19:00–07:00.

## System

The right-most button shows the battery and opens the System panel: charge, time remaining,
battery health, live CPU, memory and temperature, power profiles (saver, balanced, performance),
and lock, suspend, log out, reboot and power off. Log out, reboot and power off ask for a second
press. At 15% battery you get a warning; at 5% the machine suspends after a 60-second countdown,
unless you plug in. <kbd>M</kbd> opens a task manager (`top`).

## Updates

Quick Settings → **Updates** (<kbd>U</kbd>). The panel counts what dnf has, and **Update** / **Undo last** open a terminal running `sudo dnf upgrade` /
`sudo dnf history undo last`, so you see and confirm the changes. The shell checks every 6 hours,
notifies once when something new is ready, and shows 󰚰 on the Quick Settings pill.

## Displays

Quick Settings → **Displays** (<kbd>P</kbd>), or <kbd>Super</kbd>+<kbd>Ctrl</kbd>+<kbd>D</kbd>. Drag screens to
arrange them (they snap edge to edge), and pick each screen's resolution, scale and rotation.
**Apply** asks "Keep these settings?" and reverts after 15 seconds unless you confirm, so a mode
your screen can't show never strands you. Keeping saves the layout for that set of screens: plug
the same screens in again (your desk, a projector) and the layout comes back by itself.
`omadora-displays` does the same from a terminal.

## Lock screen

The lock screen locks after 5 minutes idle, before suspend, or from the System panel (<kbd>L</kbd>).
It uses the system's standard login authentication (PAM), and the compositor keeps the session
locked even if the shell were to crash.

## Everything else

- **Themes**: seven built in, plus any Omarchy theme; one switch recolors everything. See [Themes](../themes/).
- **Polkit dialog**: a themed password prompt when an app needs administrator rights.
- **System tray**: icons and menus for apps that provide them.
- **Keybinds overlay**: <kbd>Super</kbd>+<kbd>.</kbd> (or <kbd>Super</kbd>+<kbd>/</kbd>) shows every binding on one
  screen, grouped and filterable, generated from your live sway configuration.

## Desktop modes

The same shell comes in three layouts. Switch in Quick Settings (<kbd>M</kbd>), with
<kbd>Super</kbd>+<kbd>Ctrl</kbd>+<kbd>M</kbd>, or with `omadora-mode set tiling|windows|macos`.

| Mode | Bar | Windows |
|------|-----|---------|
| **Tiling** (default) | bar along the bottom | sway tiles them |
| **Windows** | taskbar along the bottom: start button, app buttons, clock | float, with title bars |
| **macOS** | bar along the top, plus a dock | float, with title bars |

In Windows mode, the Fedora button at the left of the taskbar (or <kbd>Super</kbd>+<kbd>Space</kbd>)
opens the Start menu: search, your pinned apps, your most used apps, and an A–Z list of all apps.
Right-click any app there to pin or unpin it. The footer locks, suspends, or opens the power menu.

In the taskbar and the dock, click an app to switch to it (click again to minimize; with several
windows, clicks cycle through them), middle-click for a new window, and right-click to pin or unpin
it. Minimized windows go to the scratchpad: <kbd>Super</kbd>+<kbd>M</kbd> minimizes,
<kbd>Super</kbd>+<kbd>-</kbd> brings one back.

The focused floating window gets minimize, maximize and close buttons in its title bar (traffic
lights on the left in macOS mode). Double-click a title bar to maximize. Drag a window to a screen
edge to snap it: left or right for half the screen, a corner for a quarter, the top to maximize.
From the keyboard, <kbd>Super</kbd>+<kbd>Alt</kbd>+arrows snap the same way.

Windows and macOS modes add Alt shortcuts for the focused window: <kbd>Alt</kbd>+<kbd>M</kbd> maximize,
<kbd>Alt</kbd>+<kbd>F</kbd> fullscreen, <kbd>Alt</kbd>+<kbd>A</kbd> / <kbd>S</kbd> snap left / right,
<kbd>Alt</kbd>+<kbd>H</kbd> hide the app, <kbd>Alt</kbd>+<kbd>W</kbd> close, and <kbd>Alt</kbd>+<kbd>D</kbd> show
the desktop (again brings everything back). They take those keys from apps in these modes (Firefox's
<kbd>Alt</kbd>+<kbd>D</kbd>, for example); tiling mode leaves Alt alone.

Hover an app in the taskbar or dock to see its windows; a red badge counts its notifications since
you last switched to it. <kbd>Super</kbd>+<kbd>Ctrl</kbd>+<kbd>↑</kbd> (or the taskbar's overview
button) shows every window at once: type to filter, click to switch.

In every mode, <kbd>Super</kbd>+<kbd>Tab</kbd> switches apps and <kbd>Alt</kbd>+<kbd>Tab</kbd>
switches between the current app's windows: hold the modifier, tap <kbd>Tab</kbd> to move (<kbd>Shift</kbd> goes back), and
release to switch.

## Fingerprint

With a fingerprint reader, enroll a finger (`fprintd-enroll`) and the lock screen accepts it
alongside your password. `./install.sh fingerprint` also turns it on for admin prompts and `sudo`.

## Scripting it

Every popup and toggle is scriptable over IPC, so you can bind anything to a key:

```bash
qs ipc show                         # list every target and function
qs ipc call launcher toggle
qs ipc call notifications toggleDnd
qs ipc call nightlight setTemperature 3500
```
