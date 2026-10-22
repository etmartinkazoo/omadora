import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import "Fuzzy.js" as Fuzzy

Scope {
    id: launcherScope

    readonly property bool active: ShellState.activePopup === "launcher"
    property int selectedIndex: 0
    property string query: ""

    // Frecency: launch count, decayed by days since last launch.
    function frecency(app) {
        const s = ShellState.settings.launchStats[app.name];
        if (!s) return 0;
        const days = (Date.now() - s.last) / 86400000;
        return s.count / (1 + days / 7);
    }

    function recordLaunch(app) {
        const stats = Object.assign({}, ShellState.settings.launchStats);
        const prev = stats[app.name] || { count: 0, last: 0 };
        stats[app.name] = { count: prev.count + 1, last: Date.now() };
        ShellState.settings.launchStats = stats;
    }

    // "= 2*(3+4)" -> "14". Only arithmetic characters are evaluated.
    readonly property string calcResult: {
        const q = query.trim();
        if (!q.startsWith("=")) return "";
        const expr = q.slice(1).trim();
        if (expr === "" || !/^[0-9+\-*/%().,^\s]+$/.test(expr)) return "";
        try {
            const v = Function("return (" + expr.replace(/\^/g, "**").replace(/,/g, "") + ");")();
            if (typeof v !== "number" || !isFinite(v)) return "";
            return String(Math.round(v * 1e10) / 1e10);
        } catch (e) {
            return "";
        }
    }

    readonly property var filteredApps: {
        if (calcResult !== "" || query.trim().startsWith("=")) return [];
        return search(query);
    }

    // Everything the launcher shows: apps, and while typing also open windows,
    // settings and files. Shared with the Start menu.
    readonly property var results: calcResult !== "" || query.trim().startsWith("=") ? [] : searchAll(query)

    onQueryChanged: requestFiles(query)

    // ---- One search for everything ----
    // Settings and actions you can reach by name
    readonly property var catalog: [
        { title: "Wi-Fi", words: "wifi network wireless internet", glyph: "󰖩", popup: "wifi" },
        { title: "Bluetooth", words: "bluetooth devices pair headphones", glyph: "󰂯", popup: "bluetooth" },
        { title: "Sound", words: "sound audio volume speakers microphone output input", glyph: "󰕾", popup: "audio" },
        { title: "Displays", words: "display monitor screen resolution scale arrange rotate projector", glyph: "󰍹", popup: "displays" },
        { title: "Updates", words: "update upgrade software system rollback", glyph: "󰚰", popup: "updates" },
        { title: "Themes", words: "theme colors appearance dark light", glyph: "󰔎", popup: "themes" },
        { title: "Next wallpaper", words: "wallpaper background", glyph: "󰸉", ipc: ["theme", "bgNext"] },
        { title: "Keybinds", words: "keyboard shortcuts keybindings hotkeys", glyph: "󰌌", popup: "keybinds" },
        { title: "Notifications", words: "notifications history", glyph: "󰂚", popup: "notifications" },
        { title: "Do not disturb", words: "dnd focus quiet silence notifications", glyph: "󰂛", ipc: ["notifications", "toggleDnd"] },
        { title: "Night light", words: "night light warmth blue light", glyph: "󰖔", ipc: ["nightlight", "togglePower"] },
        { title: "Keep awake", words: "caffeine idle sleep awake", glyph: "󰅶", ipc: ["caffeine", "toggle"] },
        { title: "Clipboard history", words: "clipboard paste copied", glyph: "󰅌", popup: "clipboard" },
        { title: "Screenshot or recording", words: "screenshot capture record screen recording", glyph: "󰄀", popup: "screenshot" },
        { title: "All windows", words: "overview mission control task view windows expose", glyph: "󰕰", popup: "overview" },
        { title: "Quick settings", words: "settings quick brightness", glyph: "󰒓", popup: "quick" },
        { title: "Desktop mode: Tiling", words: "mode tiling layout sway", glyph: "󰕰", cmd: ["omadora-mode", "set", "tiling"] },
        { title: "Desktop mode: Windows", words: "mode windows taskbar start menu floating", glyph: "󰖲", cmd: ["omadora-mode", "set", "windows"] },
        { title: "Desktop mode: macOS", words: "mode macos mac dock top bar floating", glyph: "󰀵", cmd: ["omadora-mode", "set", "macos"] },
        { title: "Battery and power", words: "battery power profile performance saver", glyph: "󰁹", popup: "system" },
        { title: "Lock screen", words: "lock screen away", glyph: "󰌾", cmd: ["loginctl", "lock-session"] },
        { title: "Suspend", words: "suspend sleep", glyph: "󰤄", cmd: ["systemctl", "suspend"] },
        { title: "Restart, power off, log out", words: "restart reboot shutdown power off log out logout", glyph: "󰐥", popup: "system" }
    ]

    function searchAll(text) {
        const q = text.trim();
        const apps = search(q);
        if (q === "") return apps.map(a => appItem(a));
        const out = apps.slice(0, 5).map(a => appItem(a));
        const ql = q.toLowerCase();

        const wins = WindowList.windowsByMru
            .map(w => ({ w: w, score: Math.max(Fuzzy.score(w.title, q), Fuzzy.score(WindowList.nameFor(w.appId), q) - 30) }))
            .filter(x => x.score >= 0)
            .sort((a, b) => b.score - a.score)
            .slice(0, 3);
        for (const x of wins) {
            out.push({ kind: "window", title: x.w.title, subtitle: WindowList.nameFor(x.w.appId)
                + (x.w.minimized ? " · minimized" : " · workspace " + x.w.workspace),
                iconSource: WindowList.iconFor(x.w.appId), id: x.w.id });
        }

        const settings = catalog
            .map(c => ({ c: c, score: Math.max(Fuzzy.score(c.title, q), c.words.split(" ").some(w => w.startsWith(ql)) ? 40 : -1) }))
            .filter(x => x.score >= 0)
            .sort((a, b) => b.score - a.score)
            .slice(0, 4);
        for (const x of settings) out.push(Object.assign({ kind: "setting", subtitle: "" }, x.c));

        if (fileQuery === q) {
            for (const f of fileResults) out.push(f);
        }
        return out;
    }

    function appItem(a) {
        return { kind: "app", title: a.name, subtitle: a.genericName || a.comment || "", iconSource: Quickshell.iconPath(a.icon, "application-x-executable"), app: a };
    }

    function runItem(item) {
        if (!item) return;
        switch (item.kind) {
        case "app": launchApp(item.app); break;
        case "window": WindowList.focus(item.id); break;
        case "file": ShellState.launch(["xdg-open", item.path]); break;
        case "setting":
            if (item.popup) ShellState.openPopup(item.popup);
            else if (item.ipc) Quickshell.execDetached(["qs", "ipc", "call"].concat(item.ipc));
            else if (item.cmd) Quickshell.execDetached(item.cmd);
            break;
        }
    }

    // Files in your home folder (find, 5 folders deep; hidden folders and
    // caches left out). Not plocate: Fedora's updatedb skips /home, a
    // separate btrfs subvolume.
    property var fileResults: []
    property string fileQuery: ""
    property string pendingFileQuery: ""
    readonly property string home: Quickshell.env("HOME")

    function requestFiles(text) {
        const q = text.trim();
        if (q.length < 3 || q.startsWith("=") || /[\0\n]/.test(q)) {
            fileTimer.stop();
            fileResults = [];
            fileQuery = q;
            return;
        }
        pendingFileQuery = q;
        fileTimer.restart();
    }

    Timer {
        id: fileTimer
        interval: 150
        onTriggered: {
            fileProc.running = false;
            fileProc.query = launcherScope.pendingFileQuery;
            // The query is passed as an argument, never spliced into the script
            fileProc.command = ["sh", "-c",
                "find \"$1\" -maxdepth 5 \\( -name '.*' -o -name node_modules -o -name __pycache__ -o -name target \\) -prune "
                + "-o -iname \"*$2*\" -print 2>/dev/null | head -n 40",
                "omadora-find", launcherScope.home, fileProc.query.replace(/[\\*?\[\]]/g, "\\$&")];
            fileProc.running = true;
        }
    }

    Process {
        id: fileProc
        property string query: ""
        stdout: StdioCollector {
            onStreamFinished: {
                const prefix = launcherScope.home + "/";
                const ql = fileProc.query.toLowerCase();
                const found = text.split("\n")
                    .filter(p => p.startsWith(prefix) && !p.slice(prefix.length).split("/").some(c => c.startsWith(".") || c === "node_modules" || c === "__pycache__"))
                    // the name itself must match, not just a folder above it
                    .filter(p => p.slice(p.lastIndexOf("/") + 1).toLowerCase().includes(ql))
                    .sort((a, b) => a.length - b.length)
                    .slice(0, 6);
                launcherScope.fileResults = found.map(p => {
                    const name = p.slice(p.lastIndexOf("/") + 1);
                    return { kind: "file", title: name, subtitle: "~/" + p.slice(prefix.length, p.lastIndexOf("/") + 1), glyph: name.includes(".") ? "󰈔" : "󰉋", path: p };
                });
                launcherScope.fileQuery = fileProc.query;
            }
        }
    }

    // App search shared with the Start menu: fuzzy over name, generic name,
    // command, comment and keywords, nudged by frecency. An empty query lists
    // every app, most used first.
    function search(text) {
        const all = DesktopEntries.applications.values.filter(app => !app.noDisplay);
        const q = text.trim();
        if (q === "") {
            return all.slice().sort((a, b) => (frecency(b) - frecency(a)) || a.name.localeCompare(b.name));
        }
        const scored = [];
        for (let i = 0; i < all.length; i++) {
            const app = all[i];
            const best = Math.max(
                Fuzzy.score(app.name, q),
                Fuzzy.score(app.genericName, q) - 50,
                Fuzzy.score(app.execString, q) - 80,
                Fuzzy.score(app.comment, q) - 100,
                Fuzzy.score(Fuzzy.joined(app.keywords), q) - 60);
            if (best >= 0) scored.push({ app: app, score: best + Math.min(150, frecency(app) * 20) });
        }
        scored.sort((a, b) => b.score - a.score || a.app.name.localeCompare(b.app.name));
        return scored.map(s => s.app);
    }

    readonly property int rowCount: calcResult !== "" ? 1 : results.length

    function launchSelected() {
        const text = query.trim();
        ShellState.closePopup("launcher");
        if (calcResult !== "") {
            Quickshell.execDetached(["wl-copy", "--", calcResult]);
            Quickshell.execDetached(["notify-send", "-t", "2000", "Copied", text.slice(1).trim() + " = " + calcResult]);
            return;
        }
        if (selectedIndex >= 0 && selectedIndex < results.length) {
            runItem(results[selectedIndex]);
            return;
        }
        // No match: run the text as a shell command.
        if (text !== "" && !text.startsWith("=")) ShellState.launch(["sh", "-c", text]);
    }

    function show() {
        if (Desktop.mode === "windows") ShellState.openPopup("start", undefined, 0);
        else ShellState.openPopup("launcher");
    }

    // Start a desktop entry (and count it for frecency)
    function launchApp(app) {
        recordLaunch(app);
        const argv = [];
        for (let i = 0; i < app.command.length; i++) argv.push(app.command[i]);
        if (argv.length === 0) return;
        if (app.runInTerminal) ShellState.launchInTerminal(argv);
        else ShellState.launch(argv, app.workingDirectory);
    }

    function move(delta) {
        if (rowCount === 0) return;
        selectedIndex = (selectedIndex + delta + rowCount) % rowCount;
        resultsList.positionViewAtIndex(selectedIndex, ListView.Contain);
    }

    onActiveChanged: {
        if (active) {
            launcherInput.text = "";
            selectedIndex = 0;
        }
    }

    IpcHandler {
        target: "launcher"
        // In Windows mode, the launcher key (Super+Space) opens the Start menu
        function open() { launcherScope.show(); }
        function show() { launcherScope.show(); }
        function hide() { ShellState.closePopup("launcher"); ShellState.closePopup("start"); }
        function toggle() {
            if (ShellState.activePopup === "launcher" || ShellState.activePopup === "start") hide();
            else launcherScope.show();
        }
        // Open the launcher with this already typed (scripts, tests)
        function search(text: string) {
            ShellState.openPopup("launcher");
            launcherInput.text = text;
        }
    }

    ShellPopup {
        name: "launcher"
        centered: true
        panelWidth: 560
        panelHeight: 440

        Column {
            anchors.fill: parent
            spacing: Theme.spacingMedium

            ThemedField {
                id: launcherInput
                width: parent.width
                focus: true
                placeholderText: "Search apps, windows, settings, files...  (= to calculate)"
                onTextChanged: {
                    launcherScope.query = text;
                    launcherScope.selectedIndex = 0;
                    resultsList.positionViewAtBeginning();
                }
                Keys.onDownPressed: launcherScope.move(1)
                Keys.onUpPressed: launcherScope.move(-1)
                Keys.onTabPressed: launcherScope.move(1)
                onAccepted: launcherScope.launchSelected()
            }

            // Calculator result
            ListRow {
                width: parent.width
                height: 44
                visible: launcherScope.calcResult !== ""
                selected: true
                onClicked: launcherScope.launchSelected()

                RowLayout {
                    anchors.fill: parent
                    spacing: Theme.spacingMedium
                    Text {
                        text: "󰃬"
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontIcon
                    }
                    Text {
                        text: launcherScope.calcResult
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLarge
                        font.bold: true
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        text: "Enter to copy"
                        color: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSmall
                    }
                }
            }

            ListView {
                id: resultsList
                width: parent.width
                height: parent.height - launcherInput.height - hintText.implicitHeight - Theme.spacingMedium * 2
                visible: launcherScope.calcResult === ""
                clip: true
                model: launcherScope.results
                currentIndex: launcherScope.selectedIndex
                spacing: Theme.spacingSmall

                delegate: ListRow {
                    required property var modelData
                    required property int index
                    width: resultsList.width
                    selected: index === launcherScope.selectedIndex
                    onEntered: launcherScope.selectedIndex = index
                    onClicked: {
                        launcherScope.selectedIndex = index;
                        launcherScope.launchSelected();
                    }

                    RowLayout {
                        anchors.fill: parent
                        spacing: Theme.spacingMedium

                        IconImage {
                            visible: !modelData.glyph
                            implicitSize: 20
                            source: modelData.iconSource ?? ""
                        }

                        Text {
                            visible: !!modelData.glyph
                            Layout.preferredWidth: 20
                            horizontalAlignment: Text.AlignHCenter
                            text: modelData.glyph ?? ""
                            color: Theme.accent
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontIcon
                        }

                        Text {
                            text: modelData.title
                            color: Theme.textPrimary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontMedium
                            elide: Text.ElideRight
                            Layout.maximumWidth: resultsList.width * 0.55
                        }

                        Text {
                            text: modelData.subtitle ?? ""
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontCaption
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        Caption {
                            visible: launcherScope.query.trim() !== ""
                            text: ({ app: "App", window: "Window", setting: "Setting", file: "File" })[modelData.kind] ?? ""
                            color: Theme.textMuted
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: launcherScope.results.length === 0 && launcherScope.calcResult === ""
                    text: launcherScope.query.trim().startsWith("=") ? "Enter an expression" : "Nothing found. Enter runs it as a command"
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontNormal
                }
            }

            Hint {
                id: hintText
                text: "↑/↓ navigate • Enter open • =2+2 calculate • Esc cancel"
            }
        }
    }
}
