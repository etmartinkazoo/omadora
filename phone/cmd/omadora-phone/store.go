package main

// Local cache: conversations, recent messages and contacts in SQLite, so the
// panel shows something instantly (after a restart, with the phone offline)
// and threads open without a round trip. The phone stays the source of
// truth: everything here is overwritten by what it sends.
//
// Rows hold the protobufs libgm hands us, so the conversion code is shared
// with live events. The file is readable only by you.

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

const (
	keepPerConversation = 1000
	mediaCacheBytes     = 500 * 1024 * 1024
)

// A nil *store (the cache couldn't be opened) caches nothing.
type store struct {
	db *sql.DB
}

func cachePath() string { return filepath.Join(stateDir(), "cache.db") }

func openStore() (*store, error) {
	if err := os.MkdirAll(stateDir(), 0o700); err != nil {
		return nil, err
	}
	// Create it private before SQLite does (it would use the umask).
	if f, err := os.OpenFile(cachePath(), os.O_CREATE|os.O_RDWR, 0o600); err == nil {
		f.Close()
	}
	db, err := sql.Open("sqlite", "file:"+cachePath()+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, ts INTEGER NOT NULL, data BLOB NOT NULL);
		CREATE TABLE IF NOT EXISTS messages (
			id TEXT PRIMARY KEY, conv TEXT NOT NULL, ts INTEGER NOT NULL, text TEXT NOT NULL, data BLOB NOT NULL);
		CREATE INDEX IF NOT EXISTS messages_conv_ts ON messages (conv, ts);
		CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL);`)
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("cache: %w", err)
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		_ = os.Chmod(cachePath()+suffix, 0o600)
	}
	return &store{db: db}, nil
}

// ------------------------------------------------------------ conversations

func (s *store) conversations() []*gmproto.Conversation {
	if s == nil {
		return nil
	}
	rows, err := s.db.Query(`SELECT data FROM conversations`)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*gmproto.Conversation
	for rows.Next() {
		var data []byte
		c := &gmproto.Conversation{}
		if rows.Scan(&data) == nil && proto.Unmarshal(data, c) == nil {
			out = append(out, c)
		}
	}
	return out
}

func (s *store) putConversations(convs ...*gmproto.Conversation) {
	if s == nil {
		return
	}
	tx, err := s.db.Begin()
	if err != nil {
		return
	}
	defer tx.Rollback()
	for _, c := range convs {
		data, err := proto.Marshal(c)
		if err != nil {
			continue
		}
		_, _ = tx.Exec(`INSERT INTO conversations (id, ts, data) VALUES (?, ?, ?)
			ON CONFLICT (id) DO UPDATE SET ts = excluded.ts, data = excluded.data`,
			c.GetConversationID(), c.GetLastMessageTimestamp(), data)
	}
	_ = tx.Commit()
}

func (s *store) deleteConversation(id string) {
	if s == nil {
		return
	}
	_, _ = s.db.Exec(`DELETE FROM conversations WHERE id = ?`, id)
	_, _ = s.db.Exec(`DELETE FROM messages WHERE conv = ?`, id)
}

// pruneConversations drops cached conversations the phone no longer lists:
// only ones at least as new as the oldest it did list (older ones may just be
// past the end of the page).
func (s *store) pruneConversations(listed map[string]bool, oldest int64) []string {
	if s == nil {
		return nil
	}
	rows, err := s.db.Query(`SELECT id FROM conversations WHERE ts >= ?`, oldest)
	if err != nil {
		return nil
	}
	var gone []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil && !listed[id] {
			gone = append(gone, id)
		}
	}
	rows.Close()
	for _, id := range gone {
		s.deleteConversation(id)
	}
	return gone
}

// ----------------------------------------------------------------- messages

func (s *store) messages(conv string, limit int) []*gmproto.Message {
	if s == nil {
		return nil
	}
	rows, err := s.db.Query(`SELECT data FROM (
		SELECT data, ts FROM messages WHERE conv = ? ORDER BY ts DESC LIMIT ?) ORDER BY ts ASC`, conv, limit)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*gmproto.Message
	for rows.Next() {
		var data []byte
		m := &gmproto.Message{}
		if rows.Scan(&data) == nil && proto.Unmarshal(data, m) == nil {
			out = append(out, m)
		}
	}
	return out
}

// putMessages stores messages and reports which ones are new or changed.
func (s *store) putMessages(msgs ...*gmproto.Message) (changed []*gmproto.Message) {
	if s == nil {
		return msgs
	}
	tx, err := s.db.Begin()
	if err != nil {
		return msgs
	}
	defer tx.Rollback()
	convs := map[string]bool{}
	for _, m := range msgs {
		data, err := proto.MarshalOptions{Deterministic: true}.Marshal(m)
		if err != nil {
			continue
		}
		var old []byte
		_ = tx.QueryRow(`SELECT data FROM messages WHERE id = ?`, m.GetMessageID()).Scan(&old)
		if string(old) == string(data) {
			continue
		}
		changed = append(changed, m)
		_, _ = tx.Exec(`INSERT INTO messages (id, conv, ts, text, data) VALUES (?, ?, ?, ?, ?)
			ON CONFLICT (id) DO UPDATE SET conv = excluded.conv, ts = excluded.ts, text = excluded.text, data = excluded.data`,
			m.GetMessageID(), m.GetConversationID(), m.GetTimestamp(), plainText(m), data)
		convs[m.GetConversationID()] = true
	}
	for conv := range convs {
		_, _ = tx.Exec(`DELETE FROM messages WHERE conv = ? AND id NOT IN (
			SELECT id FROM messages WHERE conv = ? ORDER BY ts DESC LIMIT ?)`, conv, conv, keepPerConversation)
	}
	_ = tx.Commit()
	return changed
}

// newest is the timestamp of a conversation's latest cached message (0 if none).
func (s *store) newest(conv string) int64 {
	if s == nil {
		return 0
	}
	var ts sql.NullInt64
	_ = s.db.QueryRow(`SELECT max(ts) FROM messages WHERE conv = ?`, conv).Scan(&ts)
	return ts.Int64
}

func (s *store) deleteMessage(id string) {
	if s == nil {
		return
	}
	_, _ = s.db.Exec(`DELETE FROM messages WHERE id = ?`, id)
}

// pruneMessages drops cached messages in conv's time window [from, ∞) that
// the phone didn't return: deleted there while we weren't looking.
func (s *store) pruneMessages(conv string, listed map[string]bool, from int64) []string {
	if s == nil {
		return nil
	}
	rows, err := s.db.Query(`SELECT id FROM messages WHERE conv = ? AND ts >= ?`, conv, from)
	if err != nil {
		return nil
	}
	var gone []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil && !listed[id] {
			gone = append(gone, id)
		}
	}
	rows.Close()
	for _, id := range gone {
		s.deleteMessage(id)
	}
	return gone
}

type searchHit struct {
	Conv    string  `json:"conv"`
	Message Message `json:"message"`
}

// search finds messages containing every word of query (case-insensitive).
func (s *store) search(query string, limit int) []*gmproto.Message {
	if s == nil {
		return nil
	}
	words := strings.Fields(strings.ToLower(query))
	if len(words) == 0 {
		return nil
	}
	where := make([]string, len(words))
	args := make([]any, 0, len(words)+1)
	for i, w := range words {
		where[i] = `lower(text) LIKE ? ESCAPE '\'`
		w = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(w)
		args = append(args, "%"+w+"%")
	}
	args = append(args, limit)
	rows, err := s.db.Query(`SELECT data FROM messages WHERE `+strings.Join(where, " AND ")+` ORDER BY ts DESC LIMIT ?`, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*gmproto.Message
	for rows.Next() {
		var data []byte
		m := &gmproto.Message{}
		if rows.Scan(&data) == nil && proto.Unmarshal(data, m) == nil {
			out = append(out, m)
		}
	}
	return out
}

