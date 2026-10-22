import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Updates panel (Quick Settings → Updates, or U there). Reads
// `omadora-update status`:
//   - signed image (Fedora Atomic / bootc): the running image, a staged update
//     waiting for a restart, and the previous image to roll back to. Updates
//     download in the background; you choose when to restart.
//   - regular install: how many updates dnf has; Update and Undo open a
//     terminal running dnf, so you see and confirm the changes.
// Checks every 6 hours and notifies once when something new is ready.
Scope {
    id: upd

    readonly property bool active: ShellState.activePopup === "updates"
    readonly property string cli: Quickshell.env("HOME") + "/.local/bin/omadora-update"

    property var status: ({})
    property bool checking: false
    property bool upgrading: false
    property string progress: ""
    property bool armedRollback: false

    readonly property bool atomic: status.kind === "atomic"
    readonly property bool staged: status.staged !== null && status.staged !== undefined
    readonly property int updates: status.updates ?? -1
    // Something to act on: shown on the Quick Settings pill
    readonly property bool attention: staged || updates > 0

    function refresh(check) {
        if (statusProc.running) return;
        if (check) checking = true;
        statusProc.command = check ? [cli, "status", "--check"] : [cli, "status"];
        statusProc.running = true;
    }

    function update() {
        if (atomic) {
            if (upgradeProc.running) return;
            upgrading = true;
            progress = "Starting…";
            upgradeProc.command = [cli, "upgrade"];
            upgradeProc.running = true;
        } else {
            ShellState.closePopup("updates");
            ShellState.launchInTerminal(["sh", "-c", "sudo dnf upgrade; echo; read -p 'Done. Press Enter to close.' _"]);
        }
    }

    function rollback() {
        if (!armedRollback) {
            armedRollback = true;
            disarm.restart();
            return;
        }
        armedRollback = false;
        if (atomic) {
            upgrading = true;
            progress = "Preparing the previous image…";
            upgradeProc.command = [cli, "rollback"];
            upgradeProc.running = true;
        } else {
            ShellState.closePopup("updates");
            ShellState.launchInTerminal(["sh", "-c", "sudo dnf history undo last; echo; read -p 'Done. Press Enter to close.' _"]);
        }
    }

    function restart() {
        Quickshell.execDetached(["systemctl", "reboot"]);
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
                    // Tell once, when something new shows up
                    const wasStaged = prev.staged !== null && prev.staged !== undefined;
                    const isStaged = next.staged !== null && next.staged !== undefined;
                    if (prev.kind !== undefined && ((isStaged && !wasStaged) || ((next.updates ?? 0) > 0 && (prev.updates ?? 0) === 0))) {
                        Quickshell.execDetached(["notify-send", "-a", "Updates", "-i", "system-software-update",
                            isStaged ? "Update ready" : "Updates available",
                            isStaged ? "Restart to apply it. Open Quick Settings → Updates." : "Open Quick Settings → Updates."]);
                    }
                } catch (e) {
                    console.warn("updates: bad status", e);
                }
            }
        }
    }

    Process {
        id: upgradeProc
        stdout: SplitParser { onRead: function(line) { if (line.trim() !== "") upd.progress = line.trim(); } }
        stderr: SplitParser { onRead: function(line) { if (line.trim() !== "") upd.progress = line.trim(); } }
        onExited: function(code) {
            upd.upgrading = false;
            upd.progress = code === 0 ? "" : "Didn't finish (exit " + code + "): " + upd.progress;
            upd.refresh(false);
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
        if (status.kind !== undefined && !checking && (!status.checked || Date.now() / 1000 - status.checked > 6 * 3600)) refresh(true);
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
                case Qt.Key_U: if (!upd.staged) upd.update(); break;
                case Qt.Key_R: upd.rollback(); break;
                case Qt.Key_Return:
                case Qt.Key_Enter: if (upd.staged) upd.restart(); break;
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
                        text: upd.staged ? "󰚰" : (upd.updates > 0 ? "󰏔" : (upd.updates === 0 ? "󰄬" : "󰔟"))
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
                            text: upd.upgrading ? "Updating…"
                                : upd.staged ? "Update ready: " + upd.status.staged.version
                                : upd.updates > 0 ? (upd.atomic ? "An update is available" : upd.updates + " updates available")
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
                            text: upd.upgrading ? upd.progress
                                : upd.staged ? "Restart to switch to it. Until then, nothing changes."
                                : upd.status.current ? "Running " + upd.status.current.version
                                    + (upd.status.current.time ? " · updated " + upd.date(upd.status.current.time) : "")
                                : ""
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                        Caption {
                            visible: (upd.status.error ?? "") !== "" || upd.progress.startsWith("Didn't")
                            width: parent.width
                            text: upd.progress.startsWith("Didn't") ? upd.progress : (upd.status.error ?? "")
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
                    icon: upd.staged ? "󰜉" : "󰚰"
                    label: upd.staged ? "Restart [Enter]" : "Update [U]"
                    enabled: !upd.upgrading && (upd.staged || upd.updates !== 0)
                    selected: upd.staged
                    onClicked: upd.staged ? upd.restart() : upd.update()
                }
                OptionTile {
                    width: parent.w
                    height: 62
                    iconSize: 15
                    icon: "󰕍"
                    label: upd.armedRollback ? "Press again" : (upd.atomic ? "Roll back [R]" : "Undo last [R]")
                    sublabel: upd.atomic && upd.status.rollback ? upd.status.rollback.version : ""
                    enabled: !upd.upgrading && (!upd.atomic || (upd.status.rollback ?? null) !== null)
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
                text: upd.atomic ? "The image updates in the background; you choose when to restart. The previous image is one restart away."
                    : "Security updates install automatically. Update and Undo open a terminal running dnf."
                wrapMode: Text.Wrap
                elide: Text.ElideNone
            }
        }
    }
}
