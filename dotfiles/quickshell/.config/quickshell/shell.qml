//@ pragma UseQApplication
// omadora uses Tela icons everywhere. Pinned here rather than read from GTK
// settings, which Qt only reads at startup. App icons are the same in every
// Tela variant, so light and dark themes share it.
//@ pragma IconTheme Tela
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.I3

ShellRoot {
    id: root

    // First, so it stacks below every panel (see OutsideClick.qml)
    OutsideClick {}

    // Plugins (all themed via Theme.qml, popups coordinated by ShellState.qml)
    Launcher { id: launcher }
    Screenshot { id: screenshotTool }
    Audio { id: audioTool }
    Clipboard { id: clipboardTool }
    Battery { id: batteryTool }
    Media { id: mediaTool }
    NotificationCenter { id: notifCenter }
    Phone { id: phoneTool; btTool: btMenu }
    BluetoothMenu { id: btMenu }
    WifiMenu { id: wifiMenu }
    Caffeine {
        id: caffeineTool
        // The idle inhibitor needs a visible surface: the current mode's bar.
        readonly property var visibleBars: Desktop.mode === "windows" ? taskBars : (Desktop.mode === "macos" ? topBars : tilingBars)
        barWindow: visibleBars.instances.length > 0 ? visibleBars.instances[0] : null
    }
    NightLight { id: nightLightTool }
    Keybinds { id: keybindsTool }
    Dictation { id: dictationTool }
    SysMon { id: sysMon }
    LockScreen { id: lockScreen }
    Polkit { id: polkitAgent }

    Wallpaper {}
    ThemePicker { id: themePicker }
    SystemPanel { id: systemPanel; battery: batteryTool; sysmon: sysMon }
    Updates { id: updatesTool }
    Displays { id: displaysTool }
    Chat { id: chatTool }
    PanelFocus {}
    QuickSettings { id: quickSettings; nightLight: nightLightTool; caffeine: caffeineTool; updates: updatesTool }

    Switcher { id: switcher }
    TitleButtons {}
    Overview { id: overview }
    StartMenu { id: startMenu; launcher: launcher }

    // What the bars need from the tools above
    readonly property var tools: ({
        launcher: launcher, screenshot: screenshotTool, audio: audioTool, media: mediaTool,
        notifications: notifCenter, phone: phoneTool, bluetooth: btMenu, wifi: wifiMenu, battery: batteryTool,
        system: systemPanel, quick: quickSettings, themes: themePicker, overview: overview, start: startMenu
    })

    // Bars, one per monitor. Desktop.mode decides which are visible:
    // tiling = TilingBar, windows = TaskBar, macos = TopBar + Dock.
    Variants {
        id: tilingBars
        model: Quickshell.screens
        TilingBar { tools: root.tools }
    }
    Variants {
        id: taskBars
        model: Quickshell.screens
        TaskBar { tools: root.tools }
    }
    Variants {
        id: topBars
        model: Quickshell.screens
        TopBar { tools: root.tools }
    }
    Variants {
        model: Quickshell.screens
        Dock { tools: root.tools }
    }
}
