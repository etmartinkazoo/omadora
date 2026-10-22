pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Desktop mode: tiling (bottom bar), windows (bottom taskbar) or macos (top
// bar + dock). `omadora-mode` owns the mode and writes it to
// ~/.local/state/omadora/mode; this singleton watches that file, so a
// switch from anywhere (CLI, keybind, Quick Settings) applies live.
//
// All bar geometry lives here, so the three modes share one set of numbers.
Singleton {
    id: desktop

    readonly property string cli: Quickshell.env("HOME") + "/.local/bin/omadora-mode"
    readonly property var modes: [
        { name: "tiling", label: "Tiling", icon: "󰕰" },
        { name: "windows", label: "Windows", icon: "󰖲" },
        { name: "macos", label: "macOS", icon: "󰀵" }
    ]

    property string mode: "tiling"

    FileView {
        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omadora/mode"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const m = text().trim();
            desktop.mode = desktop.modes.some(x => x.name === m) ? m : "tiling";
        }
        onLoadFailed: desktop.mode = "tiling"
    }

    function setMode(name) {
        Quickshell.execDetached([cli, "set", name]);
    }

    function nextMode() {
        Quickshell.execDetached([cli, "next"]);
    }

    // ---- Geometry (shared by every bar, dock and popup) ----
    readonly property bool barOnTop: mode === "macos"
    readonly property int barHeight: mode === "windows" ? 44 : (mode === "macos" ? 30 : 34)
    readonly property int pillHeight: 24          // status pills: same in every mode
    readonly property int edgeGap: 10             // popups and dock keep this distance from screen edges and bars

    // App tiles (taskbar, dock, switcher)
    readonly property int taskTile: 40            // windows taskbar button
    readonly property int taskIcon: 24
    readonly property int dockTile: 52            // dock cell
    readonly property int dockIcon: 40
    readonly property int dockPadding: 6
    readonly property int dockHeight: dockTile + dockPadding * 2

    // Space a popup must leave at the bar's edge
    readonly property int popupInset: barHeight + edgeGap
}
