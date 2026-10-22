package main

// Texting: SMS and RCS through Google Messages' web protocol (libgm). Keeps
// one connection to the phone, a cache of conversations, and turns libgm
// events into protocol events.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"go.mau.fi/util/exhttp"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

const maxMediaBytes = 25 * 1024 * 1024

type Conversation struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Type     string `json:"type"`
	Group    bool   `json:"group"`
	Unread   bool   `json:"unread"`
	TS       int64  `json:"ts"`
	Snippet  string `json:"snippet"`
	FromMe   bool   `json:"fromMe"`
	Color    string `json:"color"`
	Number   string `json:"number"`
	ReadOnly bool   `json:"readOnly"`
	Archived bool   `json:"archived"`
	Pinned   bool   `json:"pinned"`
}

type Media struct {
	Mime string `json:"mime"`
	Name string `json:"name"`
	Path string `json:"path"`
}

type Message struct {
	ID        string     `json:"id"`
	TS        int64      `json:"ts"`
	FromMe    bool       `json:"fromMe"`
	Sender    string     `json:"sender"`
	Text      string     `json:"text"`
	Status    string     `json:"status"`
	Media     []Media    `json:"media"`
	Reactions []Reaction `json:"reactions"`
	ReplyTo   string     `json:"replyTo"`
}

type Reaction struct {
	Emoji string `json:"emoji"`
	Count int    `json:"count"`
	Mine  bool   `json:"mine"`
}

type Contact struct {
	Name   string `json:"name"`
	Number string `json:"number"`
}

type texting struct {
	hub     *hub
	onState func()

	mu          sync.Mutex
	cli         *libgm.Client
	state       string // connected | connecting | phone-offline | unpaired | error
	errText     string
	convs       map[string]*gmproto.Conversation
	focus       string
	notified    map[string]bool // message IDs already notified (status updates resend messages)
	contactList []Contact
	notifier    *notifier
	cache       *store
	contactsNew bool // contacts refreshed from the phone this session
	prefetching bool
	pairing     bool

	events chan any
}

func newTexting(h *hub) *texting {
	t := &texting{
		hub:      h,
		onState:  func() {},
		state:    "connecting",
		convs:    map[string]*gmproto.Conversation{},
		notified: map[string]bool{},
		events:   make(chan any, 512),
	}
	// A reply from a notification counts as reading the conversation, as on the phone.
	t.notifier = newNotifier(func(conv, text string) error {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := t.send(ctx, conv, text, ""); err != nil {
			return err
		}
		_ = t.markRead(ctx, conv)
		return nil
	})
	return t
}

// loadCache fills the conversations and contacts from the local cache, so
// the panel has something to show before the phone answers.
func (t *texting) loadCache() {
	cache, err := openStore()
	if err != nil {
		fmt.Fprintln(os.Stderr, "cache disabled:", err)
		return
	}
	t.cache = cache
	t.mu.Lock()
	for _, c := range cache.conversations() {
		t.convs[c.GetConversationID()] = c
	}
	var contacts []Contact
	if cache.getJSON("contacts", &contacts) {
		t.contactList = contacts
	}
	t.mu.Unlock()
	go pruneMedia()
}

func (t *texting) status() (string, string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.state, t.errText
}

func (t *texting) setState(state, errText string) {
	t.mu.Lock()
	changed := t.state != state || t.errText != errText
	t.state, t.errText = state, errText
	t.mu.Unlock()
	if changed {
		t.onState()
	}
}

func (t *texting) client() (*libgm.Client, error) {
	t.mu.Lock()
	cli, state := t.cli, t.state
	t.mu.Unlock()
	if cli == nil || state == "unpaired" {
		return nil, errors.New("not connected to the phone")
	}
	if state == "inactive" {
		// Take the session back from the other browser.
		if err := cli.SetActiveSession(context.Background()); err != nil {
			return nil, fmt.Errorf("Messages is open in another browser: %w", err)
		}
	}
	return cli, nil
}

// reclaim makes this the active Messages for web session again, if another
// browser took it over (called when the panel connects).
func (t *texting) reclaim() {
	t.mu.Lock()
	inactive := t.state == "inactive"
	t.mu.Unlock()
	if inactive {
		_, _ = t.client()
	}
}

