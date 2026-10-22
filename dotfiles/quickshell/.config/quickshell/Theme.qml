pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Colors come from the active omadora theme: `omadora-theme` renders
// templates/quickshell.json.tpl into ~/.local/state/omadora/theme/quickshell.json
// and this singleton watches that file, so theme switches apply live.
Singleton {
    id: theme

    readonly property string cli: Quickshell.env("HOME") + "/.local/bin/omadora-theme"
    readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
        + "/omadora/theme/quickshell.json"

    property var palette: ({})

    FileView {
        path: theme.statePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                theme.palette = JSON.parse(text());
            } catch (e) {
                // Mid-write or malformed: keep the previous palette.
            }
        }
        // First run: nothing rendered yet.
        onLoadFailed: Quickshell.execDetached([theme.cli, "refresh"])
    }

    function pick(key, fallback) {
        const v = palette[key];
        return v !== undefined && v !== "" ? v : fallback;
    }

    readonly property string currentTheme: pick("name", "candor")
    readonly property bool isLight: palette.mode === "light"
    readonly property string wallpaper: pick("wallpaper", "")

    // Colors - Surfaces
    readonly property color bgOverlay: pick("bgOverlay", "#b3090e17")
    readonly property color bgPanel: pick("bgPanel", "#141d2b")
    readonly property color bgItem: pick("bgItem", "#0d1420")
    readonly property color bgSelected: pick("bgSelected", "#1f3d6e")
    readonly property color bgCritical: pick("bgCritical", "#3a141c")

    // Colors - Borders
    readonly property color border: pick("border", "#385a94")
    readonly property color borderSubtle: pick("borderSubtle", "#1f2e47")
    readonly property color borderCritical: pick("borderCritical", "#ff7b72")

    // Colors - Text
    readonly property color textPrimary: pick("textPrimary", "#f0f5ff")
    readonly property color textSecondary: pick("textSecondary", "#8fa8cc")
    readonly property color textMuted: pick("textMuted", "#6b82a6")
    readonly property color textPlaceholder: pick("textPlaceholder", "#566b8c")

    // Colors - Palette (wallpaper, accents)
    readonly property color accent: pick("accent", "#6f9cf2")
    readonly property color background: pick("background", "#141d2b")
    readonly property color darkerBackground: pick("darkerBackground", "#090e17")
    readonly property color red: pick("red", "#ff7b72")
    readonly property color green: pick("green", "#5fd08a")
    readonly property color yellow: pick("yellow", "#e3b341")
    readonly property color blue: pick("blue", "#6f9cf2")
    readonly property color magenta: pick("magenta", "#b392f0")
    readonly property color cyan: pick("cyan", "#39c5cf")

    // Typography
    readonly property string fontFamily: "0xProto Nerd Font"
    readonly property int fontSmall: 10
    readonly property int fontCaption: 11
    readonly property int fontNormal: 12
    readonly property int fontMedium: 13
    readonly property int fontLarge: 14
    readonly property int fontIcon: 15

    // Geometry & Spacing
    readonly property int radius: 0
    // Depth: soft shadows under floating surfaces (Shadow.qml).
    readonly property color shadowColor: isLight ? Qt.rgba(0, 0, 0, 0.18) : Qt.rgba(0, 0, 0, 0.45)
    readonly property int shadowBlur: 22
    readonly property int shadowOffset: 4
    readonly property int shadowMargin: shadowBlur + shadowOffset   // room a window leaves for the shadow
    readonly property int borderWidth: 1
    // An open panel is the active surface: it wears the accent border the
    // focused window gives up while it's open (PanelFocus.qml), at the same 2px
    readonly property int panelBorderWidth: 2
    readonly property int paddingSmall: 6
    readonly property int paddingMedium: 8
    readonly property int paddingLarge: 12
    readonly property int inputPadding: 14
    readonly property int spacingSmall: 2
    readonly property int spacingCompact: 4

    // Row heights, shared by every panel
    readonly property int headerHeight: 28       // a panel's title row with its buttons
    readonly property int rowHeightCompact: 32   // dense lists (audio devices, DNS presets)
    readonly property int rowHeight: 38          // lists (networks, Bluetooth devices)
    readonly property int spacingMedium: 8
    readonly property int spacingLarge: 12

    function setTheme(name) {
        Quickshell.execDetached([cli, "set", name]);
    }

    function nextTheme() {
        Quickshell.execDetached([cli, "next"]);
    }

    function nextBackground() {
        Quickshell.execDetached([cli, "bg-next"]);
    }

    function previousBackground() {
        Quickshell.execDetached([cli, "bg-prev"]);
    }

    function setBackground(index) {
        Quickshell.execDetached([cli, "bg-set", String(index)]);
    }
}
