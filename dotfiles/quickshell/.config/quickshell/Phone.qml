import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Bluetooth as BT
import "Fuzzy.js" as Fuzzy

// Phone panel: texts (SMS + RCS through Google Messages) and calls (the phone
// as a Bluetooth hands-free gateway). Everything comes from the
// omadora-phone daemon over $XDG_RUNTIME_DIR/omadora-phone.sock
// (protocol: omadora/phone/PROTOCOL.md). Slides in from the right; Super+P.
Scope {
    id: phone

    readonly property bool active: ShellState.activePopup === "phone"

    // shell.qml's BluetoothMenu: its adapter, deny-by-default pairing agent
    // (allowInAgent / clearPending) and pair/connect sequence (deviceAction).
    property var btTool: null

    // ---- Daemon state ----
    property bool daemonUp: false
    property string texting: "connecting"
    property string textingError: ""
    property var bluetooth: ({ connected: false, name: "", address: "" })
    property var conversations: []
    property var calls: []
    property var contacts: []
    property bool contactsLoaded: false

    // ---- UI state ----
    property string tab: "messages"          // "messages" | "calls"
    property var currentConv: null           // open conversation
    property var messages: []                // oldest first
    property bool loadingMessages: false
    property bool typing: false
    property string query: ""
    property int selectedIndex: 0
    property string dialQuery: ""
    property int dialIndex: 0
    property bool muted: false
    property bool callKeypad: false
    property string toneDigits: ""         // tones sent during this call, echoed
    property real now: Date.now()
    property string lastError: ""            // the hint line's notice (error or info)
    property bool noticeIsError: true
    property bool showArchived: false        // list shows archived conversations
    property var selection: ({})             // bulk selection: conversation id -> true
    property int anchorIndex: -1             // Shift+click range start
    property var pendingConfirm: null        // { text, label, run } for destructive actions
    property var replyTo: null               // message being replied to
    property var menuItems: []               // open context menu: [{ label, run, danger, enabled } | { separator } | { reactions, msg }]
    property real menuX: 0
    property real menuY: 0
    property int menuIndex: -1
    property string favDragId: ""            // favorite tile being dragged
    property int favDragTarget: -1           // its drop slot (or a list row's insert slot)
    property real favDragX: 0                // dragged tile's top-left, in favArea
    property real favDragY: 0
    property var searchResults: []           // message search: [{ conv, name, message }]
    property string searchResultsFor: ""     // the query those results answer
    property var rowDrag: null               // conversation dragged from the list (by its avatar)
    property real rowDragX: 0                // cursor, in the panel frame
    property real rowDragY: 0
    property bool rowDragOverFavs: false

    readonly property var reactionEmojis: ["👍", "😍", "😂", "😮", "😥", "😠", "👎"]
    readonly property int maxFavorites: 6

    // "inactive": Messages for web is open in another browser; sending still works
    // (the daemon takes the session back on the next request).
    readonly property bool textingReady: daemonUp && (texting === "connected" || texting === "inactive")
    readonly property bool callsReady: daemonUp && bluetooth && bluetooth.connected
    readonly property var inboxConversations: conversations.filter(c => !c.archived)
    readonly property var archivedConversations: conversations.filter(c => c.archived)
    readonly property int unreadCount: inboxConversations.filter(c => c.unread).length
    readonly property int selectionCount: Object.keys(selection).length
    readonly property var favoriteIds: ShellState.settings.phoneFavorites || []
    readonly property var favoriteConvs: favoriteIds.map(id => conversations.find(c => c.id === id)).filter(c => !!c)
    readonly property var incomingCall: {
        for (let i = 0; i < calls.length; i++) {
            if (calls[i].state === "incoming" || calls[i].state === "waiting") return calls[i];
        }
        return null;
    }
    readonly property bool hasIncoming: incomingCall !== null
    readonly property bool inCall: calls.some(c => c.state !== "incoming" && c.state !== "disconnected")
    readonly property string barText: "󰏲" + (unreadCount > 0 ? " " + unreadCount : "")

    readonly property bool queryIsNumber: /^[\d+\s\-().]+$/.test(query.trim()) && query.replace(/\D/g, "").length >= 3
    // While the favorites grid shows (inbox, no search, not selecting), its
    // conversations aren't repeated in the list; anywhere else they are.
    readonly property bool favGridShown: favoriteConvs.length > 0 && selectionCount === 0 && !showArchived && query.trim() === ""
    readonly property var filteredConversations: Fuzzy.filter(
        showArchived ? archivedConversations
            : (favGridShown ? inboxConversations.filter(c => favoriteIds.indexOf(c.id) < 0) : inboxConversations),
        query, c => [[c.name, 0], [c.number || "", 0], [c.snippet || "", 60]])
    // Message search runs once the query has 2+ characters (debounced; stale
    // replies are dropped).
    readonly property bool searchActive: query.replace(/\s/g, "").length >= 2
    readonly property var messageHits: searchActive && searchResultsFor === query ? searchResults : []
    readonly property var listItems: (queryIsNumber && selectionCount === 0 ? [{ kind: "new", number: query.trim() }] : [])
        .concat(filteredConversations.map(c => ({ kind: "conv", conv: c })))
        .concat(messageHits.length > 0 ? [{ kind: "header" }] : [])
        .concat(messageHits.map(r => ({ kind: "msg", result: r })))
    readonly property var dialMatches: dialQuery.trim() === "" ? []
        : Fuzzy.filter(contacts, dialQuery, c => [[c.name, 0], [(c.number || "").replace(/\D/g, ""), 0], [c.number || "", 0]]).slice(0, 40)

    // ---- Requests ----
    property int nextId: 1
    property var pending: ({})

    // quiet: the caller shows errors itself (no notice in the hint line).
    function request(cmd, fields, cb, quiet) {
        if (!daemonUp || !sock) {
            if (cb) cb(false, {}, "omadora-phone isn't running");
            return;
        }
        const msg = Object.assign({ cmd: cmd, id: nextId }, fields || {});
        if (cb || quiet) pending[nextId] = { cb: cb || null, quiet: !!quiet };
        nextId++;
        sock.write(JSON.stringify(msg) + "\n");
        sock.flush();
    }

    function showError(text) {
        lastError = text;
        noticeIsError = true;
        errorTimer.restart();
    }

    function showInfo(text) {
        lastError = text;
        noticeIsError = false;
        errorTimer.restart();
    }

    function handleLine(line) {
        let m;
        try {
            m = JSON.parse(line);
        } catch (e) {
            return;
        }
        if (m.event !== undefined) {
            handleEvent(m);
        } else if (m.id !== undefined) {
            const p = pending[m.id];
            delete pending[m.id];
            if (!m.ok && m.error && !(p && p.quiet)) showError(m.error);
            if (p && p.cb) p.cb(m.ok, m.data || {}, m.error || "");
        }
    }

    function handleEvent(m) {
        switch (m.event) {
        case "state":
            texting = m.texting || "error";
            textingError = m.textingError || "";
            bluetooth = m.bluetooth || { connected: false, name: "", address: "" };
            if (textingReady && active && !contactsLoaded) loadContacts();
            break;
        case "conversations":
            conversations = m.conversations || [];
            if (currentConv) {
                const fresh = conversations.find(c => c.id === currentConv.id);
                if (fresh) currentConv = fresh;
            }
            pruneSelection();
            seedFavorites();
            break;
        case "message":
            if (currentConv && m.conv === currentConv.id && m.message) upsertMessage(m.message);
            break;
        case "calls":
            calls = m.calls || [];
            if (calls.length === 0) {
                callKeypad = false;
                toneDigits = "";
            }
            break;
        case "messageDeleted":
            if (currentConv && m.conv === currentConv.id) {
                messages = messages.filter(x => x.id !== m.id);
                if (replyTo && replyTo.id === m.id) replyTo = null;
            }
            break;
        case "pairing":
            pairStage = m.stage || "";
            if (m.account) pairAccount = m.account;
            pairEmoji = m.emoji || "";
            pairError = m.error || "";
            break;
        case "typing":
            if (currentConv && m.conv === currentConv.id) {
                typing = !!m.typing;
                if (typing) typingTimer.restart();
            }
            break;
        }
    }

    function upsertMessage(msg) {
        const next = messages.slice();
        const i = next.findIndex(x => x.id === msg.id);
        if (i >= 0) next[i] = msg;
        else next.push(msg);
        next.sort((a, b) => a.ts - b.ts);
        messages = next;
        if (!msg.fromMe) typing = false;
    }

    // ---- Conversations ----
    function openConversation(conv) {
        // What's typed belongs to the conversation it was typed in.
        if (!currentConv || currentConv.id !== conv.id) {
            composeArea.text = "";
            voiceDraftShown = false;
        }
        currentConv = conv;
        messages = [];
        typing = false;
        replyTo = null;
        tab = "messages";
        voiceChooser = null;
        loadThread();
        Qt.callLater(() => { if (composeArea.enabled) composeArea.forceActiveFocus(); });
        // A voice draft kept while picking someone goes into this conversation.
        if (voiceDraftPending) {
            voiceDraftPending = false;
            placeVoiceDraft(voiceDraft);
        }
    }

    function loadThread() {
        if (!currentConv) return;
        const id = currentConv.id;
        loadingMessages = true;
        request("messages", { conv: id }, function(ok, d) {
            if (!currentConv || currentConv.id !== id) return;
            loadingMessages = false;
            if (ok) messages = d.messages || [];
        });
        request("markRead", { conv: id });
        request("focus", { conv: id });
    }

    function openConversationById(id, fallbackName) {
        const c = conversations.find(x => x.id === id);
        openConversation(c || { id: id, name: fallbackName || id, type: "SMS", group: false, number: fallbackName || "", readOnly: false });
    }

    function closeConversation() {
        currentConv = null;
        messages = [];
        typing = false;
        replyTo = null;
        composeArea.text = "";
        voiceDraftShown = false;
        request("focus", { conv: "" });
        Qt.callLater(() => searchInput.forceActiveFocus());
    }

    // The tab row's "+": an empty number field on the current tab (search
    // takes a number to text; the dial field calls it).
    function startNew() {
        setupOpen = false;
        if (tab === "calls") {
            dialField.text = "";
            Qt.callLater(() => dialField.forceActiveFocus());
            return;
        }
        if (currentConv) closeConversation();
        if (showArchived) setArchivedView(false);
        searchInput.text = "";
        Qt.callLater(() => searchInput.forceActiveFocus());
    }

    function startConversation(number) {
        request("newConversation", { number: number }, function(ok, d) {
            if (ok) {
                searchInput.text = "";
                openConversationById(d.conv, number);
            }
        });
    }

    function sendCurrent() {
        if (!currentConv) return;
        const text = composeArea.text.replace(/\s+$/, "");
        if (text.trim() === "") return;
        const conv = currentConv.id;
        const fields = { conv: conv, text: text };
        if (replyTo) fields.replyTo = replyTo.id;
        composeArea.text = "";
        replyTo = null;
        voiceDraftShown = false;
        request("send", fields, function(ok) {
            // Put it back so nothing typed is lost.
            if (!ok && composeArea.text === "" && currentConv && currentConv.id === conv) composeArea.text = text;
        });
    }

    function activateSelected() {
        const it = listItems[selectedIndex];
        if (!it) return;
        if (it.kind === "new") startConversation(it.number);
        else if (it.kind === "conv") openConversation(it.conv);
        else if (it.kind === "msg") openConversationById(it.result.conv, it.result.name);
    }

    function move(delta) {
        const n = listItems.length;
        if (n === 0) return;
        selectedIndex = (selectedIndex + delta + n) % n;
        if (listItems[selectedIndex].kind === "header" && n > 1) selectedIndex = (selectedIndex + delta + n) % n;
        convList.positionViewAtIndex(selectedIndex, ListView.Contain);
    }

    function loadContacts() {
        if (contactsLoaded) return;
        request("contacts", {}, function(ok, d) {
            if (ok) {
                contacts = d.contacts || [];
                contactsLoaded = true;
            }
        });
    }

    // ---- Voice drafts ----
    // omadora-dictate turns "text Sarah I'll be home at six" into
    // voiceText("Sarah I'll be home at six"): find the person, open their thread
    // and put the message in the compose box. Never sent automatically.
    property string voiceDraft: ""
    property bool voiceDraftShown: false     // the draft is in the compose box (strip above it)
    property bool voiceDraftPending: false   // no match yet: goes into the next conversation opened
    property var voiceChooser: null          // several people match: { name, message, candidates }
    property int voiceChooserIndex: 0

    function voiceWord(w) { return w.toLowerCase().replace(/^[.,:;!?"“”'‘’()-]+|[.,:;!?"“”'‘’()-]+$/g, ""); }
    function voiceName(n) { return (n || "").split(/\s+/).map(voiceWord).filter(w => w !== "").join(" "); }

    function voiceText(utterance) {
        ShellState.openPopup("phone");
        setupOpen = false;
        tab = "messages";
        closeMenu();
        const u = (utterance || "").trim();
        if (u === "") return;
        if (!contactsLoaded && daemonUp) {
            request("contacts", {}, function(ok, d) {
                if (ok) {
                    contacts = d.contacts || [];
                    contactsLoaded = true;
                }
                resolveVoice(u);
            });
        } else {
            resolveVoice(u);
        }
    }

    // "saying see you at 7" / ": call me back" -> "See you at 7" / "Call me back"
    function voiceMessage(words) {
        let m = words.join(" ").trim();
        for (let i = 0; i < 2; i++) m = m.replace(/^[\s,:;.-]+/, "").replace(/^(saying|that)\b/i, "");
        m = m.replace(/^[\s,:;.-]+/, "");
        return m.charAt(0).toUpperCase() + m.slice(1);
    }

    // People to text: 1:1 conversations, then contacts without one.
    function voicePeople() {
        const people = conversations.filter(c => !c.group && c.name).map(c => ({
            name: c.name, number: c.number || "", conv: c, ts: c.ts || 0, fav: isFavorite(c.id)
        }));
        const known = {};
        people.forEach(p => { if (numberKey(p.number)) known[numberKey(p.number)] = true; });
        contacts.forEach(c => {
            const k = numberKey(c.number);
            if (c.name && !(k && known[k])) {
                if (k) known[k] = true;
                people.push({ name: c.name, number: c.number || "", conv: null, ts: 0, fav: false });
            }
        });
        return people;
    }

    // People named at the start of `words`: the longest prefix (3, 2, then 1
    // words) equal to a whole name, or for one word, to a first name.
    function voiceMatch(words) {
        const people = voicePeople();
        for (let n = Math.min(3, words.length); n >= 1; n--) {
            const prefix = words.slice(0, n).map(voiceWord).filter(w => w !== "").join(" ");
            if (prefix === "") continue;
            const matches = people.filter(p => {
                const full = voiceName(p.name);
                return full === prefix || (n === 1 && full.split(" ")[0] === prefix);
            });
            if (matches.length > 0) return { matches: matches, used: n };
        }
        return { matches: [], used: 0 };
    }

    function spokenName(words) {
        const spoken = words.map(w => w.replace(/[.,:;!?]+$/, "")).join(" ");
        return spoken.charAt(0).toUpperCase() + spoken.slice(1);
    }

    function resolveVoice(u) {
        const words = u.split(/\s+/);
        const found = voiceMatch(words);
        const matches = found.matches;
        const used = found.used;
        if (matches.length === 0) {
            // Nobody by that name: search for it, keep the message for whoever is picked.
            const guess = voiceWord(words[0]);
            voiceDraft = voiceMessage(words.slice(1));
            voiceDraftPending = true;
            voiceChooser = null;
            if (currentConv) closeConversation();
            searchInput.text = guess;
            showError("No contact named " + guess + " — pick someone, your message is kept");
            Qt.callLater(() => searchInput.forceActiveFocus());
            return;
        }
        const message = voiceMessage(words.slice(used));
        // Favorites first, then most recent conversation, then contacts.
        matches.sort((a, b) => (b.fav ? 1 : 0) - (a.fav ? 1 : 0) || (b.conv ? 1 : 0) - (a.conv ? 1 : 0) || b.ts - a.ts);
        const withConv = matches.filter(m => !!m.conv);
        // One person, or one with a conversation and the rest contacts only: go.
        // Two people with conversations (two Sarahs): ask.
        if (matches.length === 1 || withConv.length === 1) voiceGo(withConv.length === 1 ? withConv[0] : matches[0], message);
        else {
            voiceChooser = { mode: "text", name: spokenName(words.slice(0, used)), message: message, candidates: matches };
            voiceChooserIndex = 0;
            if (currentConv) closeConversation();
            Qt.callLater(() => chooserView.forceActiveFocus());
        }
    }

    function voiceGo(person, message) {
        voiceChooser = null;
        voiceDraft = message;
        voiceDraftPending = false;
        if (person.conv) {
            openConversation(person.conv);
            placeVoiceDraft(message);
        } else {
            voiceDraftPending = true;
            request("newConversation", { number: person.number }, function(ok, d) {
                if (ok) openConversationById(d.conv, person.name);
            });
        }
    }

    // "call Sarah": find the person, then count down 3-2-1 on the call card
    // (CALL NOW / CANCEL) and dial. Several people: ask in the panel (picking
    // dials). Nobody: a red card for 4 s. Calls not connected: never dials.
    property var voiceCallTarget: null       // { name, number, color }
    property int voiceCallCount: 3
    property string voiceCallError: ""       // "notconnected", or the text shown in red

    function voiceCall(name) {
        const u = (name || "").trim();
        if (u === "") return;
        cancelVoiceCall();
        if (!contactsLoaded && daemonUp) {
            request("contacts", {}, function(ok, d) {
                if (ok) {
                    contacts = d.contacts || [];
                    contactsLoaded = true;
                }
                resolveVoiceCall(u);
            });
        } else {
            resolveVoiceCall(u);
        }
    }

    function resolveVoiceCall(u) {
        const words = u.split(/\s+/);
        const found = voiceMatch(words);
        const matches = found.matches.filter(m => numberKey(m.number) !== "");
        if (matches.length === 0) {
            voiceCallError = "No contact named " + spokenName(words);
            voiceCallErrorTimer.restart();
            return;
        }
        // Favorites first, then most recent conversation, then contacts; any
        // of them can be called, so more than one person means asking.
        matches.sort((a, b) => (b.fav ? 1 : 0) - (a.fav ? 1 : 0) || (b.conv ? 1 : 0) - (a.conv ? 1 : 0) || b.ts - a.ts);
        if (!callsReady) {
            voiceCallTarget = voiceCallPerson(matches[0]);
            voiceCallError = "notconnected";
            voiceCallErrorTimer.restart();
        } else if (matches.length === 1) {
            startVoiceCountdown(matches[0]);
        } else {
            ShellState.openPopup("phone");
            setupOpen = false;
            tab = "messages";
            if (currentConv) closeConversation();
            voiceChooser = { mode: "call", name: spokenName(words.slice(0, found.used)), message: "", candidates: matches };
            voiceChooserIndex = 0;
            Qt.callLater(() => chooserView.forceActiveFocus());
        }
    }

    // The call card shows the voice-call countdown / problem while no call is up.
    readonly property bool voiceCard: cardCalls.length === 0 && (!!voiceCallTarget || voiceCallError !== "")

    function voiceCallPerson(p) {
        return { name: p.name, number: p.number, color: p.conv && p.conv.color ? p.conv.color : Theme.accent };
    }

    function startVoiceCountdown(person) {
        voiceCallError = "";
        voiceCallTarget = voiceCallPerson(person);
        voiceCallCount = 3;
        voiceCountdown.restart();
    }

    // Through dial(): the pending-dial card takes over from the countdown.
    function voiceCallNow() {
        const t = voiceCallTarget;
        voiceCountdown.stop();
        voiceCallTarget = null;
        if (t && callsReady) dial(t.number);
    }

    function cancelVoiceCall() {
        voiceCountdown.stop();
        voiceCallErrorTimer.stop();
        voiceCallTarget = null;
        voiceCallError = "";
        if (voiceChooser && voiceChooser.mode === "call") voiceChooser = null;
    }

    // Chooser pick: text drafts open the thread; calls dial at once (choosing
    // is the confirmation).
    function chooserPick(person) {
        if (!voiceChooser) return;
        if (voiceChooser.mode === "call") {
            voiceChooser = null;
            ShellState.closePopup("phone");
            if (callsReady) dial(person.number);
        } else {
            voiceGo(person, voiceChooser.message);
        }
    }

    Timer {
        id: voiceCountdown
        interval: 1000
        repeat: true
        running: false
        onTriggered: {
            phone.voiceCallCount--;
            if (phone.voiceCallCount <= 0) phone.voiceCallNow();
        }
    }

    Timer {
        id: voiceCallErrorTimer
        interval: 4000
        onTriggered: {
            // "Calls aren't connected" stays a little longer than a plain error.
            if (phone.voiceCallError === "notconnected" && interval === 4000) {
                interval = 8000;
                restart();
                return;
            }
            interval = 4000;
            phone.voiceCallTarget = null;
            phone.voiceCallError = "";
        }
    }

    function placeVoiceDraft(message) {
        Qt.callLater(() => {
            composeArea.text = message;
            composeArea.cursorPosition = message.length;
            voiceDraftShown = message !== "";
            composeArea.forceActiveFocus();
        });
    }

    function discardVoiceDraft() {
        composeArea.text = "";
        voiceDraftShown = false;
        voiceDraft = "";
    }

    // ---- Setup (texts + Bluetooth calls) ----
    property bool setupOpen: false
    property string pairStage: ""            // texts: "" | starting | account | emoji | done | error
    property string pairAccount: ""
    property string pairEmoji: ""
    property string pairError: ""
    property string btStage: ""              // calls: "" | scanning | pairing | connecting | waiting | needsCalls | failed
    property string btTarget: ""             // address of the device being paired/connected
    property string btError: ""
    property bool setupDiscovering: false    // discovery we turned on (and must turn off)

    readonly property bool pairNeedsSignIn: pairStage === "error" && /firefox|google|sign|cookie|session/i.test(pairError)
    readonly property bool textsOk: daemonUp && ["connected", "connecting", "phone-offline", "inactive"].indexOf(texting) >= 0
    // Shown instead of the list while texts aren't paired; or on request.
    readonly property bool showSetup: daemonUp && (setupOpen || (texting === "unpaired" && tab === "messages"))
    readonly property var btAdapter: btTool ? btTool.adapter : null
    readonly property bool btOn: !!btAdapter && btAdapter.enabled
    readonly property var btDevices: btTool ? BT.Bluetooth.devices.values : []
    readonly property var btTargetDev: btTarget === "" ? null : (btDevices.find(d => d.address === btTarget) || null)

    function devName(d) { return d ? (d.name || d.deviceName || d.address) : ""; }
    function isPhoneDev(d) { return (d.icon || "") === "phone" || /pixel|phone|galaxy/i.test(devName(d)); }

    readonly property var pairedPhone: {
        const phones = btDevices.filter(d => (d.paired || d.bonded) && isPhoneDev(d));
        phones.sort((a, b) => (b.connected ? 1 : 0) - (a.connected ? 1 : 0));
        return phones.length > 0 ? phones[0] : null;
    }
    readonly property var discoveredDevices: {
        const list = btDevices.filter(d => !d.paired && !d.bonded && (d.name || d.deviceName));
        list.sort((a, b) => (isPhoneDev(b) ? 1 : 0) - (isPhoneDev(a) ? 1 : 0) || devName(a).localeCompare(devName(b)));
        return list;
    }
    readonly property int discoveredPhones: discoveredDevices.filter(d => isPhoneDev(d)).length

    function openSetup() {
        ShellState.openPopup("phone");
        setupOpen = true;
        tab = "messages";
        closeMenu();
    }

    function closeSetup() {
        cancelCalls();
        setupOpen = false;
        if (texting === "unpaired") tab = "calls";
        restoreFocus();
    }

    function pairTexts() {
        pairStage = "starting";
        pairError = "";
        pairEmoji = "";
        request("pairMessages", {}, function(ok, d, err) {
            if (!ok) {
                pairStage = "error";
                pairError = err;
            }
        });
    }

    function stopSetupDiscovery() {
        discoveryTimer.stop();
        if (setupDiscovering && btAdapter && btAdapter.discovering) btAdapter.discovering = false;
        setupDiscovering = false;
    }

    function startScan() {
        if (!btOn) return;
        btError = "";
        btStage = "scanning";
        if (!btAdapter.discovering) {
            btAdapter.discovering = true;
            setupDiscovering = true;
        }
        discoveryTimer.restart();
    }

    // Pairing and connecting go through BluetoothMenu.deviceAction(): it tells
    // the agent to allow this device, then pairs (or connects if bonded).
    function pairDevice(d) {
        stopSetupDiscovery();
        btTarget = d.address;
        btError = "";
        btStage = "pairing";
        btTool.deviceAction(d);
    }

    function connectDevice(d) {
        btTarget = d.address;
        btError = "";
        if (d.connected) {
            waitForCalls();
            return;
        }
        btStage = "connecting";
        btTool.deviceAction(d);
    }

    // Connected over Bluetooth; the daemon reports calls once the Pixel offers
    // the hands-free profile.
    function waitForCalls() {
        if (callsReady) {
            btStage = "";
            return;
        }
        btStage = "waiting";
        callsWait.restart();
    }

    function btFailed(text) {
        btError = text;
        btStage = "failed";
        callsWait.stop();
    }

    function cancelCalls() {
        stopSetupDiscovery();
        callsWait.stop();
        const d = btTargetDev;
        if (btStage === "pairing" && d && d.pairing) d.cancelPair();
        if ((btStage === "pairing" || btStage === "connecting") && btTool) btTool.clearPending();  // revokes the agent allowance
        btStage = "";
        btTarget = "";
    }

    onCallsReadyChanged: {
        if (callsReady && btStage !== "") {
            stopSetupDiscovery();
            callsWait.stop();
            btStage = "";
            btTarget = "";
        }
    }

    onTextsOkChanged: if (textsOk) pairStage = ""

    // The device being set up: trust it once paired, then connect (BluetoothMenu's
    // own sequence), and wait for calls once connected.
    Connections {
        target: phone.btTargetDev
        ignoreUnknownSignals: true
        function onPairedChanged() {
            const d = phone.btTargetDev;
            if (phone.btStage === "pairing" && d.paired && !d.connected && !d.pairing) {
                d.trusted = true;
                phone.btStage = "connecting";
                phone.btTool.pendingAction = "connecting";
                d.connect();
            }
        }
        function onPairingChanged() {
            const d = phone.btTargetDev;
            if (phone.btStage === "pairing" && !d.pairing && !d.paired) pairFailCheck.restart();
        }
        // The link comes up during pairing too, before the bond exists: only a
        // connection to a paired device counts.
        function onConnectedChanged() {
            const d = phone.btTargetDev;
            if (d.connected && (d.paired || d.bonded) && (phone.btStage === "connecting" || phone.btStage === "pairing")) {
                d.trusted = true;
                phone.waitForCalls();
            }
        }
    }

    Timer {
        id: pairFailCheck
        interval: 1500
        onTriggered: {
            const d = phone.btTargetDev;
            if (phone.btStage === "pairing" && d && !d.paired && !d.pairing) phone.btFailed("Pairing didn't finish. Try again, and accept the request on the Pixel.");
        }
    }

    // Connecting that never completes
    Timer {
        interval: 30000
        running: phone.btStage === "connecting"
        onTriggered: phone.btFailed("Couldn't connect to " + phone.devName(phone.btTargetDev) + ".")
    }

    Timer {
        id: discoveryTimer
        interval: 120000
        onTriggered: {
            phone.stopSetupDiscovery();
            if (phone.btStage === "scanning") phone.btStage = "";
        }
    }

    Timer {
        id: callsWait
        interval: 20000
        onTriggered: if (!phone.callsReady) phone.btStage = "needsCalls"
    }

    // ---- Message search ----
    onQueryChanged: {
        if (searchActive) searchDebounce.restart();
        else {
            searchDebounce.stop();
            searchResults = [];
            searchResultsFor = "";
        }
    }

    function runSearch() {
        const q = query;
        if (!searchActive) return;
        request("search", { text: q }, function(ok, d) {
            if (!ok || query !== q) return;  // stale: the field changed meanwhile
            searchResults = d.results || [];
            searchResultsFor = q;
        });
    }

    // Keep the cursor off the section header.
    onListItemsChanged: {
        const it = listItems[selectedIndex];
        if (it && it.kind === "header") selectedIndex = Math.min(selectedIndex + 1, listItems.length - 1);
    }

    function escapeHtml(t) {
        return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // The message text around the first match, escaped, with the query's words
    // highlighted (Text.StyledText).
    function highlight(text, q) {
        let t = (text || "").replace(/\s+/g, " ").trim();
        const words = q.trim().split(/\s+/).filter(w => w !== "");
        const lower = t.toLowerCase();
        let first = -1;
        for (let i = 0; i < words.length; i++) {
            const k = lower.indexOf(words[i].toLowerCase());
            if (k >= 0 && (first < 0 || k < first)) first = k;
        }
        if (first > 50) t = "…" + t.slice(first - 30);
        t = escapeHtml(t);
        if (words.length === 0) return t;
        const pattern = words.map(w => escapeHtml(w).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
        return t.replace(new RegExp("(" + pattern + ")", "gi"),
            '<b><font color="' + Theme.accent + '">$1</font></b>');
    }

    function convColor(id) {
        const c = conversations.find(x => x.id === id);
        return c && c.color ? c.color : Theme.accent;
    }

    // ---- Bulk selection ----
    function isSelected(id) { return !!selection[id]; }
    function selectedIds() { return Object.keys(selection); }

    function setSelected(ids, on) {
        const next = Object.assign({}, selection);
        for (let i = 0; i < ids.length; i++) {
            if (on) next[ids[i]] = true;
            else delete next[ids[i]];
        }
        selection = next;
    }

    function toggleSelect(id, index) {
        setSelected([id], !isSelected(id));
        if (index !== undefined) anchorIndex = index;
    }

    function selectRange(to) {
        const from = anchorIndex >= 0 ? anchorIndex : to;
        const ids = [];
        for (let i = Math.min(from, to); i <= Math.max(from, to); i++) {
            const it = listItems[i];
            if (it && it.kind === "conv") ids.push(it.conv.id);
        }
        setSelected(ids, true);
    }

    function selectAllVisible() {
        setSelected(listItems.filter(it => it.kind === "conv").map(it => it.conv.id), true);
    }

    function clearSelection() {
        selection = {};
        anchorIndex = -1;
    }

    // Drop selected conversations that left the current view (deleted, archived…).
    function pruneSelection() {
        if (selectionCount === 0) return;
        const visible = {};
        (showArchived ? archivedConversations : inboxConversations).forEach(c => visible[c.id] = true);
        const next = {};
        Object.keys(selection).forEach(id => { if (visible[id]) next[id] = true; });
        selection = next;
    }

    function setArchivedView(on) {
        showArchived = on;
        clearSelection();
        selectedIndex = 0;
        convList.positionViewAtBeginning();
    }

    // Row click: Ctrl toggles, Shift selects a range, and while anything is
    // selected a plain click toggles too. Otherwise it opens the conversation.
    function rowClicked(index, conv, mouse) {
        if (listItems[index] && listItems[index].kind === "header") return;
        selectedIndex = index;
        if (!conv) {
            activateSelected();
        } else if (mouse.modifiers & Qt.ShiftModifier) {
            selectRange(index);
        } else if ((mouse.modifiers & Qt.ControlModifier) || selectionCount > 0) {
            toggleSelect(conv.id, index);
        } else {
            openConversation(conv);
        }
    }

    // Keys shared by the search field and the list (while selecting, the
    // search row is hidden and the panel itself has focus).
    function listKey(event, fromField) {
        if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_A) {
            selectAllVisible();
            event.accepted = true;
        } else if (event.key === Qt.Key_Space && (selectionCount > 0 || !fromField || query === "")) {
            const it = listItems[selectedIndex];
            if (it && it.kind === "conv") toggleSelect(it.conv.id, selectedIndex);
            event.accepted = true;
        } else if (!fromField && event.key === Qt.Key_Down) {
            move(1);
            event.accepted = true;
        } else if (!fromField && event.key === Qt.Key_Up) {
            move(-1);
            event.accepted = true;
        }
    }

    function bulk(cmd) {
        const ids = selectedIds();
        if (ids.length === 0) return;
        request(cmd, { convs: ids }, function(ok) { if (ok) clearSelection(); });
    }

    // Delete / block / report spam: ask first, in the confirm strip.
    function confirmConvs(cmd, ids) {
        if (ids.length === 0) return;
        const n = ids.length;
        const what = n === 1 ? "this conversation" : n + " conversations";
        let text, label;
        if (cmd === "delete") {
            text = "Delete " + what + "? This deletes " + (n === 1 ? "it" : "them") + " on your phone.";
            label = "DELETE";
        } else if (cmd === "block") {
            text = "Block " + (n === 1 ? "this sender" : "the senders of " + n + " conversations") + "? "
                + (n === 1 ? "The conversation goes" : "Their conversations go") + " away.";
            label = "BLOCK";
        } else {
            text = "Report " + what + " as spam? " + (n === 1 ? "The sender is" : "The senders are") + " blocked too.";
            label = "REPORT";
        }
        pendingConfirm = {
            text: text,
            label: label,
            run: function() {
                request(cmd, { convs: ids }, function(ok) {
                    if (!ok) return;
                    setSelected(ids, false);
                    if (currentConv && ids.indexOf(currentConv.id) >= 0) closeConversation();
                });
            }
        };
    }

    function runConfirm() {
        const c = pendingConfirm;
        pendingConfirm = null;
        if (c) c.run();
    }

    // ---- Favorites (ordered conversation ids in the shell settings) ----
    function isFavorite(id) { return favoriteIds.indexOf(id) >= 0; }

    function pinFavorite(id) {
        if (isFavorite(id)) return;
        if (favoriteIds.length >= maxFavorites) {
            showError("Favorites are full (" + maxFavorites + ")");
            return;
        }
        ShellState.settings.phoneFavorites = favoriteIds.concat([id]);
    }

    function unpinFavorite(id) {
        ShellState.settings.phoneFavorites = favoriteIds.filter(x => x !== id);
    }

    function moveFavorite(id, delta) {
        const f = favoriteIds.slice();
        const i = f.indexOf(id);
        const j = i + delta;
        if (i < 0 || j < 0 || j >= f.length) return;
        f[i] = f[j];
        f[j] = id;
        ShellState.settings.phoneFavorites = f;
    }

    // Once, start favorites from Google Messages' own pins (newest first).
    function seedFavorites() {
        if (!ShellState.settingsLoaded || ShellState.settings.phoneFavoritesSeeded || conversations.length === 0) return;
        if (favoriteIds.length === 0) {
            ShellState.settings.phoneFavorites = conversations.filter(c => c.pinned)
                .sort((a, b) => b.ts - a.ts).slice(0, maxFavorites).map(c => c.id);
        }
        ShellState.settings.phoneFavoritesSeeded = true;
    }

    // Favorites as laid out right now: during a drag, the dragged tile sits at its
    // drop slot (and a list row being dragged in gets a "__drop__" placeholder).
    readonly property bool canPinRowDrag: !!rowDrag && !isFavorite(rowDrag.id) && favoriteIds.length < maxFavorites
    readonly property var favDisplayIds: {
        let ids = favoriteConvs.map(c => c.id);
        if (favDragId !== "" && favDragTarget >= 0) {
            ids = ids.filter(x => x !== favDragId);
            ids.splice(Math.min(favDragTarget, ids.length), 0, favDragId);
        } else if (rowDragOverFavs && canPinRowDrag && favDragTarget >= 0) {
            ids.splice(Math.min(favDragTarget, ids.length), 0, "__drop__");
        }
        return ids;
    }

    // Slot under a point in favArea's 3-column layout, for `n` slots.
    function favSlotAt(px, py, n) {
        const tileH = 84;
        const sp = Theme.spacingMedium;
        const rows = Math.max(1, Math.ceil(n / 3));
        const col = Math.max(0, Math.min(2, Math.floor(px / (favArea.tileW + sp))));
        const row = Math.max(0, Math.min(rows - 1, Math.floor(py / (tileH + sp))));
        return Math.max(0, Math.min(n - 1, row * 3 + col));
    }

    function startFavDrag(id, x, y) {
        favDragId = id;
        favDragX = x;
        favDragY = y;
        favDragTarget = favoriteConvs.findIndex(c => c.id === id);
    }

    function moveFavDrag(x, y) {
        favDragX = x;
        favDragY = y;
        favDragTarget = favSlotAt(x + favArea.tileW / 2, y + 42, favoriteConvs.length);
    }

    // Write the order on screen; ids of favorites whose conversation isn't
    // loaded keep their place at the end.
    function writeFavoriteOrder(ids) {
        const shown = ids.filter(x => x !== "__drop__");
        ShellState.settings.phoneFavorites = shown.concat(favoriteIds.filter(x => shown.indexOf(x) < 0));
    }

    function commitFavDrag() {
        const ids = favDisplayIds;
        favDragId = "";
        favDragTarget = -1;
        writeFavoriteOrder(ids);
    }

    function startRowDrag(conv) {
        rowDrag = conv;
        rowDragOverFavs = false;
        favDragTarget = -1;
    }

    function moveRowDrag(fx, fy) {
        rowDragX = fx;
        rowDragY = fy;
        const p = frame.mapToItem(favArea, fx, fy);
        rowDragOverFavs = favArea.visible && p.x >= 0 && p.x <= favArea.width && p.y >= -12 && p.y <= favArea.height + 12;
        favDragTarget = rowDragOverFavs ? favSlotAt(p.x, Math.max(0, p.y), favoriteConvs.length + 1) : -1;
    }

    function dropRow() {
        const c = rowDrag;
        const over = rowDragOverFavs;
        const ids = favDisplayIds;
        rowDrag = null;
        rowDragOverFavs = false;
        favDragTarget = -1;
        if (!c || !over) return;
        if (isFavorite(c.id)) showInfo("Already a favorite");
        else if (favoriteIds.length >= maxFavorites) showError("Favorites are full (" + maxFavorites + ")");
        else writeFavoriteOrder(ids.map(x => x === "__drop__" ? c.id : x));
    }

    function cancelDrags() {
        favDragId = "";
        rowDrag = null;
        rowDragOverFavs = false;
        favDragTarget = -1;
    }

    Connections {
        target: ShellState
        function onSettingsLoadedChanged() { phone.seedFavorites(); }
    }

    // ---- Messages: replies, reactions, menus ----
    function messageById(id) { return messages.find(x => x.id === id) || null; }

    function senderOf(m) {
        if (!m) return "";
        return m.fromMe ? "You" : (m.sender || (currentConv ? currentConv.name : ""));
    }

    function snippetOf(m) {
        if (!m) return "";
        const t = (m.text || "").replace(/\s+/g, " ").trim();
        if (t !== "") return t.length > 80 ? t.slice(0, 80) + "…" : t;
        return (m.media || []).length > 0 ? "📎 attachment" : "";
    }

    function imageOf(m) {
        const media = (m && m.media) || [];
        for (let i = 0; i < media.length; i++) {
            if ((media[i].mime || "").indexOf("image/") === 0 && media[i].path) return media[i].path;
        }
        return "";
    }

    function hasMyReaction(m, emoji) {
        return ((m && m.reactions) || []).some(r => r.emoji === emoji && r.mine);
    }

    function react(m, emoji) {
        if (!currentConv || !m) return;
        request("react", { conv: currentConv.id, message: m.id, emoji: emoji, remove: hasMyReaction(m, emoji) });
    }

    function startReply(m) {
        replyTo = m;
        Qt.callLater(() => composeArea.forceActiveFocus());
    }

    function copyText(text) {
        Quickshell.execDetached(["wl-copy", "--", text]);
        showInfo("Copied");
    }

    function saveImage(path) {
        Quickshell.execDetached(["sh", "-c",
            'd=$(xdg-user-dir DOWNLOAD 2>/dev/null); { [ -n "$d" ] && [ "$d" != "$HOME" ]; } || d="$HOME/Downloads"; '
            + 'mkdir -p "$d" && cp --backup=numbered -- "$1" "$d/"', "_", path]);
        showInfo("Saved to Downloads");
    }

    function conversationMenu(c) {
        const oneToOne = !c.group && !!c.number;
        const fav = isFavorite(c.id);
        const items = [{ label: "Open", run: () => openConversation(c) }];
        if (c.unread) items.push({ label: "Mark read", run: () => request("markRead", { conv: c.id }) });
        items.push({ label: fav ? "Unpin from favorites" : "Pin to favorites", run: () => fav ? unpinFavorite(c.id) : pinFavorite(c.id) });
        items.push({ label: c.archived ? "Unarchive" : "Archive", run: () => request(c.archived ? "unarchive" : "archive", { conv: c.id }) });
        if (oneToOne && callsReady) items.push({ label: "Call", run: () => dial(c.number) });
        if (oneToOne) items.push({ label: "Copy number", run: () => copyText(c.number) });
        items.push({ label: isSelected(c.id) ? "Deselect" : "Select", run: () => toggleSelect(c.id) });
        items.push({ separator: true });
        items.push({ label: "Delete…", danger: true, run: () => confirmConvs("delete", [c.id]) });
        items.push({ label: "Block…", danger: true, run: () => confirmConvs("block", [c.id]) });
        items.push({ label: "Report spam…", danger: true, run: () => confirmConvs("reportSpam", [c.id]) });
        return items;
    }

    function favoriteMenu(c) {
        const i = favoriteIds.indexOf(c.id);
        const items = [{ label: "Open", run: () => openConversation(c) }];
        if (!c.group && c.number && callsReady) items.push({ label: "Call", run: () => dial(c.number) });
        items.push({ label: "Unpin", run: () => unpinFavorite(c.id) });
        if (i > 0) items.push({ label: "Move left", run: () => moveFavorite(c.id, -1) });
        if (i >= 0 && i < favoriteIds.length - 1) items.push({ label: "Move right", run: () => moveFavorite(c.id, 1) });
        return items;
    }

    function messageMenu(m) {
        const canWrite = textingReady && currentConv && !currentConv.readOnly;
        const items = [];
        if (canWrite) {
            items.push({ label: "Reply", run: () => startReply(m) });
            items.push({ reactions: true, msg: m });
        }
        if (m.text) items.push({ label: "Copy text", run: () => copyText(m.text) });
        const img = imageOf(m);
        if (img !== "") {
            items.push({ label: "Open image", run: () => ShellState.launch(["xdg-open", img]) });
            items.push({ label: "Save image to Downloads", run: () => saveImage(img) });
        }
        items.push({ separator: true });
        items.push({
            label: "Delete…", danger: true,
            run: () => {
                const conv = currentConv.id;
                pendingConfirm = {
                    text: "Delete this message? Only removes it from your phone.",
                    label: "DELETE",
                    run: () => request("deleteMessage", { conv: conv, message: m.id })
                };
            }
        });
        return items;
    }

    // ---- Context menu ----
    function menuSelectable(i) {
        const it = menuItems[i];
        return !!it && !it.separator && !it.reactions && it.enabled !== false;
    }

    function openMenu(items, item, x, y) {
        const p = item.mapToItem(frame, x, y);
        menuX = p.x;
        menuY = p.y;
        menuItems = items;
        menuIndex = -1;
        menuMove(1);
        Qt.callLater(() => menuFocus.forceActiveFocus());
    }

    function closeMenu() {
        if (menuItems.length === 0) return;
        menuItems = [];
        restoreFocus();
    }

    function menuMove(delta) {
        const n = menuItems.length;
        for (let step = 1; step <= n; step++) {
            const i = ((menuIndex < 0 && delta < 0 ? 0 : menuIndex) + delta * step + n * step) % n;
            if (menuSelectable(i)) {
                menuIndex = i;
                return;
            }
        }
    }

    function menuActivate(i) {
        if (!menuSelectable(i)) return;
        const it = menuItems[i];
        closeMenu();
        it.run();
    }

    function restoreFocus() {
        Qt.callLater(() => {
            if (!active) return;
            if (tab === "calls") dialField.forceActiveFocus();
            else if (currentConv && composeArea.enabled) composeArea.forceActiveFocus();
            else if (currentConv || selectionCount > 0) scope.forceActiveFocus();
            else searchInput.forceActiveFocus();
        });
    }

    // While selecting, the search row is replaced by the action bar.
    onSelectionCountChanged: {
        if (menuItems.length === 0 && tab === "messages" && !currentConv) restoreFocus();
    }

    // ---- Calls ----
    // Dialing shows the call card at once ("Calling …" with End), before and
    // even without a `calls` event: the phone doesn't always report the call.
    // Cleared when a real call appears, on End, on a dial error (shown in the
    // card for 4 s), or after 60 s without the call connecting. If the phone
    // never reports the call, the call audio stands in for it: audio up =
    // connected (timer runs), audio down again = someone hung up (card closes).
    property var pendingDial: null           // { number, name, since, error, connectedAt }

    function dial(number) {
        const n = (number || "").trim();
        if (n === "") return;
        pendingDial = { number: n, name: nameForNumber(n), since: Date.now(), error: "" };
        request("dial", { number: n }, function(ok, d, err) {
            if (ok || !pendingDial || pendingDial.number !== n) return;
            pendingDial = Object.assign({}, pendingDial, { error: err || "Couldn't place the call" });
            pendingErrorTimer.restart();
        }, true);
    }

    function endPending() {
        request("hangupAll", {});
        pendingDial = null;
    }

    // Calls as the call cards show them: the phone's calls, else the pending dial.
    readonly property var liveCalls: calls.filter(c => c.state !== "disconnected")
    readonly property var cardCalls: liveCalls.length > 0 ? liveCalls
        : (pendingDial ? [{ path: "", state: pendingDial.connectedAt ? "active" : "pending", number: pendingDial.number,
                            name: pendingDial.name, since: pendingDial.connectedAt || pendingDial.since, incoming: false }] : [])
    readonly property var primaryCall: {
        if (incomingCall) return incomingCall;
        const live = cardCalls.filter(c => c.state !== "held");
        return live.length > 0 ? live[0] : (cardCalls.length > 0 ? cardCalls[0] : null);
    }

    onBluetoothChanged: {
        if (!pendingDial || pendingDial.error) return;
        const audioUp = bluetooth.audio === "active";
        if (audioUp && !pendingDial.connectedAt)
            pendingDial = Object.assign({}, pendingDial, { connectedAt: Date.now() });
        else if (!audioUp && pendingDial.connectedAt)
            pendingDial = null;   // the call ended (either side hung up)
    }

    onCallsChanged: {
        if (pendingDial && calls.some(c => c.state !== "incoming" && c.state !== "waiting" && c.state !== "disconnected")) {
            pendingDial = null;
            pendingErrorTimer.stop();
        }
    }

    // Last 10 digits, to match numbers written differently.
    function numberKey(n) { return (n || "").replace(/\D/g, "").slice(-10); }

    function nameForNumber(number) {
        const k = numberKey(number);
        if (k.length < 7) return "";
        const conv = conversations.find(c => !c.group && numberKey(c.number) === k);
        if (conv) return conv.name;
        const contact = contacts.find(c => numberKey(c.number) === k);
        return contact ? contact.name : "";
    }

    function callName(c) { return c ? (c.name || nameForNumber(c.number) || c.number || "Unknown") : ""; }

    function colorForNumber(number) {
        const k = numberKey(number);
        const conv = k.length >= 7 ? conversations.find(c => !c.group && numberKey(c.number) === k) : null;
        return conv && conv.color ? conv.color : Theme.accent;
    }

    Timer {
        id: pendingErrorTimer
        interval: 4000
        onTriggered: phone.pendingDial = null
    }

    Timer {
        interval: 60000
        running: !!phone.pendingDial && !phone.pendingDial.error && !phone.pendingDial.connectedAt
        onTriggered: phone.pendingDial = null
    }

    function dialSelected() {
        const c = dialMatches[dialIndex];
        if (c && dialField.text.replace(/\D/g, "") !== dialField.text.trim()) dial(c.number);
        else if (dialField.text.trim() !== "") dial(dialField.text);
        else if (c) dial(c.number);
    }

    function answer(call) { request("answer", { call: call.path }); }
    function hangup(call) {
        if (!call || !call.path) endPending();   // the pending dial: no call object yet
        else request("hangup", { call: call.path });
    }
    function toggleMute() {
        Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]);
        muted = !muted;
        muteCheck.restart();
    }

    // ---- Formatting ----
    function clock(d) {
        const h12 = d.getHours() % 12 || 12;
        return h12 + ":" + ("0" + d.getMinutes()).slice(-2) + (d.getHours() >= 12 ? "pm" : "am");
    }

    function relTime(ts) {
        if (!ts) return "";
        const d = new Date(ts);
        const n = new Date();
        if (d.toDateString() === n.toDateString()) return clock(d);
        const days = (new Date(n.getFullYear(), n.getMonth(), n.getDate()) - new Date(d.getFullYear(), d.getMonth(), d.getDate())) / 86400000;
        if (days < 7) return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()];
        return (d.getMonth() + 1) + "/" + d.getDate() + (d.getFullYear() !== n.getFullYear() ? "/" + String(d.getFullYear()).slice(2) : "");
    }

    function stampTime(ts) {
        const d = new Date(ts);
        const today = d.toDateString() === new Date().toDateString();
        return today ? clock(d) : relTime(ts) + " " + clock(d);
    }

    function duration(ms) {
        const s = Math.max(0, Math.floor(ms / 1000));
        const h = Math.floor(s / 3600);
        const m = Math.floor((s % 3600) / 60);
        const sec = ("0" + (s % 60)).slice(-2);
        return h > 0 ? h + ":" + ("0" + m).slice(-2) + ":" + sec : m + ":" + sec;
    }

    function initials(name) {
        const n = (name || "").trim();
        if (n === "" || /^[\d+(]/.test(n)) return "#";
        const parts = n.split(/[\s,]+/).filter(p => p !== "");
        return (parts[0][0] + (parts.length > 1 ? parts[1][0] : "")).toUpperCase();
    }

    function callStateText(c) {
        switch (c.state) {
        case "active": return duration(now - c.since);
        case "held": return "On hold";
        case "pending":
        case "dialing":
        case "alerting": return "Calling…";
        case "incoming": return "Incoming call";
        case "waiting": return "Call waiting";
        default: return c.state;
        }
    }

    function statusText(s) {
        switch (s) {
        case "sending": return "sending…";
        case "failed": return "failed";
        case "received": return "";
        default: return s || "";
        }
    }

    readonly property string textingLabel: {
        if (!daemonUp) return "offline";
        switch (texting) {
        case "connected": return "texts";
        case "connecting": return "connecting…";
        case "phone-offline": return "phone offline";
        case "inactive": return "in use elsewhere";
        case "unpaired": return "texts not set up";
        default: return textingError !== "" ? textingError : "error";
        }
    }

    readonly property color tintedBubble: Qt.tint(Theme.bgItem, Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.28))

    // ---- Lifecycle ----
    onActiveChanged: {
        if (active) {
            // Don't wait for the slow background retry when the panel opens.
            if (!daemonUp) reconnect();
            if (textingReady) loadContacts();
            if (currentConv && tab === "messages") loadThread();
            Qt.callLater(() => {
                if (tab === "calls") dialField.forceActiveFocus();
                else if (currentConv && composeArea.enabled) composeArea.forceActiveFocus();
                else searchInput.forceActiveFocus();
            });
        } else {
            request("focus", { conv: "" });
        }
    }

    onTabChanged: Qt.callLater(() => {
        if (tab === "calls") {
            loadContacts();
            dialField.forceActiveFocus();
        } else if (currentConv) {
            composeArea.forceActiveFocus();
        } else {
            searchInput.forceActiveFocus();
        }
    })

    // The connected Socket (set from its own signal: LazyLoader.item isn't
    // assigned yet when a fast connect completes).
    property var sock: null

    function onSocketState(s, connected) {
        sock = connected ? s : null;
        daemonUp = connected;
        if (connected) {
            request("hello", {});
            if (active && currentConv) loadThread();
        } else {
            const p = pending;
            pending = {};
            for (const k in p) if (p[k].cb) p[k].cb(false, {}, "disconnected");
            calls = [];
            texting = "connecting";
        }
    }

    // A fresh Socket per attempt: after a failed connect, Quickshell's Socket
    // ignores further requests to connect.
    LazyLoader {
        id: sockLoader
        active: true
        component: Socket {
            id: socket
            path: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/omadora-phone.sock"
            connected: true
            parser: SplitParser {
                onRead: data => phone.handleLine(data)
            }
            onConnectionStateChanged: phone.onSocketState(socket, connected)
        }
    }

    // The daemon may start after the shell, or restart: keep trying (often while
    // the panel is open, rarely otherwise: each failed attempt logs a warning).
    Timer {
        interval: phone.active ? 3000 : 20000
        repeat: true
        running: !phone.daemonUp
        onTriggered: phone.reconnect()
    }

    function reconnect() {
        sockLoader.active = false;
        sockLoader.active = true;
    }

    Timer {
        id: searchDebounce
        interval: 250
        onTriggered: phone.runSearch()
    }

    Timer {
        id: errorTimer
        interval: 6000
        onTriggered: phone.lastError = ""
    }

    Timer {
        id: typingTimer
        interval: 15000
        onTriggered: phone.typing = false
    }

    Timer {
        interval: 1000
        repeat: true
        running: phone.cardCalls.length > 0
        onTriggered: phone.now = Date.now()
    }

    // Mic mute state while in a call (the call uses the default source).
    Timer {
        id: muteCheck
        interval: 1500
        repeat: true
        running: phone.cardCalls.length > 0
        triggeredOnStart: true
        onTriggered: muteProc.running = true
    }

    Process {
        id: muteProc
        command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@"]
        stdout: StdioCollector {
            onStreamFinished: phone.muted = text.indexOf("MUTED") >= 0
        }
    }

    IpcHandler {
        target: "phone"
        function toggle(): void { ShellState.togglePopup("phone"); }
        function open(): void { ShellState.openPopup("phone"); }
        function hide(): void { ShellState.closePopup("phone"); }
        function openConversation(conv: string): void {
            ShellState.openPopup("phone");
            phone.openConversationById(conv, "");
        }
        function dial(number: string): void { phone.dial(number); }
        function answer(): void { if (phone.incomingCall) phone.answer(phone.incomingCall); }
        function hangup(): void { phone.endPending(); }
        function setup(): void { phone.openSetup(); }
        function voiceText(utterance: string): void { phone.voiceText(utterance); }
        function voiceCall(name: string): void { phone.voiceCall(name); }
        function cancelVoiceCall(): void { phone.cancelVoiceCall(); }
    }

    // ---- Shared pieces ----
    component ActionButton: Rectangle {
        id: ab
        property string text: ""
        property string tooltip: ""
        property bool tooltipBelow: Desktop.barOnTop
        property color tint: Theme.accent
        property bool filled: false
        property bool enabledState: true
        signal clicked()

        Tip {
            target: ab
            text: ab.tooltip
            hovered: abMouse.containsMouse
            below: ab.tooltipBelow
        }

        implicitHeight: 28
        implicitWidth: abLabel.implicitWidth + 18
        opacity: enabledState ? 1 : 0.4
        color: filled ? Qt.tint(Theme.bgItem, Qt.rgba(tint.r, tint.g, tint.b, abMouse.containsMouse ? 0.55 : 0.4))
            : (abMouse.containsMouse && enabledState ? Theme.bgSelected : Theme.bgItem)
        border.color: filled ? tint : Theme.border
        border.width: 0
        radius: Theme.radius

        Text {
            id: abLabel
            anchors.centerIn: parent
            text: ab.text
            color: Theme.textPrimary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontCaption
        }

        MouseArea {
            id: abMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: ab.enabledState
            onClicked: ab.clicked()
        }
    }

    // Square icon button for the tab row; a count shows beside the icon.
    component IconTab: Rectangle {
        id: itab
        property string glyph: ""
        property string tooltip: ""
        property int count: 0
        property bool highlighted: false
        signal clicked()

        Tip {
            target: itab
            text: itab.tooltip
            hovered: itMouse.containsMouse
        }

        implicitHeight: 28
        implicitWidth: Math.max(28, itRow.implicitWidth + 16)
        color: highlighted || itMouse.containsMouse ? Theme.bgSelected : Theme.bgItem
        radius: Theme.radius

        Row {
            id: itRow
            anchors.centerIn: parent
            spacing: 5
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: itab.glyph
                color: itab.highlighted ? Theme.textPrimary : Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontIcon
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: itab.count > 0
                text: itab.count
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSmall
                font.bold: true
            }
        }

        MouseArea {
            id: itMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: itab.clicked()
        }
    }

    component Keypad: GridLayout {
        id: kp
        signal pressed(string key)
        columns: 3
        rowSpacing: Theme.spacingSmall * 2
        columnSpacing: Theme.spacingSmall * 2

        Repeater {
            model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
            delegate: Rectangle {
                required property string modelData
                Layout.fillWidth: true
                Layout.preferredHeight: 36
                color: keyMouse.containsMouse ? Theme.bgSelected : Theme.bgItem
                border.color: Theme.borderSubtle
                border.width: 0
                radius: Theme.radius

                Text {
                    anchors.centerIn: parent
                    text: parent.modelData
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontLarge
                }

                MouseArea {
                    id: keyMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: kp.pressed(parent.modelData)
                }
            }
        }
    }

    component Avatar: Rectangle {
        property string name: ""
        property color tint: Theme.accent
        property int size: 34
        property bool showInitials: true
        width: size
        height: size
        color: Qt.tint(Theme.bgItem, Qt.rgba(tint.r, tint.g, tint.b, 0.45))
        border.color: tint
        border.width: 0
        radius: Theme.radius

        Text {
            anchors.centerIn: parent
            text: parent.showInitials ? phone.initials(parent.name) : ""
            color: Theme.textPrimary
            font.family: Theme.fontFamily
            font.pixelSize: parent.size >= 44 ? Theme.fontLarge + 2 : Theme.fontCaption
            font.bold: true
        }
    }

    // A setup step: number (or ✓ when done), title, and its body while not done.
    component StepCard: Rectangle {
        id: step
        property int number: 1
        property string title: ""
        property bool done: false
        property string summary: ""
        default property alias body: stepBody.data
        implicitHeight: stepCol.implicitHeight + Theme.paddingLarge * 2
        color: Theme.bgItem
        border.color: done ? Theme.borderSubtle : Theme.border
        border.width: 0
        radius: Theme.radius

        Column {
            id: stepCol
            x: Theme.paddingLarge
            y: Theme.paddingLarge
            width: parent.width - Theme.paddingLarge * 2
            spacing: Theme.spacingLarge

            Row {
                spacing: Theme.spacingMedium

                Rectangle {
                    width: 26
                    height: 26
                    color: step.done ? Qt.tint(Theme.bgItem, Qt.rgba(Theme.green.r, Theme.green.g, Theme.green.b, 0.35)) : Theme.bgSelected
                    border.color: step.done ? Theme.green : Theme.border
                    border.width: Theme.borderWidth
                    radius: Theme.radius

                    Text {
                        anchors.centerIn: parent
                        text: step.done ? "✓" : step.number
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontNormal
                        font.bold: true
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: step.done && step.summary !== "" ? step.summary : step.title
                    color: step.done ? Theme.textSecondary : Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontMedium
                    font.bold: !step.done
                }
            }

            Column {
                id: stepBody
                width: parent.width
                visible: !step.done
                spacing: Theme.spacingMedium
            }
        }
    }

    component Chip: Item {
        id: chip
        property string text: ""
        property bool ok: false
        property bool warn: false
        property bool clickable: false
        signal clicked()
        implicitWidth: chipRow.implicitWidth
        implicitHeight: chipRow.implicitHeight

        Row {
            id: chipRow
            spacing: 5

            Rectangle {
                width: 7
                height: 7
                anchors.verticalCenter: parent.verticalCenter
                color: chip.warn ? Theme.yellow : (chip.ok ? Theme.green : Theme.textMuted)
                radius: Theme.radius
            }

            Text {
                text: chip.text
                color: chip.warn ? Theme.yellow : (chip.ok ? Theme.textSecondary : Theme.textMuted)
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSmall
                font.underline: chip.clickable
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: chip.clickable
            cursorShape: chip.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: chip.clicked()
        }
    }

    // ---- Panel ----
    PanelWindow {
        id: panel

        // 0 = shown, 1 = off-screen to the right.
        property real slide: phone.active ? 0 : 1
        Behavior on slide { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        screen: ShellState.popupScreen
        visible: phone.active || slide < 1
        color: "transparent"
        anchors { top: true; bottom: true; right: true }
        margins {
            top: Desktop.barOnTop ? Desktop.popupInset : Desktop.edgeGap
            bottom: Desktop.barOnTop ? Desktop.edgeGap : Desktop.popupInset
            right: Desktop.edgeGap
        }
        // Extra room on the left for the shadow; only the frame takes input.
        implicitWidth: 440 + Theme.shadowMargin
        mask: Region { item: frame }
        exclusionMode: ExclusionMode.Ignore
        focusable: true
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: phone.active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "quickshell-phone"

        Shadow { target: frame }

        Rectangle {
            id: frame
            width: parent.width - Theme.shadowMargin
            height: parent.height
            x: Theme.shadowMargin + panel.slide * (parent.width + Desktop.edgeGap)
            color: Theme.bgPanel
            // The open panel is the active "window": accent frame like ShellPopup.
            border.color: Theme.accent
            border.width: Theme.panelBorderWidth
            radius: Theme.radius

            MouseArea {
                anchors.fill: parent
                onClicked: scope.forceActiveFocus()
            }

            FocusScope {
                id: scope
                anchors.fill: parent
                anchors.margins: Theme.paddingLarge
                focus: true

                // Esc backs out one step at a time.
                Keys.onEscapePressed: {
                    if (phone.favDragId !== "" || phone.rowDrag) phone.cancelDrags();
                    else if (phone.setupOpen) phone.closeSetup();
                    else if (phone.voiceChooser) phone.voiceChooser = null;  // text or call chooser
                    else if (phone.tab === "messages" && phone.currentConv && phone.voiceDraftShown) phone.discardVoiceDraft();
                    else if (phone.pendingConfirm) phone.pendingConfirm = null;
                    else if (phone.tab === "messages" && phone.currentConv && phone.replyTo) phone.replyTo = null;
                    else if (phone.tab === "messages" && phone.currentConv) phone.closeConversation();
                    else if (phone.tab === "messages" && phone.selectionCount > 0) phone.clearSelection();
                    else ShellState.closePopup("phone");
                }
                Keys.onPressed: function(event) {
                    if (event.modifiers & Qt.ControlModifier) {
                        if (event.key === Qt.Key_1) { phone.tab = "messages"; event.accepted = true; return; }
                        else if (event.key === Qt.Key_2) { phone.tab = "calls"; event.accepted = true; return; }
                    }
                    if (phone.tab === "messages" && !phone.currentConv && phone.selectionCount > 0) phone.listKey(event, false);
                }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Theme.spacingMedium

                    // Header
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingLarge

                        PanelTitle { text: "Phone" }
                        Item { Layout.fillWidth: true }
                        Chip {
                            text: phone.textingLabel
                            ok: phone.textingReady
                            warn: phone.daemonUp && phone.texting === "inactive"
                            clickable: phone.daemonUp && (phone.texting === "unpaired" || phone.texting === "error")
                            onClicked: phone.openSetup()
                            Layout.maximumWidth: 220
                        }
                        Chip {
                            text: phone.callsReady ? "calls: " + (phone.bluetooth.name || "phone") : "calls: not connected"
                            ok: phone.callsReady
                            clickable: !phone.callsReady && phone.daemonUp
                            onClicked: phone.openSetup()
                        }
                        ActionButton {
                            id: headerMore
                            implicitHeight: 22
                            text: "⋯"
                            onClicked: phone.openMenu([{ label: "Set up phone", run: () => phone.openSetup() }],
                                headerMore, 0, headerMore.height)
                        }
                    }

                    // Calls in progress
                    Repeater {
                        model: phone.cardCalls
                        delegate: Rectangle {
                            id: callCard
                            required property var modelData
                            readonly property bool ringing: modelData.state === "incoming" || modelData.state === "waiting"
                            Layout.fillWidth: true
                            Layout.preferredHeight: callRow.implicitHeight + Theme.paddingMedium * 2
                            color: ringing ? Qt.tint(Theme.bgItem, Qt.rgba(Theme.green.r, Theme.green.g, Theme.green.b, 0.15)) : Theme.bgItem
                            border.color: ringing ? Theme.green : Theme.border
                            border.width: ringing ? Theme.borderWidth : 0
                            radius: Theme.radius

                            RowLayout {
                                id: callRow
                                anchors.fill: parent
                                anchors.margins: Theme.paddingMedium
                                spacing: Theme.spacingMedium

                                Avatar {
                                    name: phone.callName(callCard.modelData)
                                    tint: callCard.ringing ? Theme.green : phone.colorForNumber(callCard.modelData.number)
                                }

                                Column {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    Text {
                                        width: parent.width
                                        text: phone.callName(callCard.modelData)
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontMedium
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        width: parent.width
                                        text: (phone.callName(callCard.modelData) !== callCard.modelData.number ? callCard.modelData.number + " · " : "") + phone.callStateText(callCard.modelData)
                                        color: Theme.textSecondary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                        elide: Text.ElideRight
                                    }
                                }

                                ActionButton {
                                    visible: callCard.ringing
                                    text: callCard.modelData.state === "waiting" && phone.inCall ? "HOLD + ANSWER" : "ANSWER"
                                    tint: Theme.green
                                    filled: true
                                    onClicked: {
                                        if (callCard.modelData.state === "waiting" && phone.inCall) phone.request("holdAndAnswer", {});
                                        else phone.answer(callCard.modelData);
                                    }
                                }
                                ActionButton {
                                    text: callCard.ringing ? "DECLINE" : "END"
                                    tint: Theme.red
                                    filled: true
                                    onClicked: phone.hangup(callCard.modelData)
                                }
                            }
                        }
                    }

                    // In-call controls
                    RowLayout {
                        Layout.fillWidth: true
                        visible: phone.inCall
                        spacing: Theme.spacingMedium

                        ActionButton {
                            text: phone.muted ? "󰍭  UNMUTE" : "󰍬  MUTE"
                            tint: Theme.red
                            filled: phone.muted
                            onClicked: phone.toggleMute()
                        }
                        ActionButton {
                            text: "󰌌  KEYPAD"
                            filled: phone.callKeypad
                            onClicked: phone.callKeypad = !phone.callKeypad
                        }
                        ActionButton {
                            visible: phone.calls.length >= 2
                            text: "󰓡  SWAP"
                            onClicked: phone.request("swap", {})
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: phone.callKeypad ? phone.toneDigits : ""
                            color: Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontNormal
                        }
                    }

                    Keypad {
                        Layout.fillWidth: true
                        visible: phone.inCall && phone.callKeypad
                        onPressed: function(key) {
                            phone.request("tones", { tones: key });
                            phone.toneDigits = (phone.toneDigits + key).slice(-16);
                        }
                    }

                    // Tabs
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingSmall * 2

                        IconTab {
                            glyph: "󰍩"
                            tooltip: "Messages  (Ctrl+1)"
                            count: phone.unreadCount
                            highlighted: phone.tab === "messages"
                            onClicked: {
                                phone.setupOpen = false;
                                phone.tab = "messages";
                            }
                        }
                        IconTab {
                            glyph: "󰏲"
                            tooltip: "Calls  (Ctrl+2)"
                            highlighted: phone.tab === "calls"
                            onClicked: {
                                phone.setupOpen = false;
                                phone.tab = "calls";
                            }
                        }
                        Item { Layout.fillWidth: true }
                        IconTab {
                            glyph: "󰐕"
                            tooltip: phone.tab === "calls" ? "New call" : "New message"
                            onClicked: phone.startNew()
                        }
                    }

                    // Body
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        // Daemon not reachable
                        Column {
                            anchors.centerIn: parent
                            width: parent.width
                            spacing: Theme.spacingMedium
                            visible: !phone.daemonUp

                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: "omadora-phone isn't running."
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontNormal
                            }
                            ActionButton {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "START"
                                tint: Theme.accent
                                filled: true
                                onClicked: {
                                    ShellState.launch(["systemctl", "--user", "start", "omadora-phone"]);
                                    phone.reconnect();
                                }
                            }
                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                text: "systemctl --user start omadora-phone"
                                color: Theme.textMuted
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall - 1
                            }
                        }

                        // ---- Set up phone ----
                        Flickable {
                            id: setupView
                            anchors.fill: parent
                            visible: phone.showSetup
                            clip: true
                            contentHeight: setupCol.implicitHeight
                            boundsBehavior: Flickable.StopAtBounds

                            Column {
                                id: setupCol
                                width: setupView.width
                                spacing: Theme.spacingLarge

                                Text {
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    text: "Set up your phone: texts come from Google Messages through your Google account; calls go over Bluetooth."
                                    color: Theme.textSecondary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSmall
                                }

                                // Step 1: texts
                                StepCard {
                                    width: parent.width
                                    number: 1
                                    title: "Texts (Google Messages)"
                                    done: phone.textsOk
                                    summary: "Texts paired"

                                    Text {
                                        width: parent.width
                                        visible: phone.pairStage === "" || phone.pairStage === "error"
                                        wrapMode: Text.WordWrap
                                        text: "Pairs this PC with Google Messages on your Pixel, through the Google account signed in to Firefox."
                                        color: Theme.textSecondary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                    }
                                    Text {
                                        width: parent.width
                                        visible: phone.pairStage === "error"
                                        wrapMode: Text.WordWrap
                                        text: phone.pairError
                                        color: Theme.red
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                    }
                                    // Not signed in to Google in Firefox: open the page to sign in.
                                    Text {
                                        width: parent.width
                                        visible: phone.pairNeedsSignIn
                                        wrapMode: Text.WordWrap
                                        text: "Sign in with the Google account your phone's Messages app uses, wait for the page to load, close the window, then Try again."
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                    }
                                    ActionButton {
                                        visible: phone.pairNeedsSignIn
                                        text: "SIGN IN TO GOOGLE IN FIREFOX"
                                        onClicked: ShellState.launch(["firefox", "--new-window", "https://messages.google.com/web"])
                                    }
                                    ActionButton {
                                        visible: phone.pairStage === "" || phone.pairStage === "error"
                                        text: phone.pairStage === "error" ? "TRY AGAIN" : "PAIR TEXTS"
                                        tint: Theme.accent
                                        filled: true
                                        enabledState: phone.daemonUp
                                        onClicked: phone.pairTexts()
                                    }
                                    Text {
                                        width: parent.width
                                        visible: phone.pairStage === "starting" || phone.pairStage === "account" || phone.pairStage === "done"
                                        wrapMode: Text.WordWrap
                                        text: phone.pairStage === "starting" ? "Checking your Google account…"
                                            : (phone.pairStage === "account" ? "Pairing as " + phone.pairAccount + "…" : "✓ Paired. Connecting…")
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontNormal
                                    }
                                    Column {
                                        width: parent.width
                                        visible: phone.pairStage === "emoji"
                                        spacing: Theme.spacingMedium

                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: phone.pairEmoji
                                            font.pixelSize: 72
                                        }
                                        Text {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            wrapMode: Text.WordWrap
                                            text: "On your Pixel, tap this emoji in Google Messages" + (phone.pairAccount ? "\n(" + phone.pairAccount + ")" : "")
                                            color: Theme.textPrimary
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontNormal
                                        }
                                    }
                                }

                                // Step 2: calls
                                StepCard {
                                    width: parent.width
                                    number: 2
                                    title: "Calls (Bluetooth)"
                                    done: phone.callsReady
                                    summary: "Calls via " + (phone.bluetooth.name || "your phone")

                                    Text {
                                        width: parent.width
                                        visible: !phone.btOn
                                        wrapMode: Text.WordWrap
                                        text: !phone.btAdapter ? "No Bluetooth adapter found." : "Bluetooth is off. Turn it on from the Bluetooth menu, then come back."
                                        color: Theme.yellow
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                    }

                                    // A phone that's already paired
                                    RowLayout {
                                        width: parent.width
                                        visible: phone.btOn && phone.btStage === "" && !!phone.pairedPhone
                                        spacing: Theme.spacingMedium

                                        Text {
                                            Layout.fillWidth: true
                                            text: "󰏲  " + phone.devName(phone.pairedPhone) + (phone.pairedPhone && phone.pairedPhone.connected ? "  · connected" : "  · paired")
                                            color: Theme.textPrimary
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontNormal
                                            elide: Text.ElideRight
                                        }
                                        ActionButton {
                                            text: phone.pairedPhone && phone.pairedPhone.connected ? "CHECK AGAIN" : "CONNECT"
                                            tint: Theme.accent
                                            filled: true
                                            onClicked: phone.connectDevice(phone.pairedPhone)
                                        }
                                    }

                                    // Nothing paired yet
                                    Text {
                                        width: parent.width
                                        visible: phone.btOn && phone.btStage === "" && !phone.pairedPhone
                                        wrapMode: Text.WordWrap
                                        text: "Pair your Pixel with this PC once; after that it connects by itself."
                                        color: Theme.textSecondary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                    }
                                    ActionButton {
                                        visible: phone.btOn && phone.btStage === "" && !phone.pairedPhone
                                        text: "START"
                                        tint: Theme.accent
                                        filled: true
                                        onClicked: phone.startScan()
                                    }

                                    // Searching
                                    Text {
                                        width: parent.width
                                        visible: phone.btStage === "scanning"
                                        wrapMode: Text.WordWrap
                                        text: "On your Pixel: Settings → Connected devices → Pair new device. Keep that screen open.\n\n"
                                            + (phone.discoveredDevices.length === 0 ? "Searching…" : "Pick your Pixel:")
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                    }
                                    Column {
                                        width: parent.width
                                        visible: phone.btStage === "scanning"
                                        spacing: Theme.spacingSmall

                                        Repeater {
                                            model: phone.btStage === "scanning" ? phone.discoveredDevices.slice(0, 8) : []
                                            delegate: Rectangle {
                                                id: devRow
                                                required property var modelData
                                                readonly property bool isPhone: phone.isPhoneDev(modelData)
                                                readonly property bool highlight: isPhone && phone.discoveredPhones === 1
                                                width: parent.width
                                                height: 38
                                                color: highlight ? Qt.tint(Theme.bgItem, Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.2)) : Theme.bgItem
                                                border.color: highlight ? Theme.accent : Theme.borderSubtle
                                                border.width: highlight ? Theme.borderWidth : 0
                                                radius: Theme.radius

                                                RowLayout {
                                                    anchors.fill: parent
                                                    anchors.leftMargin: 10
                                                    anchors.rightMargin: 6
                                                    spacing: Theme.spacingMedium

                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: (devRow.isPhone ? "󰏲  " : "󰂯  ") + phone.devName(devRow.modelData)
                                                        color: devRow.isPhone ? Theme.textPrimary : Theme.textSecondary
                                                        font.family: Theme.fontFamily
                                                        font.pixelSize: Theme.fontNormal
                                                        elide: Text.ElideRight
                                                    }
                                                    ActionButton {
                                                        implicitHeight: 26
                                                        text: "PAIR"
                                                        filled: devRow.highlight
                                                        onClicked: phone.pairDevice(devRow.modelData)
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Pairing / connecting / waiting
                                    Text {
                                        width: parent.width
                                        visible: ["pairing", "connecting", "waiting", "needsCalls", "failed"].indexOf(phone.btStage) >= 0
                                        wrapMode: Text.WordWrap
                                        text: {
                                            const name = phone.devName(phone.btTargetDev);
                                            const pc = phone.btAdapter ? (phone.btAdapter.name || "this PC") : "this PC";
                                            switch (phone.btStage) {
                                            case "pairing": return "Accept the pairing request on your Pixel (check the code matches).";
                                            case "connecting": return "Connecting to " + name + "…";
                                            case "waiting": return "Connected. Waiting for " + name + " to offer phone calls…";
                                            case "needsCalls": return "On your Pixel, open the Bluetooth settings for " + pc
                                                + " (gear icon) and turn on Phone calls.";
                                            default: return phone.btError;
                                            }
                                        }
                                        color: phone.btStage === "failed" ? Theme.red : Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                    }

                                    Row {
                                        spacing: Theme.spacingMedium
                                        visible: phone.btStage !== ""

                                        ActionButton {
                                            visible: phone.btStage === "needsCalls"
                                            text: "CHECK AGAIN"
                                            tint: Theme.accent
                                            filled: true
                                            onClicked: phone.waitForCalls()
                                        }
                                        ActionButton {
                                            visible: phone.btStage === "failed"
                                            text: "TRY AGAIN"
                                            tint: Theme.accent
                                            filled: true
                                            onClicked: {
                                                phone.btStage = "";
                                                phone.btTarget = "";
                                            }
                                        }
                                        ActionButton {
                                            visible: phone.btStage !== "failed"
                                            text: "CANCEL"
                                            onClicked: phone.cancelCalls()
                                        }
                                    }
                                }

                                // Step 3: done
                                StepCard {
                                    width: parent.width
                                    number: 3
                                    title: "Done"
                                    done: false
                                    visible: phone.textsOk && phone.callsReady

                                    Text {
                                        width: parent.width
                                        wrapMode: Text.WordWrap
                                        text: "Texts ✓ · Calls ✓ " + (phone.bluetooth.name || "")
                                        color: Theme.green
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontNormal
                                    }
                                    ActionButton {
                                        text: "DONE"
                                        tint: Theme.green
                                        filled: true
                                        onClicked: {
                                            phone.setupOpen = false;
                                            phone.tab = "messages";
                                            phone.restoreFocus();
                                        }
                                    }
                                }

                                SmallButton {
                                    text: "CLOSE  [Esc]"
                                    visible: phone.setupOpen
                                    onClicked: phone.closeSetup()
                                }
                            }
                        }

                        // ---- Voice draft: which person? ----
                        FocusScope {
                            id: chooserView
                            anchors.fill: parent
                            visible: phone.daemonUp && !!phone.voiceChooser && phone.tab === "messages" && !phone.showSetup

                            readonly property var people: phone.voiceChooser ? phone.voiceChooser.candidates : []
                            Keys.onUpPressed: phone.voiceChooserIndex = (phone.voiceChooserIndex - 1 + people.length) % Math.max(1, people.length)
                            Keys.onDownPressed: phone.voiceChooserIndex = (phone.voiceChooserIndex + 1) % Math.max(1, people.length)
                            Keys.onReturnPressed: if (people.length > 0) phone.chooserPick(people[phone.voiceChooserIndex])
                            Keys.onEnterPressed: if (people.length > 0) phone.chooserPick(people[phone.voiceChooserIndex])

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: Theme.spacingMedium

                                PanelTitle {
                                    Layout.fillWidth: true
                                    text: phone.voiceChooser ? (phone.voiceChooser.mode === "call" ? "Call which " : "Text which ") + phone.voiceChooser.name + "?" : ""
                                }

                                // The drafted message, quoted
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: quoteDraft.implicitHeight + Theme.paddingMedium * 2
                                    visible: !!phone.voiceChooser && phone.voiceChooser.message !== ""
                                    color: Theme.bgItem
                                    border.width: 0
                                    radius: Theme.radius

                                    Rectangle {
                                        width: 3
                                        height: parent.height
                                        color: Theme.accent
                                    }
                                    Text {
                                        id: quoteDraft
                                        x: 14
                                        y: Theme.paddingMedium
                                        width: parent.width - 24
                                        wrapMode: Text.WordWrap
                                        text: phone.voiceChooser ? "“" + phone.voiceChooser.message + "”" : ""
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontNormal
                                        font.italic: true
                                    }
                                }

                                ListView {
                                    id: chooserList
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    model: chooserView.people
                                    currentIndex: phone.voiceChooserIndex
                                    spacing: Theme.spacingSmall
                                    boundsBehavior: Flickable.StopAtBounds

                                    delegate: ListRow {
                                        id: personRow
                                        required property var modelData
                                        required property int index
                                        width: chooserList.width
                                        height: 52
                                        selected: index === phone.voiceChooserIndex
                                        onEntered: phone.voiceChooserIndex = index
                                        onClicked: phone.chooserPick(modelData)

                                        RowLayout {
                                            anchors.fill: parent
                                            spacing: Theme.spacingMedium

                                            Avatar {
                                                name: personRow.modelData.name
                                                tint: personRow.modelData.conv && personRow.modelData.conv.color ? personRow.modelData.conv.color : Theme.accent
                                            }
                                            Column {
                                                Layout.fillWidth: true
                                                spacing: 2
                                                RowLayout {
                                                    width: parent.width
                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: personRow.modelData.name + (personRow.modelData.fav ? "  ★" : "")
                                                        color: Theme.textPrimary
                                                        font.family: Theme.fontFamily
                                                        font.pixelSize: Theme.fontNormal
                                                        elide: Text.ElideRight
                                                    }
                                                    Text {
                                                        text: personRow.modelData.conv ? phone.relTime(personRow.modelData.ts) : "contact"
                                                        color: Theme.textSecondary
                                                        font.family: Theme.fontFamily
                                                        font.pixelSize: Theme.fontSmall
                                                    }
                                                }
                                                Text {
                                                    width: parent.width
                                                    text: personRow.modelData.number || ""
                                                    color: Theme.textSecondary
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSmall
                                                    elide: Text.ElideRight
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ---- Messages: conversation list ----
                        ColumnLayout {
                            anchors.fill: parent
                            spacing: Theme.spacingMedium
                            visible: phone.daemonUp && phone.tab === "messages" && !phone.currentConv && !phone.showSetup && !phone.voiceChooser

                            // Favorites: two rows of three. Drag a tile to reorder; drag a
                            // conversation's avatar here to pin it. Tiles are placed by slot (not
                            // a Grid) so they keep their identity, and the drag, while others move.
                            Item {
                                id: favArea
                                readonly property int slots: phone.favDisplayIds.length
                                readonly property int rows: Math.max(1, Math.ceil(slots / 3))
                                readonly property real tileW: Math.floor((width - Theme.spacingMedium * 2) / 3)
                                Layout.fillWidth: true
                                Layout.preferredHeight: rows * (84 + Theme.spacingMedium) - Theme.spacingMedium
                                visible: phone.favGridShown || !!phone.rowDrag && phone.selectionCount === 0 && !phone.showArchived
                                    && phone.query.trim() === ""
                                z: 5

                                function slotX(slot) { return (slot % 3) * (tileW + Theme.spacingMedium); }
                                function slotY(slot) { return Math.floor(slot / 3) * (84 + Theme.spacingMedium); }

                                // Where a conversation dragged from the list will land
                                Rectangle {
                                    readonly property int slot: phone.favDisplayIds.indexOf("__drop__")
                                    visible: slot >= 0
                                    x: favArea.slotX(Math.max(0, slot))
                                    y: favArea.slotY(Math.max(0, slot))
                                    width: favArea.tileW
                                    height: 84
                                    color: Qt.tint(Theme.bgItem, Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.15))
                                    border.color: Theme.accent
                                    border.width: Theme.borderWidth
                                    radius: Theme.radius

                                    Text {
                                        anchors.centerIn: parent
                                        text: "Drop to pin"
                                        color: Theme.textSecondary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                    }
                                }

                                // No favorites yet, or no room / already pinned
                                Rectangle {
                                    anchors.fill: parent
                                    visible: !!phone.rowDrag && (phone.favoriteConvs.length === 0 && !phone.rowDragOverFavs
                                        || phone.rowDragOverFavs && !phone.canPinRowDrag)
                                    color: "transparent"
                                    border.color: phone.rowDragOverFavs && !phone.canPinRowDrag ? Theme.borderCritical : Theme.border
                                    border.width: Theme.borderWidth
                                    radius: Theme.radius

                                    Text {
                                        anchors.centerIn: parent
                                        text: !phone.rowDragOverFavs ? "Drag here to pin to favorites"
                                            : (phone.rowDrag && phone.isFavorite(phone.rowDrag.id) ? "Already a favorite"
                                            : "Favorites are full (" + phone.maxFavorites + ")")
                                        color: phone.rowDragOverFavs ? Theme.red : Theme.textSecondary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                    }
                                }

                                Repeater {
                                    model: phone.favoriteConvs
                                    delegate: Rectangle {
                                        id: favTile
                                        required property var modelData
                                        readonly property bool dragging: phone.favDragId === modelData.id
                                        readonly property int slot: phone.favDisplayIds.indexOf(modelData.id)
                                        width: favArea.tileW
                                        height: 84
                                        x: dragging ? phone.favDragX : favArea.slotX(slot)
                                        y: dragging ? phone.favDragY : favArea.slotY(slot)
                                        z: dragging ? 10 : 0
                                        opacity: dragging ? 0.85 : 1
                                        color: favMouse.containsMouse || dragging ? Theme.bgSelected : Theme.bgItem
                                        border.color: dragging ? Theme.accent : Theme.borderSubtle
                                        border.width: dragging ? Theme.borderWidth : 0
                                        radius: Theme.radius

                                        Behavior on x { enabled: !favTile.dragging; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                                        Behavior on y { enabled: !favTile.dragging; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                                        Avatar {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            y: 9
                                            size: 44
                                            name: favTile.modelData.name
                                            tint: favTile.modelData.color || Theme.accent
                                        }
                                        Text {
                                            anchors.bottom: parent.bottom
                                            anchors.bottomMargin: 7
                                            x: 6
                                            width: parent.width - 12
                                            horizontalAlignment: Text.AlignHCenter
                                            text: favTile.modelData.name
                                            color: Theme.textPrimary
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSmall
                                            font.bold: !!favTile.modelData.unread
                                            elide: Text.ElideRight
                                        }
                                        Rectangle {
                                            visible: !!favTile.modelData.unread
                                            anchors.top: parent.top
                                            anchors.right: parent.right
                                            anchors.margins: 6
                                            width: 8
                                            height: 8
                                            color: Theme.accent
                                            radius: Theme.radius
                                        }
                                        MouseArea {
                                            id: favMouse
                                            // Press point (tile coords); a drag starts after 6px, so a
                                            // plain click still opens the conversation.
                                            property real pressX: 0
                                            property real pressY: 0
                                            property bool moved: false
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            preventStealing: true
                                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                                            onPressed: function(m) {
                                                pressX = m.x;
                                                pressY = m.y;
                                                moved = false;
                                            }
                                            onPositionChanged: function(m) {
                                                if (!(pressedButtons & Qt.LeftButton)) return;
                                                if (!moved) {
                                                    if (Math.abs(m.x - pressX) + Math.abs(m.y - pressY) < 6) return;
                                                    moved = true;
                                                    phone.startFavDrag(favTile.modelData.id, favTile.x, favTile.y);
                                                }
                                                if (!favTile.dragging) return;  // cancelled with Esc
                                                const p = mapToItem(favArea, m.x, m.y);
                                                phone.moveFavDrag(p.x - pressX, p.y - pressY);
                                            }
                                            onReleased: if (moved && favTile.dragging) phone.commitFavDrag()
                                            onClicked: function(m) {
                                                if (moved) return;
                                                if (m.button === Qt.RightButton) phone.openMenu(phone.favoriteMenu(favTile.modelData), favMouse, m.x, m.y);
                                                else phone.openConversation(favTile.modelData);
                                            }
                                        }
                                    }
                                }
                            }

                            // Inbox | Archived
                            RowLayout {
                                Layout.fillWidth: true
                                visible: phone.selectionCount === 0
                                spacing: Theme.spacingSmall * 2

                                SmallButton {
                                    text: "INBOX" + (phone.unreadCount > 0 ? "  " + phone.unreadCount : "")
                                    highlighted: !phone.showArchived
                                    onClicked: phone.setArchivedView(false)
                                }
                                SmallButton {
                                    text: "ARCHIVED (" + phone.archivedConversations.length + ")"
                                    highlighted: phone.showArchived
                                    onClicked: phone.setArchivedView(true)
                                }
                                Item { Layout.fillWidth: true }
                            }

                            ThemedField {
                                id: searchInput
                                Layout.fillWidth: true
                                visible: phone.selectionCount === 0
                                placeholderText: phone.showArchived ? "Search archived…" : "Search, or type a number to text…"
                                onTextChanged: {
                                    phone.query = text;
                                    phone.selectedIndex = 0;
                                    convList.positionViewAtBeginning();
                                }
                                Keys.onDownPressed: phone.move(1)
                                Keys.onUpPressed: phone.move(-1)
                                Keys.onPressed: function(event) { phone.listKey(event, true); }
                                onAccepted: phone.activateSelected()
                            }

                            // Bulk actions (replace the search row while selecting)
                            ColumnLayout {
                                Layout.fillWidth: true
                                visible: phone.selectionCount > 0
                                spacing: Theme.spacingMedium

                                RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        Layout.fillWidth: true
                                        text: phone.selectionCount + " selected"
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontMedium
                                        font.bold: true
                                    }
                                    SmallButton {
                                        text: "CLEAR"
                                        onClicked: phone.clearSelection()
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacingMedium

                                    ActionButton {
                                        text: "MARK READ"
                                        onClicked: phone.bulk("markRead")
                                    }
                                    ActionButton {
                                        text: phone.showArchived ? "UNARCHIVE" : "ARCHIVE"
                                        onClicked: phone.bulk(phone.showArchived ? "unarchive" : "archive")
                                    }
                                    ActionButton {
                                        text: "DELETE"
                                        tint: Theme.red
                                        filled: true
                                        onClicked: phone.confirmConvs("delete", phone.selectedIds())
                                    }
                                    ActionButton {
                                        text: "BLOCK"
                                        tint: Theme.red
                                        filled: true
                                        onClicked: phone.confirmConvs("block", phone.selectedIds())
                                    }
                                    ActionButton {
                                        id: moreBtn
                                        text: "⋯"
                                        onClicked: phone.openMenu([{
                                            label: "Report spam…", danger: true,
                                            run: () => phone.confirmConvs("reportSpam", phone.selectedIds())
                                        }], moreBtn, 0, moreBtn.height)
                                    }
                                    Item { Layout.fillWidth: true }
                                }
                            }

                            ListView {
                                id: convList
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                model: phone.listItems
                                currentIndex: phone.selectedIndex
                                spacing: Theme.spacingSmall
                                boundsBehavior: Flickable.StopAtBounds

                                delegate: ListRow {
                                    id: convRow
                                    required property var modelData
                                    required property int index
                                    readonly property var conv: modelData.kind === "conv" ? modelData.conv : null
                                    readonly property bool isHeader: modelData.kind === "header"
                                    readonly property var hit: modelData.kind === "msg" ? modelData.result : null
                                    readonly property bool picked: !!conv && phone.isSelected(conv.id)
                                    width: convList.width
                                    height: conv ? 52 : (hit ? 66 : (isHeader ? 26 : 40))
                                    selected: !isHeader && (index === phone.selectedIndex || picked)
                                    outlined: picked
                                    color: isHeader ? "transparent" : (selected || hovered ? Theme.bgSelected : Theme.bgItem)
                                    border.color: isHeader ? "transparent" : (selected || outlined ? Theme.border : Theme.borderSubtle)
                                    onEntered: if (!isHeader) phone.selectedIndex = index
                                    onClicked: function(m) {
                                        if (isHeader) return;
                                        if (m.button === Qt.RightButton) {
                                            phone.selectedIndex = index;
                                            if (convRow.conv) phone.openMenu(phone.conversationMenu(convRow.conv), convRow, m.x, m.y);
                                        } else {
                                            phone.rowClicked(index, convRow.conv, m);
                                        }
                                    }

                                    // Selected: an accent bar on the left edge.
                                    Rectangle {
                                        visible: convRow.picked
                                        x: -10
                                        width: 3
                                        height: parent.height
                                        color: Theme.accent
                                    }

                                    // Section header above message search results
                                    Caption {
                                        visible: convRow.isHeader
                                        anchors.left: parent.left
                                        anchors.leftMargin: -10
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 4
                                        text: "MESSAGES"
                                    }

                                    // A message matching the search
                                    RowLayout {
                                        visible: !!convRow.hit
                                        anchors.fill: parent
                                        spacing: Theme.spacingMedium

                                        Avatar {
                                            Layout.alignment: Qt.AlignTop
                                            Layout.topMargin: 8
                                            name: convRow.hit ? convRow.hit.name : ""
                                            tint: convRow.hit ? phone.convColor(convRow.hit.conv) : Theme.accent
                                        }
                                        Column {
                                            Layout.fillWidth: true
                                            Layout.alignment: Qt.AlignVCenter
                                            spacing: 2

                                            RowLayout {
                                                width: parent.width
                                                spacing: Theme.spacingMedium
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: convRow.hit ? convRow.hit.name : ""
                                                    color: Theme.textPrimary
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontNormal
                                                    elide: Text.ElideRight
                                                }
                                                Text {
                                                    text: convRow.hit ? phone.relTime(convRow.hit.message.ts) : ""
                                                    color: Theme.textSecondary
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSmall
                                                }
                                            }
                                            Text {
                                                width: parent.width
                                                textFormat: Text.StyledText
                                                text: convRow.hit ? (convRow.hit.message.fromMe ? "You: " : "")
                                                    + phone.highlight(convRow.hit.message.text, phone.query) : ""
                                                color: Theme.textSecondary
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSmall
                                                wrapMode: Text.Wrap
                                                maximumLineCount: 2
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }

                                    // "New message to <number>"
                                    Text {
                                        visible: convRow.modelData.kind === "new"
                                        anchors.fill: parent
                                        verticalAlignment: Text.AlignVCenter
                                        text: "󰍩  New message to " + (convRow.modelData.number || "")
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontNormal
                                        elide: Text.ElideRight
                                    }

                                    RowLayout {
                                        visible: !!convRow.conv
                                        anchors.fill: parent
                                        spacing: Theme.spacingMedium

                                        // Avatar; a checkbox on hover (or while selecting): click toggles selection.
                                        Item {
                                            implicitWidth: 34
                                            implicitHeight: 34

                                            Avatar {
                                                visible: !checkBox.visible
                                                name: convRow.conv ? convRow.conv.name : ""
                                                tint: convRow.conv && convRow.conv.color ? convRow.conv.color : Theme.accent
                                            }
                                            Rectangle {
                                                id: checkBox
                                                anchors.fill: parent
                                                visible: convRow.picked || phone.selectionCount > 0 || avatarMouse.containsMouse
                                                color: convRow.picked ? Qt.tint(Theme.bgItem, Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.35)) : Theme.bgItem
                                                border.color: convRow.picked ? Theme.accent : Theme.border
                                                border.width: Theme.borderWidth
                                                radius: Theme.radius

                                                Text {
                                                    anchors.centerIn: parent
                                                    text: convRow.picked ? "󰄲" : "󰄱"
                                                    color: convRow.picked ? Theme.accent : Theme.textSecondary
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontIcon + 2
                                                }
                                            }
                                            MouseArea {
                                                id: avatarMouse
                                                // Click toggles selection; dragging (after 6px) carries the
                                                // conversation to the favorites grid.
                                                property real pressX: 0
                                                property real pressY: 0
                                                property bool moved: false
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                preventStealing: true
                                                onPressed: function(m) {
                                                    pressX = m.x;
                                                    pressY = m.y;
                                                    moved = false;
                                                }
                                                onPositionChanged: function(m) {
                                                    if (!pressed || !convRow.conv) return;
                                                    if (!moved) {
                                                        if (Math.abs(m.x - pressX) + Math.abs(m.y - pressY) < 6 || phone.selectionCount > 0 || phone.showArchived) return;
                                                        moved = true;
                                                        phone.startRowDrag(convRow.conv);
                                                    }
                                                    if (!phone.rowDrag || phone.rowDrag.id !== convRow.conv.id) return;  // cancelled with Esc
                                                    const p = mapToItem(frame, m.x, m.y);
                                                    phone.moveRowDrag(p.x, p.y);
                                                }
                                                onReleased: if (moved && phone.rowDrag) phone.dropRow()
                                                onClicked: {
                                                    if (moved) return;
                                                    phone.selectedIndex = convRow.index;
                                                    phone.toggleSelect(convRow.conv.id, convRow.index);
                                                }
                                            }
                                        }

                                        Column {
                                            Layout.fillWidth: true
                                            spacing: 2

                                            RowLayout {
                                                width: parent.width
                                                spacing: Theme.spacingMedium

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: convRow.conv ? convRow.conv.name : ""
                                                    color: Theme.textPrimary
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontNormal
                                                    font.bold: !!(convRow.conv && convRow.conv.unread)
                                                    elide: Text.ElideRight
                                                }
                                                Text {
                                                    text: convRow.conv ? convRow.conv.type : ""
                                                    color: Theme.textMuted
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSmall - 1
                                                }
                                                Text {
                                                    text: convRow.conv ? phone.relTime(convRow.conv.ts) : ""
                                                    color: convRow.conv && convRow.conv.unread ? Theme.accent : Theme.textSecondary
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSmall
                                                }
                                            }

                                            RowLayout {
                                                width: parent.width
                                                spacing: Theme.spacingMedium

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: convRow.conv ? ((convRow.conv.fromMe ? "You: " : "") + (convRow.conv.snippet || "")).replace(/\s*\n\s*/g, " ") : ""
                                                    color: convRow.conv && convRow.conv.unread ? Theme.textPrimary : Theme.textSecondary
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSmall
                                                    elide: Text.ElideRight
                                                }
                                                Rectangle {
                                                    visible: !!(convRow.conv && convRow.conv.unread)
                                                    width: 8
                                                    height: 8
                                                    color: Theme.accent
                                                    radius: Theme.radius
                                                }
                                            }
                                        }
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    visible: phone.listItems.length === 0
                                    text: phone.textingReady ? (phone.query !== "" ? "No matches" : (phone.showArchived ? "No archived conversations" : "No conversations"))
                                        : (phone.texting === "unpaired" ? "Texts aren't set up yet" : "Waiting for the phone…")
                                    color: Theme.textMuted
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontNormal
                                }
                            }
                        }

                        // ---- Messages: thread ----
                        ColumnLayout {
                            anchors.fill: parent
                            spacing: Theme.spacingMedium
                            visible: phone.daemonUp && phone.tab === "messages" && !!phone.currentConv && !phone.showSetup && !phone.voiceChooser

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingMedium

                                ActionButton {
                                    text: "‹"
                                    onClicked: phone.closeConversation()
                                }
                                Avatar {
                                    name: phone.currentConv ? phone.currentConv.name : ""
                                    tint: phone.currentConv && phone.currentConv.color ? phone.currentConv.color : Theme.accent
                                }
                                Column {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    Text {
                                        width: parent.width
                                        text: phone.currentConv ? phone.currentConv.name : ""
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontMedium
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        width: parent.width
                                        text: phone.currentConv
                                            ? (phone.currentConv.group ? "Group" : (phone.currentConv.number || "")) + " · " + (phone.currentConv.type || "")
                                            : ""
                                        color: Theme.textSecondary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                        elide: Text.ElideRight
                                    }
                                }
                                ActionButton {
                                    text: "󰏲  CALL"
                                    enabledState: phone.callsReady && !!phone.currentConv && !phone.currentConv.group && !!phone.currentConv.number
                                    onClicked: phone.dial(phone.currentConv.number)
                                }
                            }

                            ListView {
                                id: threadList
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                verticalLayoutDirection: ListView.BottomToTop
                                model: phone.messages.slice().reverse()
                                spacing: Theme.spacingMedium
                                boundsBehavior: Flickable.StopAtBounds

                                delegate: Item {
                                    id: msgItem
                                    required property var modelData
                                    readonly property bool mine: !!modelData.fromMe
                                    readonly property real maxW: threadList.width * 0.78
                                    readonly property var media: modelData.media || []
                                    width: threadList.width
                                    height: msgCol.implicitHeight

                                    Column {
                                        id: msgCol
                                        anchors.right: msgItem.mine ? parent.right : undefined
                                        anchors.left: msgItem.mine ? undefined : parent.left
                                        width: Math.min(msgItem.maxW, Math.max(bubble.width, metaLine.implicitWidth,
                                            senderLine.visible ? senderLine.implicitWidth : 0, reactRow.visible ? reactRow.implicitWidth : 0))
                                        spacing: 2

                                        Text {
                                            id: senderLine
                                            visible: !msgItem.mine && !!(phone.currentConv && phone.currentConv.group) && !!msgItem.modelData.sender
                                            anchors.left: parent.left
                                            text: msgItem.modelData.sender || ""
                                            color: Theme.textSecondary
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSmall
                                        }

                                        Rectangle {
                                            id: bubble
                                            anchors.right: msgItem.mine ? parent.right : undefined
                                            anchors.left: msgItem.mine ? undefined : parent.left
                                            width: Math.min(msgItem.maxW, bubbleCol.implicitWidth + Theme.paddingMedium * 2)
                                            height: bubbleCol.implicitHeight + Theme.paddingMedium * 2
                                            color: msgItem.mine ? phone.tintedBubble : Theme.bgItem
                                            border.color: msgItem.modelData.status === "failed" ? Theme.borderCritical
                                                : (msgItem.mine ? Qt.tint(Theme.borderSubtle, Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)) : Theme.borderSubtle)
                                            border.width: 0
                                            radius: Theme.radius

                                            Column {
                                                id: bubbleCol
                                                x: Theme.paddingMedium
                                                y: Theme.paddingMedium
                                                spacing: Theme.spacingMedium

                                                // The message this one replies to
                                                Rectangle {
                                                    id: quote
                                                    readonly property var target: msgItem.modelData.replyTo ? phone.messageById(msgItem.modelData.replyTo) : null
                                                    visible: !!msgItem.modelData.replyTo
                                                    width: Math.min(quoteText.implicitWidth + 14, msgItem.maxW - Theme.paddingMedium * 2)
                                                    height: quoteText.implicitHeight + 8
                                                    color: Qt.rgba(0, 0, 0, Theme.isLight ? 0.06 : 0.18)
                                                    radius: Theme.radius

                                                    Rectangle {
                                                        width: 2
                                                        height: parent.height
                                                        color: Theme.accent
                                                    }
                                                    Text {
                                                        id: quoteText
                                                        x: 9
                                                        y: 4
                                                        width: Math.min(implicitWidth, msgItem.maxW - Theme.paddingMedium * 2 - 14)
                                                        text: quote.target ? phone.senderOf(quote.target) + ": " + phone.snippetOf(quote.target) : "Replying to an earlier message"
                                                        color: Theme.textSecondary
                                                        font.family: Theme.fontFamily
                                                        font.pixelSize: Theme.fontSmall
                                                        font.italic: !quote.target
                                                        elide: Text.ElideRight
                                                    }
                                                }

                                                Repeater {
                                                    model: msgItem.media
                                                    delegate: Item {
                                                        id: mediaItem
                                                        required property var modelData
                                                        readonly property bool isImage: (modelData.mime || "").indexOf("image/") === 0 && !!modelData.path
                                                        implicitWidth: isImage ? img.width : mediaLabel.implicitWidth
                                                        implicitHeight: isImage ? img.height : mediaLabel.implicitHeight

                                                        Image {
                                                            id: img
                                                            visible: mediaItem.isImage
                                                            source: mediaItem.isImage ? "file://" + mediaItem.modelData.path : ""
                                                            width: Math.min(260, msgItem.maxW - Theme.paddingMedium * 2, implicitWidth > 0 ? implicitWidth : 260)
                                                            height: implicitWidth > 0 ? implicitHeight * width / implicitWidth : 0
                                                            sourceSize.width: 520
                                                            fillMode: Image.PreserveAspectFit
                                                            asynchronous: true

                                                            MouseArea {
                                                                anchors.fill: parent
                                                                cursorShape: Qt.PointingHandCursor
                                                                onClicked: ShellState.launch(["xdg-open", mediaItem.modelData.path])
                                                            }
                                                        }

                                                        Text {
                                                            id: mediaLabel
                                                            visible: !mediaItem.isImage
                                                            text: "📎 " + (mediaItem.modelData.name || mediaItem.modelData.mime || "attachment")
                                                                + ((mediaItem.modelData.mime || "").indexOf("image/") === 0 ? " (loading…)" : "")
                                                            color: Theme.textSecondary
                                                            font.family: Theme.fontFamily
                                                            font.pixelSize: Theme.fontSmall
                                                        }
                                                    }
                                                }

                                                // Unwrapped width, to size the bubble to short messages.
                                                Text {
                                                    id: measure
                                                    visible: false
                                                    text: msgItem.modelData.text || ""
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontNormal
                                                }

                                                TextEdit {
                                                    visible: (msgItem.modelData.text || "") !== ""
                                                    width: Math.min(measure.implicitWidth + 1, msgItem.maxW - Theme.paddingMedium * 2)
                                                    text: msgItem.modelData.text || ""
                                                    readOnly: true
                                                    selectByMouse: true
                                                    wrapMode: TextEdit.Wrap
                                                    color: Theme.textPrimary
                                                    selectionColor: Theme.bgSelected
                                                    selectedTextColor: Theme.textPrimary
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontNormal
                                                }
                                            }

                                            MouseArea {
                                                id: bubbleMouse
                                                anchors.fill: parent
                                                acceptedButtons: Qt.RightButton
                                                onClicked: function(m) { phone.openMenu(phone.messageMenu(msgItem.modelData), bubbleMouse, m.x, m.y); }
                                            }
                                        }

                                        // Reactions: click one to add or remove yours
                                        Row {
                                            id: reactRow
                                            anchors.right: msgItem.mine ? parent.right : undefined
                                            anchors.left: msgItem.mine ? undefined : parent.left
                                            visible: (msgItem.modelData.reactions || []).length > 0
                                            spacing: 4

                                            Repeater {
                                                model: msgItem.modelData.reactions || []
                                                delegate: Rectangle {
                                                    id: chip
                                                    required property var modelData
                                                    width: chipText.implicitWidth + 12
                                                    height: 22
                                                    color: chip.modelData.mine ? Qt.tint(Theme.bgItem, Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.25))
                                                        : (chipMouse.containsMouse ? Theme.bgSelected : Theme.bgItem)
                                                    border.color: chip.modelData.mine ? Theme.accent : Theme.borderSubtle
                                                    border.width: chip.modelData.mine ? Theme.borderWidth : 0
                                                    radius: Theme.radius

                                                    Text {
                                                        id: chipText
                                                        anchors.centerIn: parent
                                                        text: chip.modelData.emoji + (chip.modelData.count > 1 ? " " + chip.modelData.count : "")
                                                        color: Theme.textPrimary
                                                        font.family: Theme.fontFamily
                                                        font.pixelSize: Theme.fontSmall
                                                    }
                                                    MouseArea {
                                                        id: chipMouse
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        enabled: phone.textingReady
                                                        onClicked: phone.react(msgItem.modelData, chip.modelData.emoji)
                                                    }
                                                }
                                            }
                                        }

                                        Text {
                                            id: metaLine
                                            anchors.right: msgItem.mine ? parent.right : undefined
                                            anchors.left: msgItem.mine ? undefined : parent.left
                                            text: {
                                                const s = msgItem.mine ? phone.statusText(msgItem.modelData.status) : "";
                                                return phone.stampTime(msgItem.modelData.ts) + (s !== "" ? " · " + s : "");
                                            }
                                            color: msgItem.modelData.status === "failed" ? Theme.red : Theme.textMuted
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSmall - 1
                                        }
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    visible: phone.messages.length === 0
                                    text: phone.loadingMessages ? "Loading…" : "No messages"
                                    color: Theme.textMuted
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontNormal
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: phone.typing
                                text: "typing…"
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                font.italic: true
                            }

                            // Voice draft
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 28
                                visible: phone.voiceDraftShown
                                color: Qt.tint(Theme.bgItem, Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.2))
                                border.width: 0
                                radius: Theme.radius

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: 10
                                    width: parent.width - 20
                                    text: "🎤 Voice draft — Enter to send · Esc to discard"
                                    color: Theme.textPrimary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSmall
                                    elide: Text.ElideRight
                                }
                            }

                            // Replying to…
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 30
                                visible: !!phone.replyTo
                                color: Theme.bgItem
                                border.color: Theme.borderSubtle
                                border.width: 0
                                radius: Theme.radius

                                Rectangle {
                                    width: 3
                                    height: parent.height
                                    color: Theme.accent
                                }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 12
                                    anchors.rightMargin: 8
                                    spacing: Theme.spacingMedium

                                    Text {
                                        Layout.fillWidth: true
                                        text: phone.replyTo ? "Replying to " + phone.senderOf(phone.replyTo) + ": " + phone.snippetOf(phone.replyTo) : ""
                                        color: Theme.textSecondary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        text: "✕"
                                        color: cancelReply.containsMouse ? Theme.textPrimary : Theme.textSecondary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontNormal

                                        MouseArea {
                                            id: cancelReply
                                            anchors.fill: parent
                                            anchors.margins: -6
                                            hoverEnabled: true
                                            onClicked: phone.replyTo = null
                                        }
                                    }
                                }
                            }

                            // Compose
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Math.min(composeArea.implicitHeight, 5 * 18 + 22)
                                color: Theme.bgItem
                                border.color: composeArea.activeFocus ? Theme.border : Theme.borderSubtle
                                border.width: 0
                                radius: Theme.radius

                                ScrollView {
                                    anchors.fill: parent
                                    clip: true

                                    TextArea {
                                        id: composeArea
                                        onTextChanged: if (text === "") phone.voiceDraftShown = false
                                        enabled: phone.textingReady && !!phone.currentConv && !phone.currentConv.readOnly
                                        wrapMode: TextArea.Wrap
                                        leftPadding: Theme.inputPadding
                                        rightPadding: Theme.inputPadding
                                        topPadding: 11
                                        bottomPadding: 11
                                        placeholderText: !phone.textingReady ? "Not connected to the phone"
                                            : (phone.currentConv && phone.currentConv.readOnly ? "You can't reply to this conversation"
                                            : "Message" + (phone.currentConv ? " · " + phone.currentConv.type : "") + "  (Enter sends, Shift+Enter new line)")
                                        placeholderTextColor: Theme.textPlaceholder
                                        color: Theme.textPrimary
                                        selectionColor: Theme.bgSelected
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontNormal
                                        background: null

                                        Keys.onReturnPressed: function(event) {
                                            if (event.modifiers & Qt.ShiftModifier) event.accepted = false;
                                            else phone.sendCurrent();
                                        }
                                        Keys.onEnterPressed: function(event) {
                                            if (event.modifiers & Qt.ShiftModifier) event.accepted = false;
                                            else phone.sendCurrent();
                                        }
                                    }
                                }
                            }
                        }

                        // ---- Calls ----
                        ColumnLayout {
                            anchors.fill: parent
                            spacing: Theme.spacingMedium
                            visible: phone.daemonUp && phone.tab === "calls" && !phone.showSetup

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingMedium

                                ThemedField {
                                    id: dialField
                                    Layout.fillWidth: true
                                    placeholderText: "Name or number…"
                                    onTextChanged: {
                                        phone.dialQuery = text;
                                        phone.dialIndex = 0;
                                    }
                                    Keys.onDownPressed: if (phone.dialMatches.length > 0) phone.dialIndex = (phone.dialIndex + 1) % phone.dialMatches.length
                                    Keys.onUpPressed: if (phone.dialMatches.length > 0) phone.dialIndex = (phone.dialIndex - 1 + phone.dialMatches.length) % phone.dialMatches.length
                                    onAccepted: if (phone.callsReady) phone.dialSelected()
                                }
                                ActionButton {
                                    Layout.preferredHeight: dialField.height
                                    text: "󰏲  CALL"
                                    tint: Theme.green
                                    filled: phone.callsReady
                                    enabledState: phone.callsReady && (dialField.text.trim() !== "" || phone.dialMatches.length > 0)
                                    onClicked: phone.dialSelected()
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: callsBanner.implicitHeight + Theme.paddingMedium * 2
                                visible: !phone.callsReady
                                color: Theme.bgItem
                                border.color: Theme.yellow
                                border.width: Theme.borderWidth
                                radius: Theme.radius

                                RowLayout {
                                    id: callsBanner
                                    anchors.fill: parent
                                    anchors.margins: Theme.paddingMedium
                                    spacing: Theme.spacingMedium

                                    Text {
                                        Layout.fillWidth: true
                                        wrapMode: Text.WordWrap
                                        text: "Calls need your Pixel connected to this PC over Bluetooth."
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                    }
                                    ActionButton {
                                        text: "SET UP CALLS"
                                        tint: Theme.accent
                                        filled: true
                                        onClicked: phone.openSetup()
                                    }
                                }
                            }

                            ListView {
                                id: contactList
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                model: phone.dialMatches
                                currentIndex: phone.dialIndex
                                spacing: Theme.spacingSmall
                                boundsBehavior: Flickable.StopAtBounds
                                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                                delegate: ListRow {
                                    required property var modelData
                                    required property int index
                                    width: contactList.width
                                    height: 40
                                    selected: index === phone.dialIndex
                                    onEntered: phone.dialIndex = index
                                    onClicked: {
                                        phone.dialIndex = index;
                                        if (phone.callsReady) phone.dial(modelData.number);
                                    }

                                    RowLayout {
                                        anchors.fill: parent
                                        spacing: Theme.spacingMedium
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.name || modelData.number
                                            color: Theme.textPrimary
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontNormal
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            text: modelData.number || ""
                                            color: Theme.textSecondary
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSmall
                                        }
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    visible: phone.dialMatches.length === 0
                                    text: phone.dialQuery.trim() === "" ? "Type a name or number" : (phone.contactsLoaded ? "No matching contacts" : "")
                                    color: Theme.textMuted
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontNormal
                                }
                            }

                            Keypad {
                                Layout.fillWidth: true
                                onPressed: function(key) {
                                    dialField.text += key;
                                    dialField.forceActiveFocus();
                                }
                            }
                        }
                    }

                    // Confirm a destructive action
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: confirmRow.implicitHeight + Theme.paddingMedium * 2
                        visible: !!phone.pendingConfirm
                        color: Theme.bgCritical
                        border.color: Theme.borderCritical
                        border.width: Theme.borderWidth
                        radius: Theme.radius

                        RowLayout {
                            id: confirmRow
                            anchors.fill: parent
                            anchors.margins: Theme.paddingMedium
                            spacing: Theme.spacingMedium

                            Text {
                                Layout.fillWidth: true
                                text: phone.pendingConfirm ? phone.pendingConfirm.text : ""
                                wrapMode: Text.WordWrap
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                            }
                            ActionButton {
                                text: phone.pendingConfirm ? phone.pendingConfirm.label : ""
                                tint: Theme.red
                                filled: true
                                onClicked: phone.runConfirm()
                            }
                            ActionButton {
                                text: "CANCEL"
                                onClicked: phone.pendingConfirm = null
                            }
                        }
                    }

                    Hint {
                        Layout.fillWidth: true
                        color: phone.lastError !== "" ? (phone.noticeIsError ? Theme.red : Theme.green) : Theme.textSecondary
                        text: phone.lastError !== "" ? phone.lastError
                            : phone.showSetup ? (phone.setupOpen ? "Esc close setup" : "Set up texts to see your conversations")
                            : phone.voiceChooser ? (phone.voiceChooser.mode === "call" ? "Enter call • ↑↓ move • Esc cancel" : "Enter pick • ↑↓ move • Esc cancel")
                            : (phone.currentConv && phone.voiceDraftShown) ? "Enter send • Esc discard draft"
                            : (phone.tab === "calls" ? "Enter call • ↑↓ contacts • Ctrl+1 messages • Esc close"
                            : (phone.currentConv ? "Enter send • Shift+Enter line • right-click msg • Esc back"
                            : (phone.selectionCount > 0 ? "Space toggle • Shift+click range • Ctrl+A all • Esc clear"
                            : "Enter open • Ctrl+click select • right-click menu • Esc close")))
                    }
                }
            }

            // ---- A conversation being dragged to favorites ----
            Rectangle {
                visible: !!phone.rowDrag
                x: phone.rowDragX + 10
                y: phone.rowDragY + 10
                z: 20
                width: ghostRow.implicitWidth + 16
                height: 42
                opacity: 0.9
                color: Theme.bgSelected
                border.color: phone.rowDragOverFavs && !phone.canPinRowDrag ? Theme.borderCritical : Theme.accent
                border.width: Theme.borderWidth
                radius: Theme.radius

                Row {
                    id: ghostRow
                    anchors.centerIn: parent
                    spacing: Theme.spacingMedium
                    Avatar {
                        size: 28
                        name: phone.rowDrag ? phone.rowDrag.name : ""
                        tint: phone.rowDrag && phone.rowDrag.color ? phone.rowDrag.color : Theme.accent
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, 200)
                        text: phone.rowDrag ? phone.rowDrag.name : ""
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontNormal
                        elide: Text.ElideRight
                    }
                }
            }

            // ---- Context menu (inside the panel, at the cursor) ----
            Item {
                id: menuLayer
                anchors.fill: parent
                visible: phone.menuItems.length > 0
                z: 10

                // Click outside closes it.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: phone.closeMenu()
                }

                Rectangle {
                    id: menuBox
                    width: 236
                    height: menuCol.implicitHeight + 8
                    x: Math.max(4, Math.min(phone.menuX, menuLayer.width - width - 4))
                    y: Math.max(4, Math.min(phone.menuY, menuLayer.height - height - 4))
                    color: Theme.bgPanel
                    border.color: Theme.border
                    border.width: Theme.borderWidth
                    radius: Theme.radius

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                    }

                    FocusScope {
                        id: menuFocus
                        anchors.fill: parent

                        Keys.onEscapePressed: function(event) {
                            phone.closeMenu();
                            event.accepted = true;
                        }
                        Keys.onUpPressed: phone.menuMove(-1)
                        Keys.onDownPressed: phone.menuMove(1)
                        Keys.onReturnPressed: phone.menuActivate(phone.menuIndex)
                        Keys.onEnterPressed: phone.menuActivate(phone.menuIndex)

                        Column {
                            id: menuCol
                            x: 4
                            y: 4
                            width: parent.width - 8

                            Repeater {
                                model: phone.menuItems
                                delegate: Item {
                                    id: menuEntry
                                    required property var modelData
                                    required property int index
                                    readonly property bool isSeparator: !!modelData.separator
                                    readonly property bool isReactions: !!modelData.reactions
                                    readonly property bool usable: modelData.enabled !== false
                                    width: menuCol.width
                                    height: isSeparator ? 9 : (isReactions ? 36 : 28)

                                    Rectangle {
                                        visible: menuEntry.isSeparator
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width
                                        height: 1
                                        color: Theme.borderSubtle
                                    }

                                    // The seven Google Messages reactions; yours are outlined.
                                    Row {
                                        visible: menuEntry.isReactions
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2

                                        Repeater {
                                            model: menuEntry.isReactions ? phone.reactionEmojis : []
                                            delegate: Rectangle {
                                                id: emojiCell
                                                required property string modelData
                                                readonly property bool mine: phone.hasMyReaction(menuEntry.modelData.msg, modelData)
                                                width: 30
                                                height: 30
                                                color: mine ? Qt.tint(Theme.bgItem, Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.3))
                                                    : (emojiMouse.containsMouse ? Theme.bgSelected : "transparent")
                                                border.color: mine ? Theme.accent : "transparent"
                                                border.width: Theme.borderWidth
                                                radius: Theme.radius

                                                Text {
                                                    anchors.centerIn: parent
                                                    text: emojiCell.modelData
                                                    font.pixelSize: Theme.fontLarge + 2
                                                }
                                                MouseArea {
                                                    id: emojiMouse
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    onClicked: {
                                                        const msg = menuEntry.modelData.msg;
                                                        phone.closeMenu();
                                                        phone.react(msg, emojiCell.modelData);
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    Rectangle {
                                        visible: !menuEntry.isSeparator && !menuEntry.isReactions
                                        anchors.fill: parent
                                        color: phone.menuIndex === menuEntry.index && menuEntry.usable ? Theme.bgSelected : "transparent"
                                        radius: Theme.radius

                                        Text {
                                            x: 10
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - 20
                                            text: menuEntry.modelData.label || ""
                                            color: !menuEntry.usable ? Theme.textMuted : (menuEntry.modelData.danger ? Theme.red : Theme.textPrimary)
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontNormal
                                            elide: Text.ElideRight
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onEntered: if (menuEntry.usable) phone.menuIndex = menuEntry.index
                                            onClicked: phone.menuActivate(menuEntry.index)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- Call card: top right, for the whole call (Continuity style) ----
    // Never takes keyboard focus and can't be dismissed; clicking it (not its
    // buttons) opens the panel.
    PanelWindow {
        id: callWindow
        screen: ShellState.focusedScreen
        visible: phone.cardCalls.length > 0 || phone.voiceCard
        color: "transparent"
        anchors { top: true; right: true }
        margins {
            top: Desktop.edgeGap + (Desktop.barOnTop ? Desktop.barHeight : 0)
            right: Desktop.edgeGap
        }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "quickshell-phone-call"
        // Room for the shadow below and to the left; only the card takes input.
        implicitWidth: 380 + Theme.shadowMargin
        implicitHeight: cardBox.height + Theme.shadowMargin
        mask: Region { item: cardBox }

        Shadow { target: cardBox }

        Rectangle {
            id: cardBox
            x: Theme.shadowMargin
            readonly property var call: phone.primaryCall
            readonly property bool ringing: !!call && (call.state === "incoming" || call.state === "waiting")
            readonly property bool multi: phone.cardCalls.length > 1
            readonly property bool failed: !!phone.pendingDial && phone.pendingDial.error !== "" && phone.liveCalls.length === 0
                || phone.voiceCard && phone.voiceCallError !== ""
            width: parent.width - Theme.shadowMargin
            height: cardCol.implicitHeight + Theme.paddingLarge * 2
            color: ringing ? Qt.tint(Theme.bgPanel, Qt.rgba(Theme.green.r, Theme.green.g, Theme.green.b, 0.12)) : Theme.bgPanel
            border.color: failed ? Theme.borderCritical : (ringing ? Theme.green : Theme.border)
            border.width: Theme.borderWidth
            radius: Theme.radius

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: ShellState.openPopup("phone")
            }

            Column {
                id: cardCol
                x: Theme.paddingLarge
                y: Theme.paddingLarge
                width: parent.width - Theme.paddingLarge * 2
                spacing: Theme.spacingLarge

                // Voice call: countdown, "not connected", or nobody by that name
                RowLayout {
                    width: cardCol.width
                    visible: phone.voiceCard && !!phone.voiceCallTarget
                    spacing: Theme.spacingLarge

                    Avatar {
                        size: 44
                        name: phone.voiceCallTarget ? phone.voiceCallTarget.name : ""
                        tint: phone.voiceCallTarget ? phone.voiceCallTarget.color : Theme.accent
                    }
                    Column {
                        Layout.fillWidth: true
                        spacing: 2
                        Text {
                            width: parent.width
                            text: !phone.voiceCallTarget ? ""
                                : phone.voiceCallError === "notconnected" ? phone.voiceCallTarget.name
                                : "Calling " + phone.voiceCallTarget.name + " in " + phone.voiceCallCount + "…"
                            color: Theme.textPrimary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontLarge
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            text: phone.voiceCallTarget ? phone.voiceCallTarget.number : ""
                            color: Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSmall
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            visible: phone.voiceCallError === "notconnected"
                            text: "Calls aren't connected."
                            color: Theme.red
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSmall
                        }
                    }
                }

                Text {
                    width: parent.width
                    visible: phone.voiceCard && !phone.voiceCallTarget && phone.voiceCallError !== ""
                    wrapMode: Text.WordWrap
                    text: phone.voiceCallError
                    color: Theme.red
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontNormal
                }

                Row {
                    visible: phone.voiceCard && !!phone.voiceCallTarget
                    spacing: Theme.spacingMedium

                    ActionButton {
                        visible: phone.voiceCallError === ""
                        text: "󰏲  CALL NOW"
                        tooltip: "Call without waiting"
                        tooltipBelow: true
                        tint: Theme.accent
                        filled: true
                        onClicked: phone.voiceCallNow()
                    }
                    ActionButton {
                        visible: phone.voiceCallError === "notconnected"
                        text: "SET UP CALLS"
                        tooltip: "Connect your phone for calls"
                        tooltipBelow: true
                        tint: Theme.accent
                        filled: true
                        onClicked: {
                            phone.cancelVoiceCall();
                            phone.openSetup();
                        }
                    }
                    ActionButton {
                        text: "CANCEL"
                        tooltip: "Don't call"
                        tooltipBelow: true
                        onClicked: phone.cancelVoiceCall()
                    }
                }

                Repeater {
                    model: phone.cardCalls
                    delegate: RowLayout {
                        id: cardRow
                        required property var modelData
                        readonly property bool compact: cardBox.multi
                        readonly property string label: phone.callName(modelData)
                        readonly property bool named: /[A-Za-z]/.test(label)
                        width: cardCol.width
                        spacing: Theme.spacingLarge

                        Item {
                            implicitWidth: cardRow.compact ? 32 : 44
                            implicitHeight: implicitWidth

                            Avatar {
                                size: parent.implicitWidth
                                // No name: a person glyph instead of "#".
                                name: cardRow.label
                                showInitials: cardRow.named
                                tint: cardRow.modelData.state === "incoming" || cardRow.modelData.state === "waiting"
                                    ? Theme.green : phone.colorForNumber(cardRow.modelData.number)
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: !cardRow.named
                                text: "󰀄"
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: cardRow.compact ? Theme.fontLarge : Theme.fontLarge + 6
                            }
                        }

                        Column {
                            Layout.fillWidth: true
                            spacing: 2

                            Text {
                                width: parent.width
                                text: cardRow.modelData.state === "pending" && !cardBox.failed ? "Calling " + cardRow.label + "…" : cardRow.label
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: cardRow.compact ? Theme.fontNormal : Theme.fontLarge
                                font.bold: true
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                visible: !cardRow.compact
                                text: "using " + (phone.bluetooth.name || "your phone")
                                color: Theme.textMuted
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                text: cardBox.failed ? "Call not placed" : phone.callStateText(cardRow.modelData)
                                color: cardBox.failed ? Theme.red : (cardRow.modelData.state === "active" ? Theme.green : Theme.textSecondary)
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                elide: Text.ElideRight
                            }
                        }

                        // With two calls, each gets its own End.
                        ActionButton {
                            visible: cardRow.compact
                            text: "END"
                            tooltip: "End this call"
                            tooltipBelow: true
                            tint: Theme.red
                            filled: true
                            onClicked: phone.hangup(cardRow.modelData)
                        }
                    }
                }

                Text {
                    width: parent.width
                    visible: cardBox.failed
                    wrapMode: Text.WordWrap
                    text: phone.pendingDial ? phone.pendingDial.error : ""
                    color: Theme.red
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                }

                // Ringing: Answer / Decline
                Row {
                    visible: cardBox.ringing
                    spacing: Theme.spacingMedium

                    ActionButton {
                        text: cardBox.call && cardBox.call.state === "waiting" && phone.inCall ? "HOLD + ANSWER" : "ANSWER"
                        tooltip: "Answer on this PC"
                        tooltipBelow: true
                        tint: Theme.green
                        filled: true
                        onClicked: {
                            if (cardBox.call.state === "waiting" && phone.inCall) phone.request("holdAndAnswer", {});
                            else phone.answer(cardBox.call);
                        }
                    }
                    ActionButton {
                        text: "DECLINE"
                        tooltip: "Decline the call"
                        tooltipBelow: true
                        tint: Theme.red
                        filled: true
                        onClicked: phone.hangup(cardBox.call)
                    }
                }

                // In a call (or calling): Mute, Keypad, Swap, End
                Row {
                    visible: !cardBox.ringing && !cardBox.failed && phone.cardCalls.length > 0
                    spacing: Theme.spacingMedium

                    ActionButton {
                        text: phone.muted ? "󰍭  UNMUTE" : "󰍬  MUTE"
                        tooltip: phone.muted ? "Unmute your microphone" : "Mute your microphone"
                        tooltipBelow: true
                        tint: Theme.red
                        filled: phone.muted
                        onClicked: phone.toggleMute()
                    }
                    ActionButton {
                        visible: phone.liveCalls.length > 0
                        text: "󰌌  KEYPAD"
                        tooltip: "Send tones"
                        tooltipBelow: true
                        filled: phone.callKeypad
                        onClicked: phone.callKeypad = !phone.callKeypad
                    }
                    ActionButton {
                        visible: phone.liveCalls.length >= 2
                        text: "󰓡  SWAP"
                        tooltip: "Swap the active and held call"
                        tooltipBelow: true
                        onClicked: phone.request("swap", {})
                    }
                    ActionButton {
                        visible: !cardBox.multi
                        text: "END"
                        tooltip: "End the call"
                        tooltipBelow: true
                        tint: Theme.red
                        filled: true
                        onClicked: phone.hangup(cardBox.call)
                    }
                }

                Keypad {
                    width: parent.width
                    visible: phone.callKeypad && phone.liveCalls.length > 0 && !cardBox.ringing
                    onPressed: function(key) {
                        phone.request("tones", { tones: key });
                        phone.toneDigits = (phone.toneDigits + key).slice(-16);
                    }
                }
            }
        }
    }
}
