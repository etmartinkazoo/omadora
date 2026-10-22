---
title: Security
description: What omadora protects against, how, and where its limits are.
section: Running it
order: 1
---

omadora's security model is simple: **secure defaults that need no attention**, built from
mature, audited components rather than custom inventions. This page lists every measure, so you
can verify each one yourself.

## The operating system

| Measure | What it protects against |
|---------|--------------------------|
| **Full-disk encryption (LUKS)**, chosen at install | Data theft from a lost or stolen machine |
| **Secure Boot** (you enable it in firmware) | Tampered bootloaders and kernels |
| **SELinux, enforcing** (Fedora default) | A compromised service reaching beyond its role |
| **Firewall on, ssh closed** | Network services you didn't mean to expose |

## Updates

Unpatched software is the most common way in, so updates are automatic:

`dnf5-automatic` installs Fedora's security updates on its own, and never reboots on its own.
Other updates are yours to apply with `sudo dnf upgrade`. See [Updates](../updates/).

## The desktop

### Bluetooth

Bluetooth pairing is **deny-by-default**. omadora's pairing agent rejects every pairing and
service request unless you started that pairing from the Bluetooth menu, and even then it only
accepts it for 90 seconds. The adapter is only pairable while the menu is open. This blocks
silent pairing by nearby devices, such as a fake keyboard injecting keystrokes
([CVE-2023-45866](https://nvd.nist.gov/vuln/detail/CVE-2023-45866) class).

### Lock screen

- Locks after 5 minutes idle, and **always before suspend**. Suspend waits until the compositor
  confirms that every screen is covered, so nothing flashes on resume.
- Uses the system's standard PAM authentication (the same stack as swaylock).
- Uses the Wayland session-lock protocol: if the shell crashed while locked, the session stays
  locked. A classic locker (swaylock) is the automatic fallback.

### Clipboard

History is capped at 200 entries, and entries marked sensitive by password managers are never
stored. It lives on your encrypted disk; clear it any time with **Clear All** or
`qs ipc call clipboard clear`.

### Apps and privileges

- Administrator prompts come from polkit, through the shell's dialog; nothing in the desktop runs as root.
- Wi-Fi passwords are passed to NetworkManager over a pipe, never on a command line that other
  processes could read.

## Supply chain

- System packages come from Fedora's signed repositories, installed with dnf.
- Fonts and icons are downloaded at pinned versions and **verified by SHA-256** before install.
- CI actions are pinned to commit hashes, not tags that could be moved.
- Everything is plain text in one git repository, so anyone can audit it.

## What omadora doesn't do

Be clear about these:

- It doesn't replace backups. Keep them, and keep them off the machine.
- It isn't an endpoint management (MDM) or antivirus product.
- Secure Boot and full-disk encryption depend on choices you make at install time.
- Third-party repositories and apps are only as trustworthy as their publishers.

## Verify it yourself

```bash
getenforce                             # Enforcing
mokutil --sb-state                     # SecureBoot enabled
lsblk -o NAME,TYPE,MOUNTPOINTS         # a "crypt" device under /
sudo firewall-cmd --list-services      # no ssh unless you need it
systemctl is-enabled dnf5-automatic.timer   # enabled
bluetoothctl show | grep Pairable      # "no" unless the Bluetooth menu is open
```