func plainText(m *gmproto.Message) string {
	var parts []string
	for _, info := range m.GetMessageInfo() {
		if c := info.GetMessageContent(); c != nil && c.GetContent() != "" {
			parts = append(parts, c.GetContent())
		}
	}
	return strings.Join(parts, "\n")
}

// ----------------------------------------------------------------------- kv

func (s *store) getJSON(key string, v any) bool {
	if s == nil {
		return false
	}
	var data []byte
	if s.db.QueryRow(`SELECT value FROM kv WHERE key = ?`, key).Scan(&data) != nil {
		return false
	}
	return json.Unmarshal(data, v) == nil
}

func (s *store) putJSON(key string, v any) {
	if s == nil {
		return
	}
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	_, _ = s.db.Exec(`INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value`, key, data)
}

// -------------------------------------------------------------------- media

// pruneMedia keeps the picture cache under mediaCacheBytes, oldest first.
func pruneMedia() {
	entries, err := os.ReadDir(mediaDir())
	if err != nil {
		return
	}
	type file struct {
		path string
		size int64
		mod  time.Time
	}
	var files []file
	var total int64
	for _, e := range entries {
		info, err := e.Info()
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		files = append(files, file{filepath.Join(mediaDir(), e.Name()), info.Size(), info.ModTime()})
		total += info.Size()
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mod.Before(files[j].mod) })
	for _, f := range files {
		if total <= mediaCacheBytes {
			break
		}
		if os.Remove(f.path) == nil {
			total -= f.size
		}
	}
}