// startPairing pairs texting from the panel (Google account, remembered
// Firefox profile), reporting progress as `pairing` events.
func (t *texting) startPairing() error {
	t.mu.Lock()
	if t.state != "unpaired" && t.state != "error" {
		t.mu.Unlock()
		return errors.New("texts are already paired")
	}
	if t.pairing {
		t.mu.Unlock()
		return errors.New("pairing is already in progress")
	}
	t.pairing = true
	t.mu.Unlock()
	go func() {
		defer func() {
			t.mu.Lock()
			t.pairing = false
			t.mu.Unlock()
		}()
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()
		event := func(fields map[string]any) { t.hub.event(nil, "pairing", fields) }
		event(map[string]any{"stage": "starting"})
		err := gaiaPair(ctx, loadSetup(), func(email, profile string) {
			event(map[string]any{"stage": "account", "account": email, "profile": profile})
		}, func(emoji string) {
			event(map[string]any{"stage": "emoji", "emoji": emoji})
		})
		if err != nil {
			event(map[string]any{"stage": "error", "error": err.Error()})
			return
		}
		event(map[string]any{"stage": "done"})
		// run() is waiting for the session file and connects on its own.
	}()
	return nil
}

func (t *texting) setFocus(conv string) {
	t.mu.Lock()
	t.focus = conv
	t.mu.Unlock()
}

// run connects and stays connected: reconnects with backoff after failures,
// and waits for a session file while unpaired.
func (t *texting) run(ctx context.Context) {
	go t.processEvents(ctx)
	backoff := 5 * time.Second
	for ctx.Err() == nil {
		err := t.session(ctx)
		if ctx.Err() != nil {
			return
		}
		if errors.Is(err, errUnpaired) {
			t.setState("unpaired", "run: omadora-phone pair")
			waitForFile(ctx, sessionPath())
			backoff = 5 * time.Second
			continue
		}
		if err != nil {
			t.setState("error", err.Error())
		}
		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return
		}
		backoff = min(backoff*2, 5*time.Minute)
	}
}

var errUnpaired = errors.New("not paired")

// session runs one connection until it fails fatally or ctx ends.
func (t *texting) session(ctx context.Context) error {
	ad, err := loadSession()
	if err != nil {
		return errUnpaired
	}
	t.setState("connecting", "")
	cli := libgm.NewClient(ad, nil, logger(), exhttp.SensibleClientSettings)
	fatal := make(chan error, 1)
	cli.SetEventHandler(func(evt any) {
		// libgm calls this synchronously and forbids requests from it: queue.
		switch e := evt.(type) {
		case *events.ListenFatalError:
			select {
			case fatal <- e.Error:
			default:
			}
			return
		case *events.GaiaLoggedOut:
			select {
			case fatal <- errUnpaired:
			default:
			}
			return
		case *events.AuthTokenRefreshed:
			if err := saveSession(cli.AuthData); err != nil {
				fmt.Fprintln(os.Stderr, "save session:", err)
			}
			return
		}
		select {
		case t.events <- evt:
		default:
			fmt.Fprintln(os.Stderr, "event queue full; dropping", fmt.Sprintf("%T", evt))
		}
	})
	if err := cli.FetchConfig(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "fetch config:", err)
	}
	if err := cli.Connect(ctx); err != nil {
		if errors.Is(err, events.ErrRequestedEntityNotFound) || errors.Is(err, events.ErrInvalidCredentials) {
			return errUnpaired
		}
		return fmt.Errorf("connect: %w", err)
	}
	t.mu.Lock()
	t.cli = cli
	t.mu.Unlock()
	defer func() {
		cli.Disconnect()
		t.mu.Lock()
		t.cli = nil
		t.mu.Unlock()
	}()
	_ = saveSession(cli.AuthData)

	select {
	case err := <-fatal:
		if errors.Is(err, errUnpaired) {
			_ = os.Rename(sessionPath(), sessionPath()+".invalid")
		}
		return err
	case <-ctx.Done():
		return nil
	}
}

func (t *texting) processEvents(ctx context.Context) {
	for {
		var evt any
		select {
		case evt = <-t.events:
		case <-ctx.Done():
			return
		}
		switch e := evt.(type) {
		case *gmproto.Settings:
			first := false
			t.mu.Lock()
			first = t.state != "connected"
			t.mu.Unlock()
			t.setState("connected", "")
			if first {
				go t.refreshConversations(ctx)
			}
		case *gmproto.UserAlertEvent:
			switch e.GetAlertType() {
			case gmproto.AlertType_BROWSER_INACTIVE:
				// Messages for web opened somewhere else took over; reclaim() on next use.
				t.setState("inactive", "Messages is open in another browser")
			case gmproto.AlertType_BROWSER_ACTIVE:
				t.setState("connected", "")
				go t.refreshConversations(ctx)
			}
		case *events.NoDataReceived:
			go t.refreshConversations(ctx)
		case *events.PhoneNotResponding:
			t.setState("phone-offline", "")
		case *events.PhoneRespondingAgain, *events.ListenRecovered:
			t.setState("connected", "")
		case *events.ListenTemporaryError:
			t.setState("connecting", e.Error.Error())
		case *gmproto.Conversation:
			deleted := e.GetStatus() == gmproto.ConversationStatus_DELETED
			t.mu.Lock()
			if deleted {
				delete(t.convs, e.GetConversationID())
			} else {
				t.convs[e.GetConversationID()] = e
			}
			t.mu.Unlock()
			if deleted {
				t.cache.deleteConversation(e.GetConversationID())
			} else {
				t.cache.putConversations(e)
			}
			t.broadcastConversations()
		case *libgm.WrappedMessage:
			t.handleMessage(ctx, e)
		case *gmproto.TypingData:
			t.hub.event(nil, "typing", map[string]any{
				"conv": e.GetConversationID(), "typing": e.GetType() == gmproto.TypingTypes_STARTED_TYPING,
			})
		}
	}
}

