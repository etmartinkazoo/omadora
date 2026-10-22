import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Updates panel (Quick Settings → Updates, or U there). Reads
// `omadora-update status`: how many updates dnf has. Update and Undo open a
// terminal running dnf, so you see and confirm the changes; security updates
// install on their own (dnf5-automatic).
// Checks every 6 hours and notifies once when updates show up.
Scope {
    id: upd

    readonly property bool active: ShellState.activePopup === "updates"
    readonly property string cli: Quickshell.env("HOME") + "/.local/bin/omadora-update"

    property var status: ({})
    property bool checking: false
    property bool armedRollback: false

    readonly property int updates: status.updates ?? -1
    // Something to act on: shown on the Quick Settings pill
    readonly property bool attention: updates > 0

    function refresh(check) {
        if (statusProc.running) return;
        if (check) checking = true;
        statusProc.command = check ? [cli, "status", "--check"] : [cli, "status"];
        statusProc.running = true;
    }

    function update() {
        ShellState.closePopup("updates");
        ShellState.launchInTerminal(["sh", "-c", "sudo dnf upgrade; echo; read -p 'Done. Press Enter to close.' _"]);
    }

    function rollback() {
        if (!armedRollback) {
            armedRollback = true;
            disarm.restart();
            return;
        }
        armedRollback = false;
        ShellState.closePopup("updates");
        ShellState.launchInTerminal(["sh", "-c", "sudo dnf history undo last; echo; read -p 'Done. Press Enter to close.' _"]);
    }

    function ago(epoch) {
        if (!epoch) return "never";
        const s = Math.max(0, Date.now() / 1000 - epoch);
        if (s < 90) return "just now";
        if (s < 5400) return Math.round(s / 60) + " min ago";
        if (s < 129600) return Math.round(s / 3600) + " h ago";
        return Math.round(s / 86400) + " days ago";
    }

    function date(epoch) {
        return epoch ? Qt.formatDate(new Date(epoch * 1000), "MMM d, yyyy") : "";
    }

    Process {
        id: statusProc
        stdout: StdioCollector {
            onStreamFinished: {
                upd.checking = false;
                try {
                    const prev = upd.status;
                    const next = JSON.parse(text);
                    upd.status = next;
                    // Tell once, when updates show up
                    if (prev.current !== undefined && (next.updates ?? 0) > 0 && (prev.updates ?? 0) === 0) {
                        Quickshell.execDetached(["notify-send", "-a", "Updates", "-i", "system-software-update",
                            "Updates available", "Open Quick Settings → Updates."]);
                    }
                } catch (e) {
                    console.warn("updates: bad status", e);
                }
            }
        }
    }

    Timer {
        id: disarm
        interval: 4000
        onTriggered: upd.armedRollback = false
    }

    // Check every 6 hours; on start, check if the last one is older than that
    Timer {
        interval: 6 * 3600 * 1000
        running: true
        repeat: true
        onTriggered: upd.refresh(true)
    }

    Component.onCompleted: refresh(false)
    onStatusChanged: {
        if (status.current !== undefined && !checking && (!status.checked || Date.now() / 1000 - status.checked > 6 * 3600)) refresh(true);
    }
    onActiveChanged: {
        armedRollback = false;
        if (active) refresh(false);
    }

    IpcHandler {
        target: "updates"
        function open() { ShellState.openPopup("updates"); }
        function hide() { ShellState.closePopup("updates"); }
        function toggle() { ShellState.togglePopup("updates"); }
        function check() { upd.refresh(true); }
    }

    ShellPopup {
        name: "updates"
        panelWidth: 440
        defaultRightOffset: 260

        Column {
            width: parent.width
            spacing: Theme.spacingLarge
            focus: true

            Keys.onPressed: function(event) {
                switch (event.key) {
                case Qt.Key_C: upd.refresh(true); break;
                case Qt.Key_U: upd.update(); break;
                case Qt.Key_R: upd.rollback(); break;
                default: return;
                }
                event.accepted = true;
            }

            RowLayout {
                width: parent.width
                height: Theme.headerHeight
                PanelTitle { text: "UPDATES"; Layout.fillWidth: true }
                Caption { text: upd.checking ? "checking…" : "checked " + upd.ago(upd.status.checked) }
                SmallButton {
                    text: "CHECK [C]"
                    onClicked: upd.refresh(true)
                }
            }

            // Status
            Rectangle {
                width: parent.width
                height: statusCol.implicitHeight + Theme.paddingLarge * 2
                color: upd.attention ? Theme.bgSelected : Theme.bgItem
                radius: Theme.radius

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.paddingLarge
                    spacing: Theme.paddingLarge

                    Text {
                        text: (upd.updates > 0 ? "󰏔" : (upd.updates === 0 ? "󰄬" : "󰔟"))
                        color: upd.attention ? Theme.accent : Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: 24
                    }

                    Column {
                        id: statusCol
                        Layout.fillWidth: true
                        spacing: Theme.spacingCompact

                        Text {
                            width: parent.width
                            text: upd.updates > 0 ? upd.updates + " updates available"
                                : upd.updates === 0 ? "Up to date"
                                : "Not checked yet"
                            color: Theme.textPrimary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontMedium
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        Caption {
                            width: parent.width
                            text: upd.status.current ? "Running " + upd.status.current.version
                                    + (upd.status.current.time ? " · updated " + upd.date(upd.status.current.time) : "")
                                : ""
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                        Caption {
                            visible: (upd.status.error ?? "") !== ""
                            width: parent.width
                            text: upd.status.error ?? ""
                            color: Theme.borderCritical
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                    }
                }
            }

            // Actions
            Row {
                width: parent.width
                spacing: Theme.spacingMedium
                readonly property real w: (width - spacing * 2) / 3

                OptionTile {
                    width: parent.w
                    height: 62
                    iconSize: 15
                    icon: "󰚰"
                    label: "Update [U]"
                    enabled: upd.updates !== 0
                    onClicked: upd.update()
                }
                OptionTile {
                    width: parent.w
                    height: 62
                    iconSize: 15
                    icon: "󰕍"
                    label: upd.armedRollback ? "Press again" : "Undo last [R]"
                    selected: upd.armedRollback
                    onClicked: upd.rollback()
                }
                OptionTile {
                    width: parent.w
                    height: 62
                    iconSize: 15
                    icon: "󰑓"
                    label: "Check [C]"
                    enabled: !upd.checking
                    onClicked: upd.refresh(true)
                }
            }

            Hint {
                text: "Security updates install automatically. Update and Undo open a terminal running dnf."
                wrapMode: Text.Wrap
                elide: Text.ElideNone
            }
        }
    }
}
