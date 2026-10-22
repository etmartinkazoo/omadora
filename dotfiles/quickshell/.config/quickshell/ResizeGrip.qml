import QtQuick
import Quickshell
import Quickshell.I3
import Quickshell.Wayland

// An invisible handle just outside one edge or corner of the focused floating
// window, so resizing doesn't need a 1px border. Part of TitleButtons.qml.
// The handle stays put while dragging (pointer events keep coming while the
// button is held) and moves to the new edge once the window settles.
PanelWindow {
    id: grip

    required property var win          // WindowList window, or null
    required property var out          // its output's rect
    required property string edge      // "l", "r", "b", "bl", "br"
    property bool active: true

    readonly property int t: 6         // thickness
    readonly property var f: win ? win.frame : null
    readonly property var r: {
        if (!f) return { x: 0, y: 0, width: 1, height: 1 };
        switch (edge) {
        case "l": return { x: f.x - t, y: f.y, width: t, height: f.height };
        case "r": return { x: f.x + f.width, y: f.y, width: t, height: f.height };
        case "b": return { x: f.x, y: f.y + f.height, width: f.width, height: t };
        case "bl": return { x: f.x - t, y: f.y + f.height - t, width: t * 2, height: t * 2 };
        case "br": return { x: f.x + f.width - t, y: f.y + f.height - t, width: t * 2, height: t * 2 };
        }
        return { x: 0, y: 0, width: 1, height: 1 };
    }

    visible: active && f !== null && out !== null
    color: "transparent"
    anchors { top: true; left: true }
    margins {
        left: out ? r.x - out.x : 0
        top: out ? r.y - out.y : 0
    }
    implicitWidth: Math.max(1, r.width)
    implicitHeight: Math.max(1, r.height)
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "omadora-resize"

    MouseArea {
        id: area
        anchors.fill: parent
        cursorShape: grip.edge === "l" || grip.edge === "r" ? Qt.SizeHorCursor
            : grip.edge === "b" ? Qt.SizeVerCursor
            : grip.edge === "bl" ? Qt.SizeBDiagCursor : Qt.SizeFDiagCursor

        property real px: 0
        property real py: 0
        property var start: null
        property var pending: null

        function pointer(mouse) {
            return { x: grip.out.x + grip.margins.left + mouse.x, y: grip.out.y + grip.margins.top + mouse.y };
        }

        onPressed: function(mouse) {
            const p = pointer(mouse);
            px = p.x;
            py = p.y;
            start = grip.win.frame;
        }

        onPositionChanged: function(mouse) {
            if (!pressed || !start) return;
            const p = pointer(mouse);
            const dx = p.x - px, dy = p.y - py;
            const minW = 200, minH = 120;
            let x = start.x, w = start.width, h = start.height;
            if (grip.edge === "l" || grip.edge === "bl") {
                w = Math.max(minW, start.width - dx);
                x = start.x + start.width - w;
            }
            if (grip.edge === "r" || grip.edge === "br") w = Math.max(minW, start.width + dx);
            if (grip.edge === "b" || grip.edge === "bl" || grip.edge === "br") h = Math.max(minH, start.height + dy);
            pending = { x: x, y: start.y, width: w, height: h };
            if (!resizeTimer.running) resizeTimer.start();
        }

        onReleased: {
            resizeTimer.stop();
            if (pending && grip.win) {
                WindowList.forget(grip.win.id);   // no longer snapped or maximized
                WindowList.setFrame(grip.win.id, pending);
            }
            start = null;
            pending = null;
        }

        // At most one resize per frame
        Timer {
            id: resizeTimer
            interval: 16
            onTriggered: {
                if (!area.pending || !grip.win) return;
                const f = area.pending;
                I3.dispatch(`[con_id=${grip.win.id}] resize set ${Math.round(f.width)} ${Math.round(f.height)}, move absolute position ${Math.round(f.x)} ${Math.round(f.y)}`);
            }
        }
    }
}