func (t *texting) refreshConversations(ctx context.Context) {
	cli, err := t.client()
	if err != nil {
		return
	}
	listed := map[string]bool{}
	var oldest int64 = 1<<63 - 1
	for _, folder := range []gmproto.ListConversationsRequest_Folder{gmproto.ListConversationsRequest_INBOX, gmproto.ListConversationsRequest_ARCHIVE} {
		resp, err := cli.ListConversations(ctx, &gmproto.ListConversationsRequest{Count: 75, Folder: folder})
		if err != nil {
			fmt.Fprintln(os.Stderr, "list conversations:", err)
			return
		}
		convs := resp.GetConversations()
		t.mu.Lock()
		for _, c := range convs {
			t.convs[c.GetConversationID()] = c
			listed[c.GetConversationID()] = true
		}
		t.mu.Unlock()
		t.cache.putConversations(convs...)
		// A short page is the whole folder; a full one may continue past its oldest.
		if len(convs) == 75 {
			oldest = min(oldest, convs[len(convs)-1].GetLastMessageTimestamp())
		} else {
			oldest = 0
		}
	}
	// Forget cached conversations the phone no longer has.
	for _, id := range t.cache.pruneConversations(listed, oldest) {
		t.mu.Lock()
		delete(t.convs, id)
		t.mu.Unlock()
	}
	t.broadcastConversations()
	go t.prefetch(ctx)
}

func (t *texting) broadcastConversations() {
	t.hub.event(nil, "conversations", map[string]any{"conversations": t.conversationList()})
}

func (t *texting) conversationList() []Conversation {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]Conversation, 0, len(t.convs))
	for _, c := range t.convs {
		switch c.GetStatus() {
		case gmproto.ConversationStatus_ACTIVE, gmproto.ConversationStatus_UNKNOWN_CONVERSATION_STATUS,
			gmproto.ConversationStatus_ARCHIVED, gmproto.ConversationStatus_KEEP_ARCHIVED:
		default:
			continue // deleted, spam, blocked
		}
		out = append(out, toConversation(c))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].TS > out[j].TS })
	return out
}

func toConversation(c *gmproto.Conversation) Conversation {
	conv := Conversation{
		ID:       c.GetConversationID(),
		Name:     c.GetName(),
		Type:     short(c.GetType()),
		Group:    c.GetIsGroupChat(),
		Unread:   c.GetUnread(),
		TS:       c.GetLastMessageTimestamp() / 1000,
		Snippet:  c.GetLatestMessage().GetDisplayContent(),
		FromMe:   c.GetLatestMessage().GetFromMe() != 0,
		Color:    c.GetAvatarHexColor(),
		ReadOnly: c.GetReadOnly(),
		Pinned:   c.GetPinned(),
		Archived: c.GetStatus() == gmproto.ConversationStatus_ARCHIVED || c.GetStatus() == gmproto.ConversationStatus_KEEP_ARCHIVED,
	}
	if !conv.Group {
		for _, p := range c.GetParticipants() {
			if !p.GetIsMe() {
				conv.Number = p.GetID().GetNumber()
				if conv.Number == "" {
					conv.Number = p.GetFormattedNumber()
				}
				break
			}
		}
	}
	return conv
}

func (t *texting) conversation(ctx context.Context, id string) (*gmproto.Conversation, error) {
	t.mu.Lock()
	c := t.convs[id]
	t.mu.Unlock()
	if c != nil {
		return c, nil
	}
	cli, err := t.client()
	if err != nil {
		return nil, err
	}
	c, err = cli.GetConversation(ctx, id)
	if err != nil {
		return nil, err
	}
	t.mu.Lock()
	t.convs[id] = c
	t.mu.Unlock()
	return c, nil
}

// ------------------------------------------------------------- messages ----

const threadPage = 40

