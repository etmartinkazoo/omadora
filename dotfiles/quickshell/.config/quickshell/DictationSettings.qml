import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Dictation settings: install the speech engine, pick a model, language,
// microphone and what happens with the text, and try it out. Everything is
// done through omadora-dictate (status/install/download/set/test).
Scope {
    id: settings

    readonly property string cli: Quickshell.env("HOME") + "/.local/bin/omadora-dictate"
    readonly property bool active: ShellState.activePopup === "dictation"

    property var info: null                 // `omadora-dictate status`
    property string busy: ""                // "install" | "download:<model>" | "test" | ""
    property var log: []                    // last lines of install/download output
    property string testResult: ""
    property bool testOk: true

    readonly property var cfg: info ? info.config : ({})
    // Ready once the engine is built and text can be typed; the other packages
    // only add GPU acceleration.
    readonly property bool ready: info !== null && info.whisper && info.missingPackages.indexOf("wtype") < 0
    readonly property bool gpuMissing: ready && !info.gpu && info.missingPackages.length > 0
    readonly property var modelOrder: ["base.en", "small.en", "large-v3-turbo-q5_0"]
    readonly property var modelLabels: ({ "base.en": "Fast", "small.en": "Balanced", "large-v3-turbo-q5_0": "Accurate" })

    function open() { ShellState.openPopup("dictation"); }
    function refresh() { statusProc.running = true; }

    function run(kind, args) {
        if (busy !== "") return;
        busy = kind;
        log = [];
        actionProc.command = [cli].concat(args);
        actionProc.running = true;
    }

    function set(key, value) {
        Quickshell.execDetached([cli, "set", key, value]);
        // Show it right away; the next status read confirms it.
        const c = Object.assign({}, cfg);
        c[key] = value;
        info = Object.assign({}, info, { config: c });
    }

    function chooseModel(name) {
        set("MODEL", name);
        if (!info.models[name].multilingual && cfg.LANGUAGE === "auto") set("LANGUAGE", "en");
        if (!info.models[name].present) run("download:" + name, ["download", name]);
    }

    function mb(bytes) { return Math.round(bytes / 1000000) + " MB"; }

    onActiveChanged: if (active) {
        testResult = "";
        refresh();
    }

    Process {
        id: statusProc
        command: [settings.cli, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { settings.info = JSON.parse(text); } catch (e) {}
            }
        }
    }

    Process {
        id: actionProc
        stdout: SplitParser {
            onRead: line => settings.log = settings.log.concat([line]).slice(-6)
        }
        stderr: SplitParser {
            onRead: line => settings.log = settings.log.concat([line]).slice(-6)
        }
        onExited: function(code) {
            if (code !== 0 && settings.log.length === 0) settings.log = ["Failed (exit " + code + ")"];
            else if (code === 0) settings.log = settings.log.concat(["✓ Done"]).slice(-6);
            settings.busy = "";
            settings.refresh();
        }
    }

    Process {
        id: testProc
        command: [settings.cli, "test", "4"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text);
                    settings.testOk = r.ok;
                    settings.testResult = r.ok
                        ? (r.text !== "" ? "“" + r.text + "”  · " + r.seconds + " s" : "Didn't catch anything")
                        : r.error;
                } catch (e) {
                    settings.testOk = false;
                    settings.testResult = "Test failed";
                }
            }
        }
        onExited: settings.busy = ""
    }

    // Microphones: PipeWire audio sources (not streams, not monitors).
    readonly property var sources: Pipewire.nodes.values.filter(n => n.audio && !n.isSink && !n.isStream)

    ShellPopup {
        name: "dictation"
        centered: true
        panelWidth: 520

        Column {
            width: parent.width
            spacing: Theme.spacingLarge

            RowLayout {
                width: parent.width
                PanelTitle {
                    text: "Dictation"
                    Layout.fillWidth: true
                }
                Text {
                    text: settings.info === null ? "…" : settings.ready ? "● Ready" : "● Needs setup"
                    color: settings.ready ? Theme.green : Theme.yellow
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Hold " + (settings.info ? settings.info.shortcut : "Super+Shift+D") + " and speak, then let go: the words are typed where your cursor is. Tap it to keep listening, and press again to stop. Speech is transcribed on this computer; nothing is sent anywhere."
                color: Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontCaption
            }

            // ---- Setup ----
            Column {
                width: parent.width
                spacing: Theme.spacingMedium
                Caption { text: "SPEECH ENGINE" }

                RowLayout {
                    width: parent.width
                    Text {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: settings.info === null ? "Checking…"
                            : settings.gpuMissing ? "✓ whisper.cpp installed · GPU acceleration off: install " + settings.info.missingPackages.join(", ") + " to make it faster"
                            : settings.ready ? "✓ whisper.cpp installed · GPU acceleration " + (settings.info.gpu ? "on" : "off")
                            : settings.info.missingPackages.length > 0
                                ? "Needs a few packages (" + settings.info.missingPackages.join(", ") + ") and a one-time build of the speech engine (a few minutes)."
                            : "The speech engine needs a one-time build (a few minutes)."
                        color: settings.ready ? Theme.textPrimary : Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontNormal
                    }
                    SmallButton {
                        visible: settings.info !== null && (!settings.ready || settings.gpuMissing)
                        text: settings.busy === "install" ? "INSTALLING…" : settings.gpuMissing ? "ENABLE GPU" : "INSTALL"
                        highlighted: true
                        onClicked: settings.run("install", ["install"])
                    }
                }

                Rectangle {
                    width: parent.width
                    height: logText.implicitHeight + Theme.paddingMedium * 2
                    visible: settings.log.length > 0
                    color: Theme.bgItem
                    border.width: 0
                    Text {
                        id: logText
                        anchors.fill: parent
                        anchors.margins: Theme.paddingMedium
                        text: settings.log.join("\n")
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSmall
                        wrapMode: Text.WrapAnywhere
                    }
                }
            }

            // ---- Model ----
            Column {
                width: parent.width
                spacing: Theme.spacingSmall
                visible: settings.info !== null
                Caption { text: "MODEL" }

                Repeater {
                    model: settings.info ? settings.modelOrder : []
                    delegate: ListRow {
                        id: modelRow
                        required property string modelData
                        readonly property var m: settings.info.models[modelData]
                        readonly property bool chosen: settings.cfg.MODEL === modelData
                        width: parent.width
                        height: 48
                        selected: chosen
                        onClicked: settings.chooseModel(modelData)

                        RowLayout {
                            anchors.fill: parent
                            spacing: Theme.spacingMedium
                            Text {
                                text: modelRow.chosen ? "◉" : "○"
                                color: modelRow.chosen ? Theme.accent : Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontLarge
                            }
                            Column {
                                Layout.fillWidth: true
                                Text {
                                    text: settings.modelLabels[modelRow.modelData] + "  ·  " + modelRow.modelData + "  ·  " + settings.mb(modelRow.m.size)
                                    color: Theme.textPrimary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontNormal
                                }
                                Text {
                                    text: modelRow.m.description
                                    color: Theme.textSecondary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSmall
                                }
                            }
                            Text {
                                text: settings.busy === "download:" + modelRow.modelData ? "downloading…"
                                    : modelRow.m.present ? "✓" : "download"
                                color: modelRow.m.present ? Theme.green : Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                            }
                        }
                    }
                }
            }

            // ---- Language, output ----
            GridLayout {
                width: parent.width
                visible: settings.info !== null
                columns: 2
                columnSpacing: Theme.spacingLarge
                rowSpacing: Theme.spacingMedium

                Caption { text: "LANGUAGE" }
                Caption { text: "WHEN DONE" }

                Row {
                    spacing: Theme.spacingSmall
                    SmallButton {
                        text: "ENGLISH"
                        highlighted: settings.cfg.LANGUAGE !== "auto"
                        onClicked: settings.set("LANGUAGE", "en")
                    }
                    SmallButton {
                        readonly property bool possible: settings.info && settings.info.models[settings.cfg.MODEL]
                            && settings.info.models[settings.cfg.MODEL].multilingual
                        text: "AUTO-DETECT"
                        opacity: possible ? 1 : 0.45
                        highlighted: settings.cfg.LANGUAGE === "auto"
                        onClicked: if (possible) settings.set("LANGUAGE", "auto")
                    }
                }

                Row {
                    spacing: Theme.spacingSmall
                    Repeater {
                        model: [["type", "TYPE IT"], ["clipboard", "COPY"], ["both", "BOTH"]]
                        delegate: SmallButton {
                            required property var modelData
                            text: modelData[1]
                            highlighted: (settings.cfg.OUTPUT || "type") === modelData[0]
                            onClicked: settings.set("OUTPUT", modelData[0])
                        }
                    }
                }

                Text {
                    text: settings.info && settings.info.models[settings.cfg.MODEL] && !settings.info.models[settings.cfg.MODEL].multilingual
                        ? "Auto-detect needs the Accurate model" : ""
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                }

                SmallButton {
                    text: (settings.cfg.SPACE !== "no" ? "☑" : "☐") + " SPACE AFTER"
                    onClicked: settings.set("SPACE", settings.cfg.SPACE !== "no" ? "no" : "yes")
                }
            }

            // ---- Voice commands ----
            Column {
                width: parent.width
                spacing: Theme.spacingMedium
                visible: settings.info !== null
                Caption { text: "VOICE COMMANDS" }
                RowLayout {
                    width: parent.width
                    SmallButton {
                        text: (settings.cfg.COMMANDS !== "no" ? "☑" : "☐") + " TEXT BY VOICE"
                        onClicked: settings.set("COMMANDS", settings.cfg.COMMANDS !== "no" ? "no" : "yes")
                    }
                    Text {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: "Say “text Sarah I'm on my way”: the phone panel opens with the message drafted for Sarah, and Enter sends it."
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSmall
                    }
                }
            }

            // ---- Microphone ----
            Column {
                width: parent.width
                spacing: Theme.spacingSmall
                visible: settings.info !== null
                Caption { text: "MICROPHONE" }

                ListRow {
                    width: parent.width
                    height: Theme.rowHeightCompact
                    selected: !settings.cfg.SOURCE
                    onClicked: settings.set("SOURCE", "")
                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        text: "System default"
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontNormal
                    }
                }
                Repeater {
                    model: settings.sources
                    delegate: ListRow {
                        required property var modelData
                        width: parent.width
                        height: Theme.rowHeightCompact
                        selected: settings.cfg.SOURCE === modelData.name
                        onClicked: settings.set("SOURCE", modelData.name)
                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            text: modelData.description || modelData.nickname || modelData.name
                            color: Theme.textPrimary
                            elide: Text.ElideRight
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontNormal
                        }
                    }
                }
            }

            // ---- Try it ----
            Column {
                width: parent.width
                spacing: Theme.spacingMedium
                visible: settings.ready

                Caption { text: "TRY IT" }
                RowLayout {
                    width: parent.width
                    SmallButton {
                        text: settings.busy === "test" ? "LISTENING (4 s)…" : "TEST MICROPHONE"
                        highlighted: settings.busy === "test"
                        onClicked: {
                            if (settings.busy !== "") return;
                            settings.busy = "test";
                            settings.testResult = "";
                            testProc.running = true;
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: settings.busy === "test" ? "Say something…" : settings.testResult
                        color: settings.testOk ? Theme.textPrimary : Theme.borderCritical
                        wrapMode: Text.WordWrap
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontNormal
                    }
                }
            }

            Hint { text: "Esc close · settings are saved in ~/.config/omadora/dictation.conf" }
        }
    }
}
