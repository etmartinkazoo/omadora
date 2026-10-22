import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam

// Session lock (ext-session-lock). Locked via `omadora-lock`, which swayidle
// runs for idle, before-sleep and `loginctl lock-session`; it waits for
// isSecure() so suspend can't race the lock.
// Authenticates through the same PAM stack as swaylock (/etc/pam.d/swaylock).
//
// Fingerprint: when fprintd has fingers enrolled for the user, a second PAM
// conversation (pam/fingerprint, fingerprint only) runs alongside the password
// one, so either unlocks. Without a reader or enrolled fingers it never starts.
Scope {
    id: lockScope

    property string password: ""
    property string status: ""
    property bool busy: false
    readonly property bool locked: sessionLock.locked
    readonly property string userName: Quickshell.env("USER") || ""

    // Fingerprint
    property bool fingerprintReady: false
    property string fingerprintStatus: ""
    property int fingerprintAttempts: 0
    readonly property int maxFingerprintAttempts: 5

    signal clearInputs()

    function lock() {
        if (sessionLock.locked) return;
        password = "";
        status = "";
        busy = false;
        ShellState.closePopup();
        sessionLock.locked = true;
        fingerprintReady = false;
        fingerprintStatus = "";
        fingerprintAttempts = 0;
        fprintCheck.running = true;
    }

    function startFingerprint() {
        if (!sessionLock.locked || !fingerprintReady || fpPam.active) return;
        if (fingerprintAttempts >= maxFingerprintAttempts) {
            fingerprintStatus = "Fingerprint paused: use your password";
            return;
        }
        fingerprintAttempts++;
        if (!fpPam.start()) fingerprintStatus = "";
    }

    function unlocked() {
        if (fpPam.active) fpPam.abort();
        fpRetry.stop();
        sessionLock.locked = false;
        finish("");
        fingerprintStatus = "";
    }

    // Enrolled fingers look like " - #0: right-index-finger"
    Process {
        id: fprintCheck
        command: ["fprintd-list", lockScope.userName]
        stdout: StdioCollector {
            onStreamFinished: {
                lockScope.fingerprintReady = /#\d+:/.test(text);
                if (lockScope.fingerprintReady) lockScope.startFingerprint();
            }
        }
    }

    PamContext {
        id: fpPam
        configDirectory: Quickshell.shellPath("pam")
        config: "fingerprint"
        user: lockScope.userName

        onPamMessage: {
            if (fpPam.responseRequired) fpPam.respond("");
            else if (fpPam.message !== "") lockScope.fingerprintStatus = fpPam.message;
        }

        onCompleted: function(result) {
            if (result === PamResult.Success) {
                lockScope.unlocked();
            } else {
                lockScope.fingerprintStatus = "Fingerprint not recognized";
                fpRetry.restart();
            }
        }

        onError: function(err) {
            lockScope.fingerprintStatus = "";
            fpRetry.restart();
        }
    }

    // Start listening again after a miss or a timeout
    Timer {
        id: fpRetry
        interval: 1500
        onTriggered: lockScope.startFingerprint()
    }

    function tryUnlock() {
        if (busy || password === "") return;
        busy = true;
        status = "Checking…";
        if (!pam.start()) {
            busy = false;
            status = "Couldn't start authentication";
        }
    }

    function finish(message) {
        busy = false;
        status = message;
        password = "";
        clearInputs();
    }

    PamContext {
        id: pam
        config: "swaylock"

        onPamMessage: {
            if (pam.responseRequired) pam.respond(lockScope.password);
            else if (pam.message !== "") lockScope.status = pam.message;
        }

        onCompleted: function(result) {
            if (result === PamResult.Success) {
                lockScope.unlocked();
            } else {
                lockScope.finish(result === PamResult.MaxTries ? "Too many attempts" : "Wrong password");
            }
        }

        onError: function(err) {
            lockScope.finish("Authentication error: " + PamError.toString(err));
        }
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
        enabled: sessionLock.locked
    }

    WlSessionLock {
        id: sessionLock

        WlSessionLockSurface {
            id: surface
            color: Theme.darkerBackground

            Rectangle {
                anchors.centerIn: parent
                width: 380
                height: lockCol.implicitHeight + Theme.paddingLarge * 2 + 8
                color: Theme.bgPanel
                border.color: lockScope.status !== "" && !lockScope.busy ? Theme.borderCritical : Theme.border
                border.width: Theme.borderWidth
                radius: Theme.radius

                Column {
                    id: lockCol
                    anchors.centerIn: parent
                    width: parent.width - Theme.paddingLarge * 2 - 8
                    spacing: Theme.spacingLarge

                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: {
                            const d = clock.date;
                            const h = d.getHours() % 12 || 12;
                            return h + ":" + ("0" + d.getMinutes()).slice(-2) + (d.getHours() >= 12 ? "pm" : "am");
                        }
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: 44
                        font.bold: true
                    }

                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: Qt.formatDate(clock.date, "dddd, MMMM d")
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontMedium
                    }

                    TextField {
                        id: passField
                        width: parent.width
                        height: 44
                        focus: true
                        enabled: !lockScope.busy
                        echoMode: TextInput.Password
                        horizontalAlignment: TextInput.AlignHCenter
                        leftPadding: Theme.inputPadding
                        rightPadding: Theme.inputPadding
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLarge
                        color: Theme.textPrimary
                        placeholderText: "󰌾  Password for " + lockScope.userName
                        placeholderTextColor: Theme.textPlaceholder
                        background: Rectangle {
                            color: Theme.bgItem
                            radius: Theme.radius
                        }
                        onTextChanged: lockScope.password = text
                        onAccepted: lockScope.tryUnlock()
                        Keys.onEscapePressed: text = ""
                        Component.onCompleted: forceActiveFocus()

                        Connections {
                            target: lockScope
                            function onClearInputs() {
                                passField.text = "";
                                passField.forceActiveFocus();
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: lockScope.status !== "" ? lockScope.status
                            : (lockScope.fingerprintReady ? (lockScope.fingerprintStatus || "Touch the fingerprint reader") + ", or type your password" : "Enter to unlock")
                        color: lockScope.status !== "" && !lockScope.busy ? Theme.borderCritical : Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontCaption
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "lock"
        function lock() { lockScope.lock(); }
        function isLocked(): bool { return sessionLock.locked; }
        // True once the compositor confirms every output is covered.
        function isSecure(): bool { return sessionLock.secure; }
    }
}
