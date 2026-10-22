import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Pill shown while omadora-dictate listens or transcribes. It never takes
// keyboard focus: the words are typed into whatever window had it.
Scope {
    id: dictation

    property string stage: "idle"      // idle | listening | transcribing | error
    property bool latched: false        // tapped on: press the key again to stop
    property string message: ""
    property real startedAt: 0
    property real now: Date.now()

    // Microphone level, newest last (omadora-dictate writes it ~20×/s).
    property var levels: []
    readonly property int bars: 14

    readonly property bool active: stage !== "idle"
    readonly property string elapsed: {
        const s = Math.max(0, Math.floor((now - startedAt) / 1000));
        return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2);
    }

    IpcHandler {
        target: "dictation"
        function listening(mode: string): void {
            if (dictation.stage !== "listening") {
                dictation.startedAt = Date.now();
                dictation.levels = [];
            }
            dictation.latched = mode === "latched";
            dictation.stage = "listening";
        }
        function transcribing(): void { dictation.stage = "transcribing"; }
        function idle(): void { dictation.stage = "idle"; }
        function settings(): void { settingsWindow.open(); }
        function hideSettings(): void { ShellState.closePopup("dictation"); }
        function error(msg: string): void {
            dictation.message = msg;
            dictation.stage = "error";
            errorTimer.restart();
        }
    }

    DictationSettings { id: settingsWindow }

    Timer {
        interval: 250
        repeat: true
        running: dictation.stage === "listening"
        onTriggered: dictation.now = Date.now()
    }

    FileView {
        id: levelFile
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omadora-dictate/level"
        printErrors: false
        onLoaded: {
            const v = parseFloat(text());
            if (!isNaN(v)) dictation.levels = dictation.levels.concat([v]).slice(-dictation.bars);
        }
    }

    // Poll rather than watch: the file only exists while recording.
    Timer {
        interval: 60
        repeat: true
        running: dictation.stage === "listening"
        onTriggered: levelFile.reload()
    }

    Timer {
        id: errorTimer
        interval: 3500
        onTriggered: if (dictation.stage === "error") dictation.stage = "idle"
    }

    PanelWindow {
        screen: ShellState.focusedScreen
        visible: dictation.active
        color: "transparent"
        anchors { bottom: !Desktop.barOnTop; top: Desktop.barOnTop }
        margins { bottom: Desktop.popupInset; top: Desktop.popupInset }
        implicitWidth: pill.width
        implicitHeight: pill.height
        exclusionMode: ExclusionMode.Ignore
        focusable: false
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "quickshell-dictation"

        Rectangle {
            id: pill
            width: row.implicitWidth + Theme.paddingLarge * 2
            height: 34
            color: Theme.bgPanel
            border.color: dictation.stage === "error" ? Theme.borderCritical
                : dictation.stage === "listening" ? Theme.red : Theme.border
            border.width: Theme.borderWidth
            radius: Theme.radius

            Row {
                id: row
                anchors.centerIn: parent
                spacing: Theme.spacingMedium

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 10
                    height: 10
                    radius: 5
                    visible: dictation.stage === "listening"
                    color: Theme.red
                    SequentialAnimation on opacity {
                        running: dictation.stage === "listening"
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.3; duration: 600 }
                        NumberAnimation { to: 1; duration: 600 }
                    }
                }

                // Live meter: your voice over the last ~second.
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: dictation.stage === "listening"
                    spacing: 2
                    height: 18
                    Repeater {
                        model: dictation.bars
                        delegate: Rectangle {
                            required property int index
                            readonly property real v: {
                                const l = dictation.levels;
                                const i = l.length - dictation.bars + index;
                                return i >= 0 ? l[i] : 0;
                            }
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3
                            radius: 1.5
                            // Quiet room ≈ 0.1: show from there up, so speech fills the bar.
                            height: Math.max(3, 18 * Math.min(1, Math.max(0, (v - 0.15) / 0.6)))
                            color: v > 0.3 ? Theme.accent : Theme.textSecondary
                            Behavior on height { NumberAnimation { duration: 60 } }
                        }
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: dictation.stage === "listening"
                        ? "Listening  " + dictation.elapsed + (dictation.latched ? "  · press again to stop" : "")
                        : dictation.stage === "transcribing" ? "󰗊  Transcribing…"
                        : dictation.message
                    color: dictation.stage === "error" ? Theme.borderCritical : Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontNormal
                }
            }

            // Click to stop (and type) while listening; on an error, open settings.
            MouseArea {
                anchors.fill: parent
                enabled: dictation.stage === "listening" || dictation.stage === "error"
                onClicked: {
                    if (dictation.stage === "error") {
                        dictation.stage = "idle";
                        settingsWindow.open();
                    } else {
                        Quickshell.execDetached([Quickshell.env("HOME") + "/.local/bin/omadora-dictate", "toggle"]);
                    }
                }
            }
        }
    }
}