// messages answers from the cache when it has the thread, then refreshes it
// from the phone in the background (changes arrive as message /
// messageDeleted events). Without a cached copy it asks the phone directly.
func (t *texting) messages(ctx context.Context, convID string) ([]Message, error) {
	conv, err := t.conversation(ctx, convID)
	if err != nil {
		return nil, err
	}
	if cached := t.cache.messages(convID, threadPage); len(cached) > 0 {
		go t.refreshThread(context.WithoutCancel(ctx), convID)
		return t.convertAll(convID, conv, cached), nil
	}
	msgs, err := t.fetchThread(ctx, convID)
	if err != nil {
		return nil, err
	}
	t.cache.putMessages(msgs...)
	return t.convertAll(convID, conv, msgs), nil
}

// fetchThread gets a thread's latest messages from the phone, oldest first.
func (t *texting) fetchThread(ctx context.Context, convID string) ([]*gmproto.Message, error) {
	cli, err := t.client()
	if err != nil {
		return nil, err
	}
	resp, err := cli.FetchMessages(ctx, convID, threadPage, nil)
	if err != nil {
		return nil, err
	}
	msgs := resp.GetMessages()
	out := make([]*gmproto.Message, 0, len(msgs))
	for i := len(msgs) - 1; i >= 0; i-- {
		out = append(out, msgs[i])
	}
	return out, nil
}

// refreshThread syncs the cached thread with the phone and sends the panel
// what changed.
func (t *texting) refreshThread(ctx context.Context, convID string) {
	conv, err := t.conversation(ctx, convID)
	if err != nil {
		return
	}
	msgs, err := t.fetchThread(ctx, convID)
	if err != nil || len(msgs) == 0 {
		return
	}
	listed := map[string]bool{}
	for _, m := range msgs {
		listed[m.GetMessageID()] = true
	}
	changed := t.cache.putMessages(msgs...)
	gone := t.cache.pruneMessages(convID, listed, msgs[0].GetTimestamp())
	for _, m := range changed {
		if out, ok := t.convert(conv, m); ok {
			t.hub.event(nil, "message", map[string]any{"conv": convID, "message": out})
			t.fetchMedia(convID, conv, m)
		}
	}
	for _, id := range gone {
		t.hub.event(nil, "messageDeleted", map[string]any{"conv": convID, "id": id})
	}
}

const prefetchThreads = 30

// prefetch brings the most recent threads' cached messages up to date, one
// at a time, so they open instantly and search covers them.
func (t *texting) prefetch(ctx context.Context) {
	if t.cache == nil {
		return
	}
	t.mu.Lock()
	if t.prefetching {
		t.mu.Unlock()
		return
	}
	t.prefetching = true
	t.mu.Unlock()
	defer func() {
		t.mu.Lock()
		t.prefetching = false
		t.mu.Unlock()
	}()
	list := t.conversationList()
	for i, c := range list {
		if i >= prefetchThreads || ctx.Err() != nil {
			return
		}
		// Conversation timestamps are in µs, like message timestamps.
		if t.cache.newest(c.ID) >= c.TS*1000 {
			continue
		}
		t.refreshThread(ctx, c.ID)
		select {
		case <-time.After(300 * time.Millisecond):
		case <-ctx.Done():
			return
		}
	}
}

func (t *texting) convertAll(convID string, conv *gmproto.Conversation, msgs []*gmproto.Message) []Message {
	out := make([]Message, 0, len(msgs))
	for _, m := range msgs {
		if c, ok := t.convert(conv, m); ok {
			out = append(out, c)
			t.fetchMedia(convID, conv, m)
		}
	}
	return out
}

// search looks through cached message text.
func (t *texting) search(query string) []map[string]any {
	out := []map[string]any{}
	for _, m := range t.cache.search(query, 50) {
		t.mu.Lock()
		conv := t.convs[m.GetConversationID()]
		t.mu.Unlock()
		if conv == nil {
			continue
		}
		if msg, ok := t.convert(conv, m); ok {
			out = append(out, map[string]any{"conv": m.GetConversationID(), "name": conv.GetName(), "message": msg})
		}
	}
	return out
}

