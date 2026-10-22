# omadora-phone daemon protocol

`omadora-phone daemon` listens on `$XDG_RUNTIME_DIR/omadora-phone.sock` (mode 0600).
Newline-delimited JSON, one object per line, both directions. Several clients may connect;
every client receives every event.

## Requests (client → daemon)

Every request has a `cmd`; `id` (any number) is optional and echoed in the reply.

| cmd | fields | reply data |
|---|---|---|
| `hello` | – | none; the daemon then sends `state`, `conversations` and `calls` events to this client |
| `messages` | `conv` | `{"conv", "messages": [Message…]}` (oldest first, last ~40). Answered from the local cache when it has the thread; the daemon then syncs with the phone and sends changes as `message` / `messageDeleted` events |
| `search` | `text` | `{"results": [{"conv", "name", "message": Message}]}`: cached messages containing every word, newest first, max 50 |
| `send` | `conv`, `text`, `replyTo` (message id, optional) | `{"conv"}` — the message itself arrives as a `message` event |
| `markRead` | `conv` or `convs` | – |
| `archive` / `unarchive` | `conv` or `convs` | – (error names how many failed) |
| `delete` | `conv` or `convs` | – deletes the conversations on the phone |
| `block` / `reportSpam` | `conv` or `convs` | – blocks the sender (and reports spam); the conversation goes away |
| `deleteMessage` | `conv`, `message` (id) | – a `messageDeleted` event follows |
| `react` | `conv`, `message`, `emoji`, `remove` (bool) | – the updated message arrives as a `message` event |
| `newConversation` | `number` (any format) | `{"conv"}` — an existing or new conversation with that number |
| `contacts` | – | `{"contacts": [{"name", "number"}]}` |
| `focus` | `conv` (or `""`) | – the conversation open on screen: no notifications for it |
| `pairMessages` | – | – pairs texting through the Google account in the remembered Firefox profile (`omadora-phone pair` remembers it); progress arrives as `pairing` events. Only while `texting` is `unpaired` or `error` |
| `dial` | `number` | – |
| `answer` | `call` (path) | – |
| `hangup` | `call` (path) | – |
| `hangupAll` | – | – |
| `tones` | `tones` (`0-9*#`) | – |
| `swap` | – | – (swap active and held call) |
| `holdAndAnswer` | – | – (answer a waiting call, hold the current one) |

Replies: `{"id": n, "ok": true, "data": {...}}` or `{"id": n, "ok": false, "error": "text"}`.

## Cache

The daemon keeps conversations, the last ~1000 messages of each thread it has seen, and
contacts in `~/.local/state/omadora/phone/cache.db` (mode 0600), and pictures in
`~/.cache/omadora/phone/media` (capped at 500 MB). On connect it brings the 30 most recent
threads up to date in the background, so they open instantly and `search` covers them. The phone
is the source of truth: what it sends overwrites the cache, and conversations or messages it no
longer has are dropped.

## Events (daemon → client)

`{"event": "<name>", ...fields}`

- `state`:
  - `texting`: `"connected" | "connecting" | "phone-offline" | "inactive" | "unpaired" | "error"`
    (`inactive`: Messages for web was opened in another browser; the daemon takes the session
    back on the next request)
  - `textingError`: string (when `error` or `unpaired`)
  - `bluetooth`: `{ "connected": bool, "name": string, "address": string, "audio": string }` — the
    phone as a hands-free audio gateway (calls possible only when connected); `audio` is the call
    audio link: `"active"` while call audio flows to the PC, else `"idle"` (or other transport states)
- `conversations`: `{"conversations": [Conversation…]}` — full list, newest first, sent on any change
- `message`: `{"conv", "message": Message}` — new or updated (status change, media downloaded)
- `calls`: `{"calls": [Call…]}` — full list, sent on any change
- `typing`: `{"conv", "typing": bool}`
- `messageDeleted`: `{"conv", "id"}`
- `pairing`: `{"stage": "starting" | "account" | "emoji" | "done" | "error", "account", "profile", "emoji", "error"}`
  — `account` names the Google account about to be paired; `emoji` is the one to tap on the phone
  (~1 minute); after `done` the daemon connects by itself (`state.texting` goes to `connected`)

## Objects

Conversation:
```json
{"id": "98", "name": "Joseph Spoerl", "type": "RCS" | "SMS", "group": false,
 "unread": true, "ts": 1792100000000, "snippet": "Tks Ted", "fromMe": false,
 "color": "#7aa2f7", "number": "+12695550100", "readOnly": false,
 "archived": false, "pinned": false}
```
`archived` conversations are in the list too; `pinned` is Google Messages' own pin (there's
no way to change it from here).
`ts` is epoch milliseconds. `number` is the other participant's number (empty for groups).

Message:
```json
{"id": "1234", "ts": 1792100000000, "fromMe": true, "sender": "Joseph Spoerl",
 "text": "On my way", "status": "sending" | "sent" | "delivered" | "read" | "failed" | "received",
 "media": [{"mime": "image/jpeg", "name": "", "path": "/run/user/1000/omadora-phone/media/abc.jpg"}],
 "reactions": [{"emoji": "👍", "count": 2, "mine": true}], "replyTo": "1230"}
```
`replyTo` is the id of the message this one answers (empty if none). Mark-unread doesn't exist
in Google Messages' web protocol.
`media[].path` is empty until downloaded; an updated `message` event follows with the path.
Only images are downloaded; other media shows as a placeholder.

Call:
```json
{"path": "/org/pipewire/Telephony/ag0/call0", "number": "+12695550100", "name": "Joseph Spoerl",
 "state": "active" | "held" | "dialing" | "alerting" | "incoming" | "waiting" | "disconnected",
 "since": 1792100000000, "incoming": true}
```
`name` comes from the phone, else from Google Messages contacts, else empty. `since` is when
the call entered its current state.
