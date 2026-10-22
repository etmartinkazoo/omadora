import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.I3
import Quickshell.Wayland

// Title-bar controls for the focused floating window (Windows and macOS
// modes). sway draws title bars but no buttons, so this lays a transparent
// strip over the focused window's title bar:
//
//   - minimize, maximize/restore and close buttons: on the right in Windows
//     mode, as traffic lights on the left in macOS mode
//   - double-click to maximize or restore
//   - drag to move; drop on a screen edge to snap (left/right half, top to
//     maximize, corners for quarters), with a preview of where it will land
//   - resize from invisible handles just outside the sides and bottom
//
// Only the focused window gets the strip: it sits above all windows, so on a
// window further back it would cover the ones in front.
Scope {
    id: tb

    readonly property bool macStyle: Desktop.mode === "macos"

    Variants {
        model: Quickshell.screens

        Scope {
            id: perScreen

            required property var modelData

            readonly property var win: WindowList.focusedWindow
            readonly property var out: WindowList.outputRects[modelData.name] ?? null
            readonly property bool shown: Desktop.mode !== "tiling" && win !== null && win.floating
                && !win.fullscreen && !win.minimized && win.titleHeight > 0
                && win.output === modelData.name && out !== null

            // Drag state, in layout coordinates
            property bool dragging: false
            property string zone: ""

            // ---- The strip over the title bar ----
            PanelWindow {
                id: strip

                screen: perScreen.modelData
                visible: perScreen.shown
                color: "transparent"
                anchors { top: true; left: true }
                margins {
                    left: perScreen.shown ? perScreen.win.frame.x - perScreen.out.x : 0
                    top: perScreen.shown ? perScreen.win.frame.y - perScreen.out.y : 0
                }
                implicitWidth: perScreen.shown ? perScreen.win.frame.width : 1
                implicitHeight: perScreen.shown ? perScreen.win.titleHeight : 1
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.layer: WlrLayer.Top
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                WlrLayershell.namespace: "omadora-titlebar"

                // Drag to move, double-click to maximize. The strip stays put
                // while dragging (pointer events keep coming while the button
                // is held), and the buttons hide until the window lands.
                MouseArea {
                    id: dragArea
                    anchors.fill: parent

                    property real pressX: 0
                    property real pressY: 0
                    property var startFrame: null
                    property real pendingX: 0
                    property real pendingY: 0

                    function pointer(mouse) {
                        // Pointer in layout coordinates
                        return { x: perScreen.out.x + strip.margins.left + mouse.x, y: perScreen.out.y + strip.margins.top + mouse.y };
                    }

                    function zoneAt(p) {
                        const o = perScreen.out;
                        const edge = 4, corner = 64;
                        const nearTop = p.y - o.y < corner, nearBottom = o.y + o.height - p.y < corner;
                        if (p.x - o.x <= edge) return nearTop ? "tl" : (nearBottom ? "bl" : "left");
                        if (o.x + o.width - p.x <= edge) return nearTop ? "tr" : (nearBottom ? "br" : "right");
                        if (p.y - o.y <= edge) return "max";
                        return "";
                    }

                    onPressed: function(mouse) {
                        const p = pointer(mouse);
                        pressX = p.x;
                        pressY = p.y;
                        startFrame = perScreen.win.frame;
                    }

                    onPositionChanged: function(mouse) {
                        if (!pressed || !startFrame) return;
                        const p = pointer(mouse);
                        const dx = p.x - pressX, dy = p.y - pressY;
                        if (!perScreen.dragging) {
                            if (Math.abs(dx) < 4 && Math.abs(dy) < 4) return;
                            perScreen.dragging = true;
                            // Dragging a snapped window restores its size, under the pointer
                            const id = perScreen.win.id;
                            const restore = WindowList.restoreFrames[id];
                            if (restore) {
                                const ratio = (pressX - startFrame.x) / startFrame.width;
                                startFrame = { x: pressX - restore.width * ratio, y: startFrame.y, width: restore.width, height: restore.height };
                                WindowList.forget(id);
                                WindowList.setFrame(id, startFrame);
                            }
                        }
                        pendingX = startFrame.x + dx;
                        pendingY = Math.max(perScreen.out.y, startFrame.y + dy);
                        perScreen.zone = zoneAt(p);
                        if (!moveTimer.running) moveTimer.start();
                    }

                    onReleased: function(mouse) {
                        moveTimer.stop();
                        if (perScreen.dragging) {
                            const id = perScreen.win.id;
                            if (perScreen.zone !== "") {
                                WindowList.snap(id, perScreen.zone);
                            } else {
                                I3.dispatch(`[con_id=${id}] move absolute position ${Math.round(pendingX)} ${Math.round(pendingY)}`);
                                WindowList.geometryChanged();
                            }
                        }
                        perScreen.dragging = false;
                        perScreen.zone = "";
                        startFrame = null;
                    }

                    onDoubleClicked: WindowList.toggleMaximize(perScreen.win.id)

                    // At most one move per frame
                    Timer {
                        id: moveTimer
                        interval: 16
                        onTriggered: {
                            if (!perScreen.win) return;
                            I3.dispatch(`[con_id=${perScreen.win.id}] move absolute position ${Math.round(dragArea.pendingX)} ${Math.round(dragArea.pendingY)}`);
                        }
                    }
                }

                // ---- Windows style: minimize, maximize, close on the right ----
                Row {
                    visible: !tb.macStyle && !perScreen.dragging
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.borderWidth
                    anchors.top: parent.top
                    anchors.topMargin: Theme.borderWidth
                    // Leave sway's border lines above and below visible
                    height: parent.height - Theme.borderWidth * 2

                    Repeater {
                        model: [
                            { action: "minimize", glyph: "󰖰" },
                            { action: "maximize", glyph: perScreen.win && WindowList.isMaximized(perScreen.win.id) ? "󰖲" : "󰖯" },
                            { action: "close", glyph: "󰖭" }
                        ]
                        delegate: Rectangle {
                            id: winBtn
                            required property var modelData
                            width: 40
                            height: parent.height
                            color: btnMouse.containsMouse ? (modelData.action === "close" ? Theme.red : Theme.bgSelected) : Theme.bgPanel

                            Text {
                                anchors.centerIn: parent
                                text: winBtn.modelData.glyph
                                color: btnMouse.containsMouse && winBtn.modelData.action === "close" ? Theme.bgPanel : Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontNormal
                            }

                            MouseArea {
                                id: btnMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: tb.run(winBtn.modelData.action, perScreen.win)
                            }

                            Tip {
                                target: winBtn
                                below: true
                                hovered: btnMouse.containsMouse
                                text: winBtn.modelData.action === "close" ? "Close (Alt+W)"
                                    : winBtn.modelData.action === "minimize" ? "Minimize"
                                    : (perScreen.win && WindowList.isMaximized(perScreen.win.id) ? "Restore (Alt+M)" : "Maximize (Alt+M)")
                            }
                        }
                    }
                }

                // ---- macOS style: traffic lights on the left ----
                Row {
                    id: lights
                    visible: tb.macStyle && !perScreen.dragging
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.paddingLarge
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.paddingMedium

                    readonly property bool hovered: lightsMouse.containsMouse

                    Repeater {
                        model: [
                            { action: "close", color: Theme.red, glyph: "×" },
                            { action: "minimize", color: Theme.yellow, glyph: "−" },
                            { action: "maximize", color: Theme.green, glyph: "+" }
                        ]
                        delegate: Rectangle {
                            id: light
                            required property var modelData
                            width: 12
                            height: 12
                            radius: 6
                            color: modelData.color

                            Text {
                                anchors.centerIn: parent
                                visible: lights.hovered
                                text: light.modelData.glyph
                                color: Theme.bgPanel
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                font.bold: true
                            }
                        }
                    }
                }

                // One hover area for the traffic lights (macOS shows all glyphs at once)
                MouseArea {
                    id: lightsMouse
                    visible: lights.visible
                    anchors.fill: lights
                    anchors.margins: -4
                    hoverEnabled: true
                    onClicked: function(mouse) {
                        const i = Math.floor((mouse.x - 4 + lights.spacing / 2) / (12 + lights.spacing));
                        const actions = ["close", "minimize", "maximize"];
                        if (i >= 0 && i < 3) tb.run(actions[i], perScreen.win);
                    }
                }
            }

            // ---- Resize handles around the window ----
            Variants {
                model: ["l", "r", "b", "bl", "br"]
                ResizeGrip {
                    required property string modelData
                    edge: modelData
                    screen: perScreen.modelData
                    win: perScreen.shown ? perScreen.win : null
                    out: perScreen.out
                    active: !perScreen.dragging
                }
            }

            // ---- Where a dragged window will snap ----
            PanelWindow {
                screen: perScreen.modelData
                visible: perScreen.dragging && perScreen.zone !== ""
                color: "transparent"
                anchors { top: true; bottom: true; left: true; right: true }
                exclusionMode: ExclusionMode.Ignore
                mask: Region {}
                WlrLayershell.layer: WlrLayer.Top
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                WlrLayershell.namespace: "omadora-snap-preview"

                Rectangle {
                    readonly property var r: perScreen.win && perScreen.zone !== "" ? WindowList.zoneRect(perScreen.win, perScreen.zone) : null
                    visible: r !== null
                    x: r ? r.x - perScreen.out.x + Desktop.edgeGap / 2 : 0
                    y: r ? r.y - perScreen.out.y + Desktop.edgeGap / 2 : 0
                    width: r ? r.width - Desktop.edgeGap : 0
                    height: r ? r.height - Desktop.edgeGap : 0
                    color: Qt.alpha(Theme.accent, 0.18)
                    border.color: Theme.accent
                    border.width: 2
                    radius: Theme.radius

                    Behavior on x { NumberAnimation { duration: 90 } }
                    Behavior on y { NumberAnimation { duration: 90 } }
                    Behavior on width { NumberAnimation { duration: 90 } }
                    Behavior on height { NumberAnimation { duration: 90 } }
                }
            }
        }
    }

    IpcHandler {
        target: "window"
        // Super+Alt+arrows: left / right / up / down
        function snap(direction: string) { WindowList.snapKey(direction); }
        function maximize() { if (WindowList.focusedWindow) WindowList.toggleMaximize(WindowList.focusedWindow.id); }
        // Alt+A / Alt+S: snap to a half (again restores)
        function snapTo(zone: string) {
            const w = WindowList.focusedWindow;
            if (!w) return;
            if (WindowList.snapped[w.id] === zone) WindowList.unsnap(w.id);
            else WindowList.snap(w.id, zone);
        }
        function showDesktop() { WindowList.toggleDesktop(); }
        function hideApp() { WindowList.hideFocusedApp(); }
    }

    function run(action, win) {
        if (!win) return;
        if (action === "close") WindowList.close(win.id);
        else if (action === "minimize") WindowList.minimize(win.id);
        else if (action === "maximize") WindowList.toggleMaximize(win.id);
    }
}
