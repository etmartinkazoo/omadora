---
title: Themes
description: Seven built-in themes, live switching, and any Omarchy theme with one command.
section: Using omadora
order: 3
---

One theme colors everything at once, live and without restarting anything:

| What | How it follows the theme |
|------|--------------------------|
| Bar, popups, lock screen, wallpaper | instantly |
| Window borders (sway) | instantly |
| **kitty** (the default terminal) | instantly, in every open window |
| **Neovim** | instantly in every running Neovim using the `omadora` colorscheme (full Tree-sitter/LSP highlighting via mini.nvim when installed) |
| foot | instantly, if you use it |
| GTK apps and icons | light/dark and icon theme switch immediately |
| Firefox | instantly: toolbar, tabs, menus, sidebar, new tab page and the light/dark preference web pages see (the omadora Theme extension, installed by the `firefox` step) |
| tern | within a second |

To make Neovim follow the theme, set the colorscheme in your `init.lua` (after your plugins load):

```lua
vim.cmd.colorscheme("omadora")
```

## Switching

Press <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>T</kbd>, or click the theme in Quick Settings (the cog in the
bar), to open the picker. Arrow keys move, <kbd>Enter</kbd> applies (the picker stays open so you can compare), and
<kbd>B</kbd> / <kbd>Shift</kbd>+<kbd>B</kbd> step through the theme's wallpapers; click one in the strip below the themes to use it.

From a terminal:

```bash
omadora-theme list
omadora-theme set tokyo-night
omadora-theme next
omadora-theme bg-next
omadora-theme bg-prev
omadora-theme bg-set 2                       # third wallpaper of the current theme
```

## Built-in themes

| Theme | Mode | Character |
|-------|------|-----------|
| **candor** | dark | omadora's own: deep navy, clear blue accent. The default. |
| **graphite** | dark | Quiet and neutral, near-black with soft grey accents. |
| **candor-light** | light | candor for daytime: cool paper white, clear blue accent. |
| **graphite-light** | light | graphite for bright rooms: soft off-white, neutral grey accents. |
| **tokyo-night** | dark | Cool blues and purples, with synthwave wallpapers. |
| **catppuccin** | dark | Soft pastels on a warm dark base. |
| **flexoki-light** | light | Warm, paper-like light theme for bright rooms and daytime. |

Themes without wallpaper images get a generated one, drawn by the shell from the theme's colors,
so it's sharp at any resolution.

## More themes from Omarchy

omadora uses the same palette format as [Omarchy](https://github.com/omacom/omarchy), so its
themes, and the community's, install directly:

```bash
omadora-theme install omarchy:gruvbox        # any theme in Omarchy's repository
omadora-theme install omarchy:nord
omadora-theme install https://github.com/<user>/<omarchy-theme-repo>
omadora-theme set gruvbox
```

Omarchy ships, among others, everforest, gruvbox, kanagawa, matte-black, nord, osaka-jade,
ristretto, rose-pine, catppuccin-latte and white. Installed themes live in
`~/.local/share/omadora/themes/`; remove one with `omadora-theme remove <name>`.

> Imported themes are only used as data. Every color must be a plain hex value; anything else is
> ignored, so a theme can't smuggle commands into your configuration.

## Your own wallpaper

```bash
omadora-theme wallpaper ~/Pictures/my-wallpaper.jpg   # use it with every theme
omadora-theme wallpaper --clear                       # back to the theme's wallpapers
```

## Making a theme

A theme is a folder with a `colors.toml`, plus optionally a `backgrounds/` folder of images:

```toml
mode = "dark"

accent = "#7aa2f7"
background = "#1a1b26"
foreground = "#a9b1d6"
# … plus red, green, yellow, blue, magenta, cyan and their bright_ variants
```

Missing keys are derived from the ones you set. Put the folder in
`~/.local/share/omadora/themes/<name>/`, or run `omadora-theme install ./my-theme`. The full
key list and the template syntax are in the
[themes README](https://github.com/etmartinkazoo/omadora/tree/main/themes).

To theme another app (for example Alacritty, Ghostty, btop or tmux), add a template to `~/.config/omadora/templates/`. Each `*.tpl` file
there is rendered to `~/.local/state/omadora/theme/rendered/` on every theme change, using
tokens like `{{ accent }}`, `{{ background_strip }}` or `{{ mix background accent 30% }}`.
