---
title: FAQ
description: Short answers to the questions people ask first.
section: Reference
order: 2
---

## Is omadora a Linux distribution?

No. It's a desktop built on Fedora: an installer that sets up the desktop and its security defaults
on a regular Fedora 45 system. Fedora remains the operating system, with Fedora's packages and
Fedora's security team.

## How is this different from Omarchy and other "riced" setups?

Most opinionated desktops are built on rolling-release distributions and fast-moving compositors:
exciting, but they ask you to absorb breakage. omadora makes the opposite trade. It runs on
Fedora's fixed releases, with sway, whose configuration has
stayed compatible for a decade. You get the polish without the maintenance.

## Why sway instead of Hyprland or GNOME?

sway is stable, fast and conservative: its configuration language is i3's, and it rarely breaks
anything between versions. Tiling is what makes a keyboard-first workflow fast, and Quickshell adds
the polish that tiling setups usually lack.

## Can I use Chrome, Slack, Zoom, VS Code…?

Yes. It's regular Fedora, so install them the way their vendors document for Fedora. Screen sharing works through the desktop portal
(xdg-desktop-portal-wlr).

## Does it work on multiple monitors?

Yes. Each screen gets its own bar showing its own workspaces, and popups open on the screen you're using.

## Do I have to use the keyboard?

No. Everything in the bar and popups is clickable. The keyboard is just faster once you know it.

## What hardware does it need?

Whatever Fedora supports. Intel and AMD graphics work best with sway. NVIDIA's proprietary driver
isn't officially supported by sway and needs extra setup.

## Who maintains it, and what does it cost?

It's developed in the open on [GitHub](https://github.com/etmartinkazoo/omadora), where issues and
pull requests are welcome.

## What does the name mean?

See [The name](../introduction/#the-name) in the introduction.