func (t *texting) handleMessage(ctx context.Context, w *libgm.WrappedMessage) {
	convID := w.GetConversationID()
	conv, err := t.conversation(ctx, convID)
	if err != nil {
		return
	}
	m, ok := t.convert(conv, w.Message)
	if isDeleted(w.Message) {
		t.cache.deleteMessage(w.GetMessageID())
	} else {
		t.cache.putMessages(w.Message)
	}
	if !ok {
		if isDeleted(w.Message) {
			t.hub.event(nil, "messageDeleted", map[string]any{"conv": convID, "id": w.GetMessageID()})
		}
		return
	}
	t.hub.event(nil, "message", map[string]any{"conv": convID, "message": m})
	t.fetchMedia(convID, conv, w.Message)

	if w.IsOld || m.FromMe || m.Status != "received" {
		return
	}
	t.mu.Lock()
	seen := t.notified[m.ID]
	t.notified[m.ID] = true
	if len(t.notified) > 2000 {
		t.notified = map[string]bool{m.ID: true}
	}
	focused := t.focus == convID
	t.mu.Unlock()
	if seen || focused {
		return
	}
	// The message is newer than the conversation snapshot: show it unread.
	t.mu.Lock()
	if c := t.convs[convID]; c != nil {
		c.Unread = true
		if c.LatestMessage == nil {
			c.LatestMessage = &gmproto.LatestMessage{}
		}
		c.LatestMessage.DisplayContent = m.Text
		c.LastMessageTimestamp = m.TS * 1000
	}
	t.mu.Unlock()
	t.broadcastConversations()

	title := m.Sender
	if conv.GetIsGroupChat() {
		title = m.Sender + " · " + conv.GetName()
	}
	body := m.Text
	if body == "" && len(m.Media) > 0 {
		body = "📎 " + m.Media[0].Mime
	}
	t.notifier.message(convID, title, body)
}

func statusName(s gmproto.MessageStatusType) string {
	switch {
	case s >= 200:
		return "system"
	case s >= 100:
		return "received"
	}
	switch s {
	case gmproto.MessageStatusType_OUTGOING_COMPLETE:
		return "sent"
	case gmproto.MessageStatusType_OUTGOING_DELIVERED:
		return "delivered"
	case gmproto.MessageStatusType_OUTGOING_DISPLAYED:
		return "read"
	case gmproto.MessageStatusType_OUTGOING_YET_TO_SEND, gmproto.MessageStatusType_OUTGOING_SENDING,
		gmproto.MessageStatusType_OUTGOING_RESENDING, gmproto.MessageStatusType_OUTGOING_AWAITING_RETRY,
		gmproto.MessageStatusType_OUTGOING_VALIDATING, gmproto.MessageStatusType_OUTGOING_SEND_AFTER_PROCESSING,
		gmproto.MessageStatusType_OUTGOING_NOT_DELIVERED_YET, gmproto.MessageStatusType_OUTGOING_SCHEDULED,
		gmproto.MessageStatusType_OUTGOING_DRAFT, gmproto.MessageStatusType_STATUS_UNKNOWN:
		return "sending"
	case gmproto.MessageStatusType_OUTGOING_DELETED:
		return "deleted"
	}
	return "failed"
}

func isDeleted(m *gmproto.Message) bool {
	switch m.GetMessageStatus().GetStatus() {
	case gmproto.MessageStatusType_OUTGOING_DELETED, gmproto.MessageStatusType_INCOMING_DELETED, gmproto.MessageStatusType_MESSAGE_DELETED:
		return true
	}
	return false
}

func (t *texting) convert(conv *gmproto.Conversation, m *gmproto.Message) (Message, bool) {
	status := statusName(m.GetMessageStatus().GetStatus())
	if status == "system" || isDeleted(m) {
		return Message{}, false
	}
	out := Message{
		ID:      m.GetMessageID(),
		TS:      m.GetTimestamp() / 1000,
		FromMe:  m.GetMessageStatus().GetStatus() < 100,
		Status:  status,
		Text:    text(m),
		Media:   []Media{},
		ReplyTo: m.GetReplyMessage().GetMessageID(),
	}
	out.Reactions = reactions(conv, m)
	if !out.FromMe {
		out.Sender = m.GetSenderParticipant().GetFullName()
		if out.Sender == "" {
			for _, p := range conv.GetParticipants() {
				if p.GetID().GetParticipantID() == m.GetParticipantID() {
					out.Sender = p.GetFullName()
					if out.Sender == "" {
						out.Sender = p.GetFormattedNumber()
					}
				}
			}
		}
		if out.Sender == "" {
			out.Sender = conv.GetName()
		}
	}
	// text() renders media as [mime]; keep the text part only.
	var parts []string
	for _, info := range m.GetMessageInfo() {
		if c := info.GetMessageContent(); c != nil && c.GetContent() != "" {
			parts = append(parts, c.GetContent())
		} else if media := info.GetMediaContent(); media != nil {
			out.Media = append(out.Media, Media{Mime: media.GetMimeType(), Name: media.GetMediaName(), Path: mediaPathIfPresent(media)})
		}
	}
	out.Text = strings.Join(parts, "\n")
	return out, true
}

