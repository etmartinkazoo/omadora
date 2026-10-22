import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.I3
import Quickshell.Wayland

// Display settings (Quick Settings → Displays, or Super+Ctrl+D). Drag screens
// to arrange them (they snap edge to edge); pick resolution, scale and
// rotation; Apply asks "Keep these settings?" and reverts after 15 seconds
// unless you confirm, so a bad mode can't strand you on a dark screen.
// Keeping saves the layout as the profile for this set of screens: plugging
// them in again restores it (omadora-displays restore, run on hotplug).
Scope {
    id: disp

    readonly property bool active: ShellState.activePopup === "displays"
    readonly property string cli: Quickshell.env("HOME") + "/.local/bin/omadora-displays"

    property var outputs: []        // as listed by sway
    property var draft: []          // edited copy
    property var before: []         // what to revert to
    property string selected: ""
    property int countdown: 0
    property bool identifying: false

    readonly property var sel: draft.find(o => o.name === selected) ?? null
    readonly property bool dirty: JSON.stringify(strip(draft)) !== JSON.stringify(strip(outputs))

    function strip(list) {
        return list.map(o => ({ name: o.name, enabled: o.enabled, mode: o.mode, scale: o.scale, transform: o.transform, x: o.x, y: o.y }));
    }

    function load() {
        if (!listProc.running) listProc.running = true;
    }

    function edit(name, change) {
        draft = draft.map(o => o.name === name ? Object.assign({}, o, change) : o);
        if ("mode" in change || "scale" in change || "transform" in change || "enabled" in change) draft = arrange(draft, name);
    }

    // Logical size: what the screen occupies in the layout
    function logical(o) {
        const m = o.modes.find(x => x.mode === o.mode) ?? { width: o.width, height: o.height };
        const rotated = o.transform === "90" || o.transform === "270" || o.transform === "flipped-90" || o.transform === "flipped-270";
        const w = Math.round((rotated ? m.height : m.width) / o.scale);
        const h = Math.round((rotated ? m.width : m.height) / o.scale);
        return { width: w, height: h };
    }

    // Move `moved` flush against its nearest neighbour, then shift everything
    // so the layout starts at 0,0.
    function arrange(list, moved) {
        const on = list.filter(o => o.enabled);
        const m = on.find(o => o.name === moved);
        if (m && on.length > 1) {
            const ms = logical(m);
            let best = null;
            for (const o of on) {
                if (o.name === moved) continue;
                const os = logical(o);
                const options = [
                    { x: o.x - ms.width, y: m.y },          // left of it
                    { x: o.x + os.width, y: m.y },          // right of it
                    { x: m.x, y: o.y - ms.height },         // above it
                    { x: m.x, y: o.y + os.height }          // below it
                ];
                for (const p of options) {
                    // Keep it overlapping along the other axis; align edges when close
                    if (p.x === o.x - ms.width || p.x === o.x + os.width) {
                        p.y = Math.max(o.y - ms.height + 50, Math.min(o.y + os.height - 50, p.y));
                        if (Math.abs(p.y - o.y) < 80) p.y = o.y;
                    } else {
                        p.x = Math.max(o.x - ms.width + 50, Math.min(o.x + os.width - 50, p.x));
                        if (Math.abs(p.x - o.x) < 80) p.x = o.x;
                    }
                    const d = Math.hypot(p.x - m.x, p.y - m.y);
                    if (!best || d < best.d) best = { x: Math.round(p.x), y: Math.round(p.y), d: d };
                }
            }
            if (best) list = list.map(o => o.name === moved ? Object.assign({}, o, { x: best.x, y: best.y }) : o);
        }
        const xs = list.filter(o => o.enabled).map(o => o.x), ys = list.filter(o => o.enabled).map(o => o.y);
        const dx = xs.length ? Math.min(...xs) : 0, dy = ys.length ? Math.min(...ys) : 0;
        return list.map(o => Object.assign({}, o, { x: o.x - dx, y: o.y - dy }));
    }

    function apply() {
        if (!dirty || draft.every(o => !o.enabled)) return;
        before = strip(outputs);
        run(strip(draft));
        countdown = 15;
        revertTimer.restart();
    }

    function keep() {
        revertTimer.stop();
        countdown = 0;
        Quickshell.execDetached([cli, "save"]);
    }

    function revert() {
        revertTimer.stop();
        countdown = 0;
        run(before);
    }

    function run(entries) {
        applyProc.command = [cli, "apply", JSON.stringify(entries)];
        applyProc.running = true;
    }

    Process {
        id: listProc
        command: [disp.cli, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const list = JSON.parse(text);
                    disp.outputs = list;
                    if (disp.countdown === 0) disp.draft = list;
                    if (!list.some(o => o.name === disp.selected)) disp.selected = (list.find(o => o.focused) ?? list[0] ?? { name: "" }).name;
                } catch (e) {
                    console.warn("displays: bad list", e);
                }
            }
        }
    }

    Process {
        id: applyProc
        onExited: disp.load()
    }

    Timer {
        id: revertTimer
        interval: 1000
        repeat: true
        onTriggered: {
            disp.countdown--;
            if (disp.countdown <= 0) disp.revert();
        }
    }

    // Hotplug: bring back the layout saved for the screens now connected
    Timer {
        id: restoreSoon
        interval: 1500
        onTriggered: {
            Quickshell.execDetached([disp.cli, "restore"]);
            disp.load();
        }
    }

    I3IpcListener {
        subscriptions: ["output"]
        onIpcEvent: if (disp.countdown === 0) restoreSoon.restart()
    }

    Component.onCompleted: restoreSoon.restart()
    onActiveChanged: if (active) load()

    IpcHandler {
        target: "displays"
        function open() { ShellState.openPopup("displays"); }
        function hide() { ShellState.closePopup("displays"); }
        function toggle() { ShellState.togglePopup("displays"); }
    }

    // ---- Identify: each screen's name, big, on that screen ----
    Timer {
        id: identifyTimer
        interval: 2500
        onTriggered: disp.identifying = false
    }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: idWin
            required property var modelData
            screen: modelData
            visible: disp.identifying
            color: "transparent"
            anchors { top: true; left: true }
            margins { top: 48; left: 48 }
            implicitWidth: idBox.width
            implicitHeight: idBox.height
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            Rectangle {
                id: idBox
                width: idText.implicitWidth + 48
                height: idText.implicitHeight + 24
                color: Theme.bgPanel
                border.color: Theme.accent
                border.width: 2
                radius: Theme.radius
                Text {
                    id: idText
                    anchors.centerIn: parent
                    text: idWin.modelData.name
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: 40
                    font.bold: true
                }
            }
        }
    }

    ShellPopup {
        name: "displays"
        centered: true
        panelWidth: 720

        Column {
            width: parent.width
            spacing: Theme.spacingLarge
            focus: true

            Keys.onReturnPressed: disp.countdown > 0 ? disp.keep() : disp.apply()
            Keys.onEnterPressed: disp.countdown > 0 ? disp.keep() : disp.apply()
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_I) {
                    disp.identifying = true;
                    identifyTimer.restart();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape && disp.countdown > 0) {
                    disp.revert();
                    event.accepted = true;
                }
            }

            RowLayout {
                width: parent.width
                height: Theme.headerHeight
                PanelTitle { text: "DISPLAYS"; Layout.fillWidth: true }
                SmallButton {
                    text: "IDENTIFY [I]"
                    onClicked: {
                        disp.identifying = true;
                        identifyTimer.restart();
                    }
                }
            }

            // ---- Arrangement ----
            Rectangle {
                id: canvas
                width: parent.width
                height: 200
                color: Theme.bgItem
                radius: Theme.radius
                clip: true

                readonly property var boxes: disp.draft.filter(o => o.enabled).map(o => Object.assign({ name: o.name }, disp.logical(o), { x: o.x, y: o.y }))
                readonly property real minX: boxes.length ? Math.min(...boxes.map(b => b.x)) : 0
                readonly property real minY: boxes.length ? Math.min(...boxes.map(b => b.y)) : 0
                readonly property real spanW: boxes.length ? Math.max(...boxes.map(b => b.x + b.width)) - minX : 1
                readonly property real spanH: boxes.length ? Math.max(...boxes.map(b => b.y + b.height)) - minY : 1
                readonly property real k: Math.min((width - 80) / spanW, (height - 60) / spanH)
                readonly property real ox: (width - spanW * k) / 2
                readonly property real oy: (height - spanH * k) / 2

                Repeater {
                    model: canvas.boxes
                    delegate: Rectangle {
                        id: box
                        required property var modelData
                        readonly property bool isSel: modelData.name === disp.selected
                        // Dragging moves the box directly; dropping updates the
                        // model, which recreates the boxes in their new places.
                        x: canvas.ox + (modelData.x - canvas.minX) * canvas.k
                        y: canvas.oy + (modelData.y - canvas.minY) * canvas.k
                        width: modelData.width * canvas.k
                        height: modelData.height * canvas.k
                        color: isSel ? Theme.bgSelected : Theme.bgPanel
                        border.color: Theme.accent
                        border.width: isSel ? 2 : 0
                        radius: Theme.radius

                        Column {
                            anchors.centerIn: parent
                            spacing: 2
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: box.modelData.name
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontNormal
                                font.bold: true
                            }
                            Caption {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: box.modelData.width + "×" + box.modelData.height
                            }
                        }

                        MouseArea {
                            id: dragArea
                            anchors.fill: parent
                            drag.target: box
                            cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            onPressed: disp.selected = box.modelData.name
                            onReleased: {
                                const homeX = canvas.ox + (box.modelData.x - canvas.minX) * canvas.k;
                                const homeY = canvas.oy + (box.modelData.y - canvas.minY) * canvas.k;
                                if (Math.abs(box.x - homeX) < 2 && Math.abs(box.y - homeY) < 2) return;   // a click
                                const nx = Math.round((box.x - canvas.ox) / canvas.k + canvas.minX);
                                const ny = Math.round((box.y - canvas.oy) / canvas.k + canvas.minY);
                                disp.draft = disp.draft.map(o => o.name === box.modelData.name ? Object.assign({}, o, { x: nx, y: ny }) : o);
                                disp.draft = disp.arrange(disp.draft, box.modelData.name);
                            }
                        }
                    }
                }

                Caption {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottomMargin: Theme.paddingSmall
                    text: disp.draft.length > 1 ? "drag to arrange • click to select" : "one screen connected"
                }
            }

            // ---- Selected screen ----
            Column {
                width: parent.width
                spacing: Theme.spacingMedium
                visible: disp.sel !== null

                // Tabs for each screen (including ones that are off)
                Row {
                    spacing: Theme.paddingSmall
                    Repeater {
                        model: disp.draft
                        delegate: SmallButton {
                            required property var modelData
                            text: modelData.name + (modelData.enabled ? "" : " (off)")
                            highlighted: modelData.name === disp.selected
                            onClicked: disp.selected = modelData.name
                        }
                    }
                }

                RowLayout {
                    width: parent.width
                    Caption { text: disp.sel ? disp.sel.description : ""; Layout.fillWidth: true }
                    SmallButton {
                        text: disp.sel && disp.sel.enabled ? "ON" : "OFF"
                        highlighted: disp.sel !== null && disp.sel.enabled
                        onClicked: if (disp.sel) disp.edit(disp.selected, { enabled: !disp.sel.enabled })
                    }
                }

                GridLayout {
                    width: parent.width
                    columns: 2
                    columnSpacing: Theme.spacingLarge
                    rowSpacing: Theme.spacingMedium
                    enabled: disp.sel !== null && disp.sel.enabled
                    opacity: enabled ? 1 : 0.45

                    Caption { text: "RESOLUTION" }
                    Flow {
                        Layout.fillWidth: true
                        spacing: Theme.paddingSmall
                        Repeater {
                            model: disp.sel ? disp.sel.modes.slice(0, 12) : []
                            delegate: SmallButton {
                                required property var modelData
                                text: modelData.width + "×" + modelData.height + " " + Math.round(modelData.refresh) + "Hz"
                                highlighted: disp.sel && disp.sel.mode === modelData.mode
                                onClicked: disp.edit(disp.selected, { mode: modelData.mode })
                            }
                        }
                    }

                    Caption { text: "SCALE" }
                    Row {
                        spacing: Theme.paddingSmall
                        Repeater {
                            model: [1, 1.25, 1.5, 1.75, 2, 2.5, 3]
                            delegate: SmallButton {
                                required property real modelData
                                text: Math.round(modelData * 100) + "%"
                                highlighted: disp.sel && Math.abs(disp.sel.scale - modelData) < 0.01
                                onClicked: disp.edit(disp.selected, { scale: modelData })
                            }
                        }
                    }

                    Caption { text: "ROTATION" }
                    Row {
                        spacing: Theme.paddingSmall
                        Repeater {
                            model: [{ t: "normal", l: "0°" }, { t: "90", l: "90°" }, { t: "180", l: "180°" }, { t: "270", l: "270°" }]
                            delegate: SmallButton {
                                required property var modelData
                                text: modelData.l
                                highlighted: disp.sel && disp.sel.transform === modelData.t
                                onClicked: disp.edit(disp.selected, { transform: modelData.t })
                            }
                        }
                    }
                }
            }

            // ---- Apply / keep ----
            Rectangle {
                width: parent.width
                height: Theme.rowHeight + Theme.paddingMedium
                color: disp.countdown > 0 ? Theme.bgSelected : "transparent"
                radius: Theme.radius

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: disp.countdown > 0 ? Theme.paddingLarge : 0
                    anchors.rightMargin: disp.countdown > 0 ? Theme.paddingSmall : 0
                    spacing: Theme.paddingSmall

                    Text {
                        Layout.fillWidth: true
                        text: disp.countdown > 0 ? "Keep these settings? Reverting in " + disp.countdown + " s"
                            : disp.dirty ? "Not applied yet" : "Current settings"
                        color: disp.countdown > 0 ? Theme.textPrimary : Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontCaption
                        font.bold: disp.countdown > 0
                    }
                    SmallButton {
                        visible: disp.countdown > 0
                        text: "REVERT [Esc]"
                        onClicked: disp.revert()
                    }
                    SmallButton {
                        visible: disp.countdown > 0
                        text: "KEEP [Enter]"
                        highlighted: true
                        onClicked: disp.keep()
                    }
                    SmallButton {
                        visible: disp.countdown === 0 && disp.dirty
                        text: "UNDO"
                        onClicked: disp.draft = disp.outputs
                    }
                    SmallButton {
                        visible: disp.countdown === 0
                        text: "APPLY [Enter]"
                        highlighted: disp.dirty
                        onClicked: disp.apply()
                    }
                }
            }
        }
    }
}
