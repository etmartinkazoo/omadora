package main

// The daemon: one long-lived connection to Google Messages (texting.go) and
// to PipeWire's hands-free telephony service (calls.go), served to the
// Quickshell panel over a Unix socket. See PROTOCOL.md.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
)

func runtimeDir() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return d
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("omadora-phone-%d", os.Getuid()))
}

func socketPath() string { return filepath.Join(runtimeDir(), "omadora-phone.sock") }

type request struct {
	ID     *json.Number `json:"id,omitempty"`
	Cmd    string       `json:"cmd"`
	Conv   string       `json:"conv,omitempty"`
	Text   string       `json:"text,omitempty"`
	Number string       `json:"number,omitempty"`
	Call   string       `json:"call,omitempty"`
	Tones  string       `json:"tones,omitempty"`

	Convs   []string `json:"convs,omitempty"`
	Message string   `json:"message,omitempty"`
	Emoji   string   `json:"emoji,omitempty"`
	Remove  bool     `json:"remove,omitempty"`
	ReplyTo string   `json:"replyTo,omitempty"`
}

type reply struct {
	ID    *json.Number `json:"id,omitempty"`
	OK    bool         `json:"ok"`
	Data  any          `json:"data,omitempty"`
	Error string       `json:"error,omitempty"`
}

type client struct {
	out  chan []byte
	conn net.Conn
}

// hub fans events out to every connected client.
type hub struct {
	mu      sync.Mutex
	clients map[*client]struct{}
}

func (h *hub) add(c *client) {
	h.mu.Lock()
	h.clients[c] = struct{}{}
	h.mu.Unlock()
}

func (h *hub) remove(c *client) {
	h.mu.Lock()
	if _, ok := h.clients[c]; ok {
		delete(h.clients, c)
		close(c.out)
	}
	h.mu.Unlock()
}

// event sends {"event": name, ...fields} to every client (or just one).
func (h *hub) event(to *client, name string, fields map[string]any) {
	msg := map[string]any{"event": name}
	for k, v := range fields {
		msg[k] = v
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	data = append(data, '\n')
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients {
		if to != nil && c != to {
			continue
		}
		select {
		case c.out <- data:
		default:
			// A client that stopped reading: drop it rather than stall everyone.
			delete(h.clients, c)
			close(c.out)
			c.conn.Close()
		}
	}
}

type daemon struct {
	hub   *hub
	text  *texting
	calls *calls
}

func runDaemon(ctx context.Context) error {
	if err := os.MkdirAll(runtimeDir(), 0o700); err != nil {
		return err
	}
	path := socketPath()
	if c, err := net.Dial("unix", path); err == nil {
		c.Close()
		return errors.New("already running (" + path + ")")
	}
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	defer os.Remove(path)
	if err := os.Chmod(path, 0o600); err != nil {
		return err
	}

	d := &daemon{hub: &hub{clients: map[*client]struct{}{}}}
	d.text = newTexting(d.hub)
	d.text.loadCache()
	d.calls = newCalls(d.hub, d.text)
	d.text.onState = d.broadcastState
	d.calls.onState = d.broadcastState
	go d.text.run(ctx)
	go d.calls.run(ctx)

	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go d.serve(ctx, conn)
	}
}

func (d *daemon) serve(ctx context.Context, conn net.Conn) {
	c := &client{out: make(chan []byte, 256), conn: conn}
	d.hub.add(c)
	defer d.hub.remove(c)
	go func() {
		for data := range c.out {
			if _, err := conn.Write(data); err != nil {
				conn.Close()
				return
			}
		}
	}()
	defer conn.Close()

	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		var req request
		dec := json.NewDecoder(bytes.NewReader(sc.Bytes()))
		dec.UseNumber()
		if err := dec.Decode(&req); err != nil {
			d.reply(c, reply{Error: "bad request: " + err.Error()})
			continue
		}
		// Requests may block on the phone; don't hold up this client's other requests.
		go func(req request) {
			data, err := d.handle(ctx, c, req)
			r := reply{ID: req.ID, OK: err == nil, Data: data}
			if err != nil {
				r.Error = err.Error()
			}
			d.reply(c, r)
		}(req)
	}
}