func reactions(conv *gmproto.Conversation, m *gmproto.Message) []Reaction {
	me := map[string]bool{conv.GetDefaultOutgoingID(): true}
	for _, p := range conv.GetParticipants() {
		if p.GetIsMe() {
			me[p.GetID().GetParticipantID()] = true
		}
	}
	out := []Reaction{}
	for _, r := range m.GetReactions() {
		emoji := r.GetData().GetUnicode()
		if emoji == "" || len(r.GetParticipantIDs()) == 0 {
			continue
		}
		mine := false
		for _, id := range r.GetParticipantIDs() {
			mine = mine || me[id]
		}
		out = append(out, Reaction{Emoji: emoji, Count: len(r.GetParticipantIDs()), Mine: mine})
	}
	return out
}

// mediaDir keeps downloaded pictures across reboots (pruneMedia caps its size).
func mediaDir() string {
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".cache")
	}
	return filepath.Join(base, "omadora/phone/media")
}

// mediaSource picks what to download: the full image when the phone has
// uploaded it, else its preview (most received pictures only have a preview
// until someone asks the phone for the full size).
func mediaSource(media *gmproto.MediaContent) (id string, key []byte) {
	if media.GetMediaID() != "" {
		return media.GetMediaID(), media.GetDecryptionKey()
	}
	return media.GetThumbnailMediaID(), media.GetThumbnailDecryptionKey()
}

func mediaPath(media *gmproto.MediaContent) string {
	id, _ := mediaSource(media)
	sum := sha256.Sum256([]byte(id))
	ext := map[string]string{"image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif", "image/webp": ".webp", "image/heic": ".heic"}[media.GetMimeType()]
	if ext == "" {
		ext = ".bin"
		if exts, _ := mime.ExtensionsByType(media.GetMimeType()); len(exts) > 0 {
			ext = exts[0]
		}
	}
	return filepath.Join(mediaDir(), hex.EncodeToString(sum[:12])+ext)
}

func mediaPathIfPresent(media *gmproto.MediaContent) string {
	if !strings.HasPrefix(media.GetMimeType(), "image/") {
		return ""
	}
	p := mediaPath(media)
	if _, err := os.Stat(p); err == nil {
		return p
	}
	return ""
}

// fetchMedia downloads a message's images (in the background) and re-sends
// the message once they're on disk.
func (t *texting) fetchMedia(convID string, conv *gmproto.Conversation, m *gmproto.Message) {
	var todo []*gmproto.MediaContent
	for _, info := range m.GetMessageInfo() {
		media := info.GetMediaContent()
		if media != nil && os.Getenv("OMADORA_PHONE_DEBUG") != "" {
			fmt.Fprintf(os.Stderr, "media msg=%s mime=%q id=%q thumb=%q size=%d keylen=%d status=%s\n", m.GetMessageID(), media.GetMimeType(),
				media.GetMediaID(), media.GetThumbnailMediaID(), media.GetSize(), len(media.GetDecryptionKey()), m.GetMessageStatus().GetStatus())
		}
		if id, _ := mediaSource(media); media == nil || !strings.HasPrefix(media.GetMimeType(), "image/") || id == "" ||
			media.GetSize() > maxMediaBytes || mediaPathIfPresent(media) != "" {
			continue
		}
		todo = append(todo, media)
	}
	if len(todo) == 0 {
		return
	}
	go func() {
		cli, err := t.client()
		if err != nil {
			return
		}
		if err := os.MkdirAll(mediaDir(), 0o700); err != nil {
			return
		}
		for _, media := range todo {
			if err := download(cli, media); err != nil {
				fmt.Fprintln(os.Stderr, "download media:", err)
				return
			}
		}
		if msg, ok := t.convert(conv, m); ok {
			t.hub.event(nil, "message", map[string]any{"conv": convID, "message": msg})
		}
		pruneMedia()
	}()
}

