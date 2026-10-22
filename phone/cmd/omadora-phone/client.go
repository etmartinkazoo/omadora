package main

// When the daemon runs, the CLI goes through it: Google Messages has one
// active web session at a time, and a second connection would take it over.

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"
)

type daemonConn struct {
	conn net.Conn
	sc   *bufio.Scanner
}

// dialDaemon returns nil (and no error) when the daemon isn't running.
func dialDaemon() *daemonConn {
	conn, err := net.DialTimeout("unix", socketPath(), time.Second)
	if err != nil {
		return nil
	}
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 64*1024), 16*1024*1024)
	return &daemonConn{conn: conn, sc: sc}
}

// call sends a request and waits for its reply, collecting events on the way.
func (d *daemonConn) call(req map[string]any) (json.RawMessage, map[string]json.RawMessage, error) {
	req["id"] = 1
	data, _ := json.Marshal(req)
	_ = d.conn.SetDeadline(time.Now().Add(60 * time.Second))
	if _, err := d.conn.Write(append(data, '\n')); err != nil {
		return nil, nil, err
	}
	evs := map[string]json.RawMessage{}
	for d.sc.Scan() {
		var line struct {
			Event string          `json:"event"`
			ID    *int            `json:"id"`
			OK    bool            `json:"ok"`
			Data  json.RawMessage `json:"data"`
			Error string          `json:"error"`
		}
		if json.Unmarshal(d.sc.Bytes(), &line) != nil {
			continue
		}
		if line.Event != "" {
			evs[line.Event] = append(json.RawMessage(nil), d.sc.Bytes()...)
			continue
		}
		if line.ID != nil && *line.ID == 1 {
			if !line.OK {
				return nil, evs, errors.New(line.Error)
			}
			return line.Data, evs, nil
		}
	}
	if err := d.sc.Err(); err != nil {
		return nil, evs, err
	}
	return nil, evs, errors.New("daemon closed the connection")
}

func (d *daemonConn) list() error {
	_, evs, err := d.call(map[string]any{"cmd": "hello"})
	if err != nil {
		return err
	}
	var ev struct {
		Conversations []Conversation `json:"conversations"`
	}
	if raw, ok := evs["conversations"]; ok {
		_ = json.Unmarshal(raw, &ev)
	}
	for _, c := range ev.Conversations {
		fmt.Printf("%-8s %-4s %-28.28s %s  %.50q\n", c.ID, c.Type, c.Name, time.UnixMilli(c.TS).Format("01-02 15:04"), c.Snippet)
	}
	return nil
}

func (d *daemonConn) messages(conv string) error {
	data, _, err := d.call(map[string]any{"cmd": "messages", "conv": conv})
	if err != nil {
		return err
	}
	var resp struct {
		Messages []Message `json:"messages"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return err
	}
	for _, m := range resp.Messages {
		who := "them"
		if m.FromMe {
			who = "me"
		}
		fmt.Printf("%s  %-4s %-9s %q\n", time.UnixMilli(m.TS).Format("01-02 15:04"), who, m.Status, m.Text)
	}
	return nil
}

func (d *daemonConn) send(conv, text string) error {
	_, _, err := d.call(map[string]any{"cmd": "send", "conv": conv, "text": text})
	if err == nil {
		fmt.Println("sent")
	}
	return err
}
