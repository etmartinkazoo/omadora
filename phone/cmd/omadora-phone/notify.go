package main

// Desktop notifications for new texts. Clicking one opens the conversation
// in the panel; typing in its reply box (the "inline-reply" action, a KDE
// extension Quickshell implements) sends the text without opening anything.

import (
	"fmt"
	"os"
	"os/exec"
	"sync"

	"github.com/godbus/dbus/v5"
)

type notifier struct {
	mu    sync.Mutex
	conn  *dbus.Conn
	convs map[uint32]string // notification ID -> conversation
	last  map[string]uint32 // conversation -> its latest notification (replaced, not stacked)
	reply func(conv, text string) error
}

func newNotifier(reply func(conv, text string) error) *notifier {
	n := &notifier{convs: map[uint32]string{}, last: map[string]uint32{}, reply: reply}
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		fmt.Fprintln(os.Stderr, "notifications disabled:", err)
		return n
	}
	n.conn = conn
	_ = conn.AddMatchSignal(dbus.WithMatchInterface("org.freedesktop.Notifications"), dbus.WithMatchMember("ActionInvoked"))
	_ = conn.AddMatchSignal(dbus.WithMatchInterface("org.freedesktop.Notifications"), dbus.WithMatchMember("NotificationClosed"))
	_ = conn.AddMatchSignal(dbus.WithMatchInterface("org.freedesktop.Notifications"), dbus.WithMatchMember("NotificationReplied"))
	signals := make(chan *dbus.Signal, 16)
	conn.Signal(signals)
	go func() {
		for sig := range signals {
			if len(sig.Body) < 1 || (sig.Name == "org.freedesktop.Notifications.NotificationReplied" && len(sig.Body) < 2) {
				continue
			}
			id, _ := sig.Body[0].(uint32)
			n.mu.Lock()
			conv, ok := n.convs[id]
			if sig.Name == "org.freedesktop.Notifications.NotificationClosed" {
				delete(n.convs, id)
				if n.last[conv] == id {
					delete(n.last, conv)
				}
			}
			n.mu.Unlock()
			if !ok {
				continue
			}
			switch sig.Name {
			case "org.freedesktop.Notifications.ActionInvoked":
				_ = exec.Command("qs", "ipc", "call", "phone", "openConversation", conv).Run()
			case "org.freedesktop.Notifications.NotificationReplied":
				text, _ := sig.Body[1].(string)
				go func() {
					if err := n.reply(conv, text); err != nil {
						fmt.Fprintln(os.Stderr, "reply:", err)
						n.failed(conv, err)
					}
				}()
			}
		}
	}()
	return n
}

func (n *notifier) message(conv, title, body string) {
	n.notify(conv, title, body, []string{"default", "Open", "inline-reply", "Reply"}, map[string]dbus.Variant{
		"category":                     dbus.MakeVariant("im.received"),
		"x-kde-reply-placeholder-text": dbus.MakeVariant("Reply to " + title),
	})
}

// failed reports a reply that didn't go out, in that conversation's slot;
// clicking it opens the conversation to try again.
func (n *notifier) failed(conv string, err error) {
	n.notify(conv, "Reply not sent", err.Error(), []string{"default", "Open"},
		map[string]dbus.Variant{"category": dbus.MakeVariant("im.error")})
}

func (n *notifier) notify(conv, title, body string, actions []string, hints map[string]dbus.Variant) {
	if n.conn == nil {
		return
	}
	n.mu.Lock()
	replaces := n.last[conv]
	n.mu.Unlock()
	obj := n.conn.Object("org.freedesktop.Notifications", "/org/freedesktop/Notifications")
	var id uint32
	err := obj.Call("org.freedesktop.Notifications.Notify", 0,
		"Messages", replaces, "phone", title, body, actions, hints, int32(-1)).Store(&id)
	if err != nil {
		fmt.Fprintln(os.Stderr, "notify:", err)
		return
	}
	n.mu.Lock()
	n.convs[id] = conv
	n.last[conv] = id
	n.mu.Unlock()
}