func (d *daemon) reply(c *client, r reply) {
	data, err := json.Marshal(r)
	if err != nil {
		return
	}
	d.hub.mu.Lock()
	defer d.hub.mu.Unlock()
	if _, ok := d.hub.clients[c]; ok {
		select {
		case c.out <- append(data, '\n'):
		default:
		}
	}
}

func (d *daemon) handle(ctx context.Context, c *client, req request) (any, error) {
	switch req.Cmd {
	case "hello":
		go d.text.reclaim()
		d.hub.event(c, "state", d.state())
		d.hub.event(c, "conversations", map[string]any{"conversations": d.text.conversationList()})
		d.hub.event(c, "calls", map[string]any{"calls": d.calls.list()})
		return nil, nil
	case "messages":
		msgs, err := d.text.messages(ctx, req.Conv)
		if err != nil {
			return nil, err
		}
		return map[string]any{"conv": req.Conv, "messages": msgs}, nil
	case "send":
		if err := d.text.send(ctx, req.Conv, req.Text, req.ReplyTo); err != nil {
			return nil, err
		}
		return map[string]any{"conv": req.Conv}, nil
	case "markRead":
		for _, id := range convList(req) {
			if err := d.text.markRead(ctx, id); err != nil {
				return nil, err
			}
		}
		return nil, nil
	case "archive", "unarchive":
		return nil, d.text.setArchived(ctx, convList(req), req.Cmd == "archive")
	case "delete":
		return nil, d.text.deleteConversations(ctx, convList(req), "")
	case "block":
		return nil, d.text.deleteConversations(ctx, convList(req), "block")
	case "reportSpam":
		return nil, d.text.deleteConversations(ctx, convList(req), "spam")
	case "search":
		return map[string]any{"results": d.text.search(req.Text)}, nil
	case "deleteMessage":
		return nil, d.text.deleteMessage(ctx, req.Conv, req.Message)
	case "react":
		return nil, d.text.react(ctx, req.Conv, req.Message, req.Emoji, req.Remove)
	case "newConversation":
		id, err := d.text.newConversation(ctx, req.Number)
		if err != nil {
			return nil, err
		}
		return map[string]any{"conv": id}, nil
	case "contacts":
		contacts, err := d.text.contacts(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"contacts": contacts}, nil
	case "focus":
		d.text.setFocus(req.Conv)
		return nil, nil
	case "pairMessages":
		return nil, d.text.startPairing()
	case "dial":
		return nil, d.calls.dial(req.Number)
	case "answer":
		return nil, d.calls.callMethod(req.Call, "Answer")
	case "hangup":
		return nil, d.calls.callMethod(req.Call, "Hangup")
	case "hangupAll":
		return nil, d.calls.agMethod("HangupAll")
	case "tones":
		return nil, d.calls.agMethod("SendTones", req.Tones)
	case "swap":
		return nil, d.calls.agMethod("SwapCalls")
	case "holdAndAnswer":
		return nil, d.calls.agMethod("HoldAndAnswer")
	}
	return nil, fmt.Errorf("unknown command %q", req.Cmd)
}

// convList is a request's conversations: `convs`, or the single `conv`.
func convList(req request) []string {
	if len(req.Convs) > 0 {
		return req.Convs
	}
	if req.Conv != "" {
		return []string{req.Conv}
	}
	return nil
}

// state is the `state` event's fields.
func (d *daemon) state() map[string]any {
	status, errText := d.text.status()
	return map[string]any{
		"texting":      status,
		"textingError": errText,
		"bluetooth":    d.calls.bluetooth(),
	}
}

// broadcastState sends the current state to everyone; texting and calls call
// it when their part changes.
func (d *daemon) broadcastState() {
	d.hub.event(nil, "state", d.state())
}