func download(cli *libgm.Client, media *gmproto.MediaContent) error {
	id, key := mediaSource(media)
	rc, err := cli.DownloadMedia(id, key)
	if err != nil {
		return err
	}
	defer rc.Close()
	dst := mediaPath(media)
	tmp, err := os.CreateTemp(mediaDir(), ".dl-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := io.Copy(tmp, io.LimitReader(rc, maxMediaBytes)); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), dst)
}

// ------------------------------------------------------------- actions ----

func (t *texting) send(ctx context.Context, convID, body, replyTo string) error {
	body = strings.TrimSpace(body)
	if body == "" {
		return errors.New("empty message")
	}
	cli, err := t.client()
	if err != nil {
		return err
	}
	conv, err := t.conversation(ctx, convID)
	if err != nil {
		return err
	}
	tmp := fmt.Sprintf("tmp_%d", time.Now().UnixNano())
	resp, err := cli.SendMessage(ctx, &gmproto.SendMessageRequest{
		ConversationID: convID,
		MessagePayload: &gmproto.MessagePayload{
			TmpID:          tmp,
			TmpID2:         tmp,
			ConversationID: convID,
			ParticipantID:  conv.GetDefaultOutgoingID(),
			MessageInfo: []*gmproto.MessageInfo{{
				Data: &gmproto.MessageInfo_MessageContent{MessageContent: &gmproto.MessageContent{Content: body}},
			}},
		},
		SIMPayload: conv.GetSimCard().GetSIMData().GetSIMPayload(),
		TmpID:      tmp,
		Reply:      replyPayload(replyTo),
	})
	if err != nil {
		return err
	}
	if resp.GetStatus() != gmproto.SendMessageResponse_SUCCESS {
		return fmt.Errorf("phone refused the message (%s)", resp.GetStatus())
	}
	return nil
}

func (t *texting) markRead(ctx context.Context, convID string) error {
	cli, err := t.client()
	if err != nil {
		return err
	}
	conv, err := t.conversation(ctx, convID)
	if err != nil {
		return err
	}
	if !conv.GetUnread() {
		return nil
	}
	if err := cli.MarkRead(ctx, convID, conv.GetLatestMessageID()); err != nil {
		return err
	}
	t.mu.Lock()
	conv.Unread = false
	t.mu.Unlock()
	t.cache.putConversations(conv)
	t.broadcastConversations()
	return nil
}

func replyPayload(id string) *gmproto.ReplyPayload {
	if id == "" {
		return nil
	}
	return &gmproto.ReplyPayload{MessageID: id}
}

// setArchived archives or unarchives conversations.
func (t *texting) setArchived(ctx context.Context, ids []string, archived bool) error {
	cli, err := t.client()
	if err != nil {
		return err
	}
	status := gmproto.ConversationStatus_ACTIVE
	if archived {
		status = gmproto.ConversationStatus_ARCHIVED
	}
	var failed []string
	for _, id := range ids {
		resp, err := cli.UpdateConversation(ctx, &gmproto.UpdateConversationRequest{
			ConversationID: id,
			Data: &gmproto.UpdateConversationRequest_UpdateData{UpdateData: &gmproto.UpdateConversationData{
				ConversationID: id,
				Data:           &gmproto.UpdateConversationData_Status{Status: status},
			}},
		})
		if err != nil || !resp.GetSuccess() {
			failed = append(failed, id)
			continue
		}
		t.mu.Lock()
		c := t.convs[id]
		if c != nil {
			c.Status = status
		}
		t.mu.Unlock()
		if c != nil {
			t.cache.putConversations(c)
		}
	}
	t.broadcastConversations()
	return failedErr("archive", failed, len(ids))
}

// deleteConversations deletes conversations on the phone, or blocks their
// senders (blockMode "block" / "spam": block and report spam).
func (t *texting) deleteConversations(ctx context.Context, ids []string, blockMode string) error {
	cli, err := t.client()
	if err != nil {
		return err
	}
	var failed []string
	for _, id := range ids {
		conv, err := t.conversation(ctx, id)
		if err != nil {
			failed = append(failed, id)
			continue
		}
		req := &gmproto.UpdateConversationRequest{
			Action:         gmproto.ConversationActionStatus_DELETE,
			ConversationID: id,
		}
		switch blockMode {
		case "block":
			req.Action, req.Action5 = gmproto.ConversationActionStatus_BLOCK, &gmproto.ConversationAction5{Field2: true}
		case "spam":
			req.Action, req.Action5 = gmproto.ConversationActionStatus_BLOCK_AND_REPORT, &gmproto.ConversationAction5{Field2: true}
		}
		phone := toConversation(conv).Number
		data := &gmproto.DeleteConversationData{ConversationID: id}
		if phone != "" {
			data.Phone = &phone
		}
		req.Data = &gmproto.UpdateConversationRequest_DeleteData{DeleteData: data}
		resp, err := cli.UpdateConversation(ctx, req)
		if err != nil || !resp.GetSuccess() {
			failed = append(failed, id)
			continue
		}
		t.mu.Lock()
		delete(t.convs, id)
		t.mu.Unlock()
		t.cache.deleteConversation(id)
	}
	t.broadcastConversations()
	return failedErr(map[string]string{"": "delete", "block": "block", "spam": "report"}[blockMode], failed, len(ids))
}

func failedErr(action string, failed []string, total int) error {
	if len(failed) == 0 {
		return nil
	}
	return fmt.Errorf("couldn't %s %d of %d conversations", action, len(failed), total)
}

func (t *texting) deleteMessage(ctx context.Context, convID, msgID string) error {
	cli, err := t.client()
	if err != nil {
		return err
	}
	resp, err := cli.DeleteMessage(ctx, msgID)
	if err != nil {
		return err
	}
	if !resp.GetSuccess() {
		return errors.New("the phone didn't delete the message")
	}
	t.cache.deleteMessage(msgID)
	t.hub.event(nil, "messageDeleted", map[string]any{"conv": convID, "id": msgID})
	return nil
}

func (t *texting) react(ctx context.Context, convID, msgID, emoji string, remove bool) error {
	cli, err := t.client()
	if err != nil {
		return err
	}
	conv, err := t.conversation(ctx, convID)
	if err != nil {
		return err
	}
	action := gmproto.SendReactionRequest_ADD
	if remove {
		action = gmproto.SendReactionRequest_REMOVE
	}
	resp, err := cli.SendReaction(ctx, &gmproto.SendReactionRequest{
		MessageID:    msgID,
		ReactionData: gmproto.MakeReactionData(emoji),
		Action:       action,
		SIMPayload:   conv.GetSimCard().GetSIMData().GetSIMPayload(),
	})
	if err != nil {
		return err
	}
	if !resp.GetSuccess() {
		return errors.New("the phone didn't accept the reaction")
	}
	return nil
}

func (t *texting) newConversation(ctx context.Context, number string) (string, error) {
	number = cleanNumber(number)
	if len(digits(number)) < 3 {
		return "", errors.New("not a phone number")
	}
	cli, err := t.client()
	if err != nil {
		return "", err
	}
	resp, err := cli.GetOrCreateConversation(ctx, &gmproto.GetOrCreateConversationRequest{
		Numbers: []*gmproto.ContactNumber{{MysteriousInt: 2, Number: number, Number2: number}},
	})
	if err != nil {
		return "", err
	}
	c := resp.GetConversation()
	if c == nil {
		return "", fmt.Errorf("phone didn't create a conversation (%s)", resp.GetStatus())
	}
	t.mu.Lock()
	t.convs[c.GetConversationID()] = c
	t.mu.Unlock()
	t.broadcastConversations()
	return c.GetConversationID(), nil
}

func (t *texting) contacts(ctx context.Context) ([]Contact, error) {
	t.mu.Lock()
	cached, fresh := t.contactList, t.contactsNew
	t.mu.Unlock()
	if cached != nil {
		if !fresh {
			go t.refreshContacts(context.WithoutCancel(ctx))
		}
		return cached, nil
	}
	return t.refreshContacts(ctx)
}

func (t *texting) refreshContacts(ctx context.Context) ([]Contact, error) {
	t.mu.Lock()
	t.contactsNew = true
	t.mu.Unlock()
	cli, err := t.client()
	if err != nil {
		return nil, err
	}
	resp, err := cli.ListContacts(ctx)
	if err != nil {
		return nil, err
	}
	out := []Contact{}
	for _, c := range resp.GetContacts() {
		number := c.GetNumber().GetNumber()
		if number == "" {
			number = c.GetNumber().GetNumber2()
		}
		if c.GetName() == "" || number == "" {
			continue
		}
		out = append(out, Contact{Name: c.GetName(), Number: number})
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	t.mu.Lock()
	t.contactList = out
	t.mu.Unlock()
	t.cache.putJSON("contacts", out)
	return out, nil
}

// nameFor finds a name for a phone number (caller ID), from contacts or
// one-to-one conversations. Only what's cached: never blocks on the phone.
func (t *texting) nameFor(number string) string {
	want := lastDigits(number)
	if want == "" {
		return ""
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, c := range t.contactList {
		if lastDigits(c.Number) == want {
			return c.Name
		}
	}
	for _, c := range t.convs {
		if c.GetIsGroupChat() {
			continue
		}
		for _, p := range c.GetParticipants() {
			if !p.GetIsMe() && lastDigits(p.GetID().GetNumber()) == want && p.GetFullName() != "" {
				return p.GetFullName()
			}
		}
	}
	return ""
}

func digits(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// lastDigits compares numbers regardless of country code and formatting.
func lastDigits(s string) string {
	d := digits(s)
	if len(d) > 10 {
		d = d[len(d)-10:]
	}
	if len(d) < 7 {
		return ""
	}
	return d
}

func cleanNumber(s string) string {
	s = strings.TrimSpace(s)
	plus := strings.HasPrefix(s, "+")
	d := digits(s)
	if plus {
		return "+" + d
	}
	return d
}

func waitForFile(ctx context.Context, path string) {
	t := time.NewTicker(3 * time.Second)
	defer t.Stop()
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		select {
		case <-t.C:
		case <-ctx.Done():
			return
		}
	}
}
