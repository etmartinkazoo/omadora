---
title: Introduction
description: What omadora is, who it's for, and why it's built on Fedora Atomic, sway and Quickshell.
section: Start here
order: 1
---

omadora is a complete desktop for people whose computer is a tool for work. It combines three
mature open-source projects, and each one covers one side of the job:

| Layer | Project | What it gives you |
|-------|---------|-------------------|
| Operating system | **Fedora Atomic** | Stability and security. The OS is an image: updates apply in one step or not at all, and the previous version is always one reboot away. |
| Window manager | **sway** | Productivity. Keyboard-first tiling: every window has a place, nothing overlaps, nothing needs dragging. |
| Desktop shell | **Quickshell** | Beauty. One coherent, themed shell for the bar, launcher, notifications, clipboard, screenshots, Wi-Fi, Bluetooth, audio, lock screen and more. |

Usually you have to pick two: a stable system that's dull, a beautiful one that breaks on
updates, or a fast one you spend weekends maintaining. omadora's premise is that you don't
have to choose any more.

## Who it's for

- **Business owners** who want company machines that stay up, stay patched and stay out of the way.
- **Admins** who want one signed image to roll out, pin, test and roll back across a whole team.
- **Employees** who just want a fast, calm desktop that's the same every morning.
- **Power users** who live on the keyboard and want every action a keystroke away.

## Principles

1. **Boring where it matters.** Fedora's fixed releases and an image-based OS, not a rolling distribution.
2. **Secure by default.** Encryption, SELinux, a closed firewall, automatic updates, and deny-by-default
   Bluetooth pairing, with no setup required. See [Security](../security/).
3. **Keyboard first, mouse friendly.** Everything has a shortcut, and everything is also clickable.
4. **One look.** A single theme drives the bar, popups, window borders, terminal, GTK icons and Firefox.
5. **Readable configuration.** Plain text in a git repository: no hidden state, and you can audit all of it.

## The name

**omadora** is *Fedora* + *candor*. In Latin, *candor* means brilliance or radiance (literally,
dazzling whiteness), and also sincerity and openness. Both meanings apply: a desktop that's a
pleasure to look at, and one that's honest about what it does. Every line of it is open and auditable.

## Two ways to run it

- **[Fedora Atomic](../install-atomic/)** (recommended): the whole desktop as a signed, bootable
  image, with atomic updates and rollback.
- **[Fedora Workstation](../install-workstation/)**: the same desktop installed on a regular Fedora
  system by an idempotent script.
