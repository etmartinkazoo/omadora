import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Visual theme picker. Each card previews the theme's wallpaper (or a mini
// mock-up from its palette) and color swatches. Enter applies live and keeps
// the picker open, so you can compare themes. The grid scrolls; below it, a
// strip of the current theme's wallpapers lets you pick one.
Scope {
    id: picker

    readonly property bool active: ShellState.activePopup === "themes"
    readonly property int columns: 3
    property var themes: []
    property int selectedIndex: 0

    readonly property var currentEntry: themes.find(t => t.name === Theme.currentTheme) ?? null
    readonly property var currentBackgrounds: currentEntry ? (currentEntry.backgrounds ?? []) : []
    readonly property int currentBackgroundIndex: currentBackgrounds.indexOf(Theme.wallpaper)

    onActiveChanged: if (active) lister.running = true
    onCurrentBackgroundIndexChanged: if (currentBackgroundIndex >= 0) wallList.positionViewAtIndex(currentBackgroundIndex, ListView.Contain)

    function move(delta) {
        if (themes.length === 0) return;
        selectedIndex = Math.max(0, Math.min(themes.length - 1, selectedIndex + delta));
        ensureVisible();
    }

    // Scroll the grid so the selected card is fully in view (keyboard only:
    // hover also selects, and following it would fight the mouse wheel).
    function ensureVisible() {
        if (themes.length === 0) return;
        const rows = Math.ceil(themes.length / columns);
        const rowHeight = (grid.height + grid.spacing) / rows;
        const top = Math.floor(selectedIndex / columns) * rowHeight;
        const bottom = top + rowHeight - grid.spacing;
        if (top < flick.contentY) flick.contentY = top;
        else if (bottom > flick.contentY + flick.height) flick.contentY = bottom - flick.height;
    }

    function applySelected() {
        if (selectedIndex >= 0 && selectedIndex < themes.length) Theme.setTheme(themes[selectedIndex].name);
    }

    Process {
        id: lister
        command: [Theme.cli, "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const list = JSON.parse(text);
                    picker.themes = list;
                    const cur = list.findIndex(t => t.current);
                    picker.selectedIndex = cur >= 0 ? cur : 0;
                    Qt.callLater(picker.ensureVisible);
                } catch (e) {
                    console.warn("theme picker: bad list output", e);
                }
            }
        }
    }

    IpcHandler {
        target: "theme"
        function picker() { ShellState.togglePopup("themes"); }
        function next() { Theme.nextTheme(); }
        function set(name: string) { Theme.setTheme(name); }
        function bgNext() { Theme.nextBackground(); }
    }

    ShellPopup {
        id: popupWin
        name: "themes"
        centered: true
        panelWidth: 760

        Column {
            id: col
            width: parent.width
            spacing: Theme.spacingLarge
            focus: true

            Keys.onLeftPressed: picker.move(-1)
            Keys.onRightPressed: picker.move(1)
            Keys.onUpPressed: picker.move(-picker.columns)
            Keys.onDownPressed: picker.move(picker.columns)
            Keys.onReturnPressed: picker.applySelected()
            Keys.onEnterPressed: picker.applySelected()
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_B) {
                    if (event.modifiers & Qt.ShiftModifier) Theme.previousBackground();
                    else Theme.nextBackground();
                    event.accepted = true;
                }
            }

            RowLayout {
                width: parent.width
                PanelTitle {
                    text: "THEMES"
                    Layout.fillWidth: true
                }
                Caption { text: "current: " + Theme.currentTheme }
            }

            Item {
                id: viewport
                width: parent.width
                height: Math.min(grid.height, Math.max(240, (popupWin.screen ? popupWin.screen.height : 1080) * 0.55))
                clip: true

                Flickable {
                    id: flick
                    anchors.fill: parent
                    contentWidth: width
                    contentHeight: grid.height
                    boundsBehavior: Flickable.StopAtBounds

                    Grid {
                        id: grid
                        width: parent.width - 10   // gutter for the scroll indicator
                        columns: picker.columns
                        spacing: Theme.spacingMedium

                        Repeater {
                            model: picker.themes
                            delegate: Rectangle {
                                id: card
                                required property var modelData
                                required property int index
                                readonly property var c: modelData.colors
                                readonly property bool isCurrent: modelData.name === Theme.currentTheme
                                readonly property bool isSelected: index === picker.selectedIndex
                                width: (grid.width - grid.spacing * (picker.columns - 1)) / picker.columns
                                height: preview.height + info.implicitHeight + 16
                                color: Theme.bgItem
                                border.color: Theme.accent
                                border.width: isSelected ? 2 : 0
                                radius: Theme.radius

                                // Preview: wallpaper, or a mini desktop drawn from the palette
                                Rectangle {
                                    id: preview
                                    x: 6
                                    y: 6
                                    width: parent.width - 12
                                    height: width * 9 / 16
                                    color: card.c.background
                                    clip: true

                                    Image {
                                        anchors.fill: parent
                                        visible: card.modelData.preview !== ""
                                        source: card.modelData.preview !== "" ? "file://" + card.modelData.preview : ""
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        sourceSize.width: 480
                                        sourceSize.height: 270
                                    }

                                    // Two tiled "windows"
                                    Row {
                                        visible: card.modelData.preview === ""
                                        x: parent.width * 0.06
                                        y: parent.height * 0.1
                                        spacing: parent.width * 0.03
                                        Rectangle {
                                            width: preview.width * 0.5; height: preview.height * 0.62
                                            color: card.c.dark_background; border.color: card.c.accent; border.width: 1
                                        }
                                        Rectangle {
                                            width: preview.width * 0.35; height: preview.height * 0.62
                                            color: card.c.dark_background; border.color: Qt.alpha(card.c.foreground, 0.2); border.width: 1
                                        }
                                    }

                                    // Bar with an accent pill
                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        height: parent.height * 0.13
                                        color: Qt.alpha(card.c.background, 0.92)
                                        Row {
                                            anchors.verticalCenter: parent.verticalCenter
                                            x: 6
                                            spacing: 3
                                            Repeater {
                                                model: 3
                                                delegate: Rectangle {
                                                    required property int index
                                                    width: index === 0 ? 18 : 8; height: 7
                                                    color: index === 0 ? card.c.accent : card.c.dark_background
                                                    border.color: Qt.alpha(card.c.foreground, 0.25); border.width: 1
                                                }
                                            }
                                        }
                                    }
                                }

                                Column {
                                    id: info
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: preview.bottom
                                    anchors.margins: 8
                                    anchors.topMargin: 6
                                    spacing: 5

                                    RowLayout {
                                        width: parent.width
                                        Text {
                                            text: card.modelData.name
                                            color: Theme.textPrimary
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontNormal
                                            font.bold: true
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                        Text {
                                            text: card.isCurrent ? "● current" : (card.modelData.mode === "light" ? "light" : "")
                                            color: card.isCurrent ? Theme.accent : Theme.textMuted
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSmall
                                        }
                                    }

                                    Row {
                                        spacing: 3
                                        Repeater {
                                            model: ["accent", "red", "yellow", "green", "cyan", "blue", "magenta", "foreground"]
                                            delegate: Rectangle {
                                                required property string modelData
                                                width: 14; height: 10
                                                color: card.c[modelData]
                                                border.color: Qt.alpha(Theme.textPrimary, 0.15); border.width: 1
                                            }
                                        }
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onEntered: picker.selectedIndex = card.index
                                    onClicked: {
                                        picker.selectedIndex = card.index;
                                        picker.applySelected();
                                    }
                                }
                            }
                        }
                    }
                }

                // Scroll indicator
                Rectangle {
                    visible: flick.contentHeight > flick.height
                    anchors.right: parent.right
                    width: 4
                    radius: 2
                    y: flick.visibleArea.yPosition * viewport.height
                    height: flick.visibleArea.heightRatio * viewport.height
                    color: Theme.border
                }
            }

            RowLayout {
                width: parent.width
                PanelTitle {
                    text: "WALLPAPERS"
                    Layout.fillWidth: true
                }
                Caption {
                    visible: picker.currentBackgrounds.length > 0
                    text: (picker.currentBackgroundIndex >= 0 ? (picker.currentBackgroundIndex + 1) + " / " : "")
                        + picker.currentBackgrounds.length
                }
            }

            Caption {
                visible: picker.currentBackgrounds.length === 0
                text: Theme.currentTheme + " has no wallpaper images; its wallpaper is drawn from the palette."
            }

            ListView {
                id: wallList
                visible: picker.currentBackgrounds.length > 0
                width: parent.width
                height: 72
                orientation: ListView.Horizontal
                spacing: Theme.spacingMedium
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: picker.currentBackgrounds

                // Vertical wheel scrolls the strip sideways
                WheelHandler {
                    orientation: Qt.Vertical
                    target: null
                    onWheel: function(event) {
                        const max = Math.max(0, wallList.contentWidth - wallList.width);
                        wallList.contentX = Math.max(0, Math.min(max, wallList.contentX - event.angleDelta.y));
                    }
                }

                delegate: Rectangle {
                    id: thumb
                    required property string modelData
                    required property int index
                    readonly property bool isCurrent: index === picker.currentBackgroundIndex
                    width: 128
                    height: 72
                    color: Theme.bgItem
                    radius: Theme.radius
                    border.color: Theme.accent
                    border.width: isCurrent ? 2 : 0

                    Image {
                        anchors.fill: parent
                        anchors.margins: 3
                        source: "file://" + thumb.modelData
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: 256
                        sourceSize.height: 144
                    }

                    MouseArea {
                        id: thumbMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: Theme.setBackground(thumb.index)
                    }
                }
            }

            Hint {
                text: "←→↑↓ select • Enter apply • B / Shift+B wallpaper • more: omadora-theme install omarchy:<name>"
            }
        }
    }
}
