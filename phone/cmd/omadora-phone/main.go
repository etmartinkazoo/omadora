// omadora-phone: texts (SMS + RCS) through Google Messages' web protocol.
//
//	omadora-phone setup             pair texts (if needed), then open the panel's setup for calls
//	omadora-phone pair [--profile NAME] [--account EMAIL]
//	                                  pair through the Google account signed in to Firefox
//	                                  (NAME: a Firefox profile; EMAIL: refuse any other account;
//	                                  both are remembered for next time)
//	omadora-phone pair --qr         pair by QR code, where Google still offers it
//	omadora-phone whoami [--profile NAME]
//	                                  which Google account that profile would pair as
//	omadora-phone daemon            serve the Quickshell panel (see PROTOCOL.md)
//	omadora-phone list              recent conversations
//	omadora-phone messages CONV_ID  recent messages in a conversation
//	omadora-phone send CONV_ID TEXT send a text
//	omadora-phone watch             print events as they arrive
//
// list, messages and send go through the daemon when it's running.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/rs/zerolog"
	"github.com/skip2/go-qrcode"
	"go.mau.fi/util/exhttp"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

func stateDir() string {
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".local/state")
	}
	return filepath.Join(base, "omadora/phone")
}

func sessionPath() string { return filepath.Join(stateDir(), "session.json") }

func saveSession(ad *libgm.AuthData) error {
	if err := os.MkdirAll(stateDir(), 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(ad)
	if err != nil {
		return err
	}
	tmp := sessionPath() + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, sessionPath())
}

func loadSession() (*libgm.AuthData, error) {
	data, err := os.ReadFile(sessionPath())
	if err != nil {
		return nil, fmt.Errorf("not paired (run: omadora-phone pair): %w", err)
	}
	ad := libgm.NewAuthData()
	return ad, json.Unmarshal(data, ad)
}

func logger() zerolog.Logger {
	level := zerolog.WarnLevel
	if os.Getenv("OMADORA_PHONE_DEBUG") != "" {
		level = zerolog.DebugLevel
	}
	return zerolog.New(zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.TimeOnly}).Level(level).With().Timestamp().Logger()
}

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "omadora-phone: "+format+"\n", a...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		die("usage: setup | daemon | pair | whoami | list | messages CONV_ID | send CONV_ID TEXT | watch")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	var err error
	switch os.Args[1] {
	case "pair":
		opts := flags(os.Args[2:])
		if opts["qr"] != "" {
			err = pairQR(ctx)
		} else {
			err = pairGoogle(ctx, opts["profile"], opts["account"], false)
		}
	case "setup":
		err = setup(ctx)
	case "whoami":
		err = pairGoogle(ctx, flags(os.Args[2:])["profile"], "", true)
	case "daemon":
		err = runDaemon(ctx)
	case "list":
		if d := dialDaemon(); d != nil {
			err = d.list()
		} else {
			err = withClient(ctx, nil, list)
		}
	case "messages":
		if len(os.Args) != 3 {
			die("usage: messages CONV_ID")
		}
		if d := dialDaemon(); d != nil {
			err = d.messages(os.Args[2])
		} else {
			err = withClient(ctx, nil, func(ctx context.Context, c *libgm.Client) error { return messages(ctx, c, os.Args[2]) })
		}
	case "send":
		if len(os.Args) < 4 {
			die("usage: send CONV_ID TEXT")
		}
		if d := dialDaemon(); d != nil {
			err = d.send(os.Args[2], strings.Join(os.Args[3:], " "))
		} else {
			err = withClient(ctx, nil, func(ctx context.Context, c *libgm.Client) error {
				return send(ctx, c, os.Args[2], strings.Join(os.Args[3:], " "))
			})
		}
	case "watch":
		if dialDaemon() != nil {
			die("the daemon is running; stop it first (systemctl --user stop omadora-phone)")
		}
		err = withClient(ctx, printEvent, func(ctx context.Context, c *libgm.Client) error {
			fmt.Println("watching; ^C to stop")
			<-ctx.Done()
			return nil
		})
	default:
		die("unknown command %q", os.Args[1])
	}
	if err != nil && !errors.Is(err, context.Canceled) {
		die("%v", err)
	}
}

// --------------------------------------------------------------- pairing ----

// flags parses --qr, --profile NAME and --account EMAIL.
func flags(args []string) map[string]string {
	out := map[string]string{}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--qr":
			out["qr"] = "1"
		case "--profile", "--account":
			if i+1 >= len(args) {
				die("%s needs a value", args[i])
			}
			out[strings.TrimPrefix(args[i], "--")] = args[i+1]
			i++
		default:
			die("unknown option %q", args[i])
		}
	}
	return out
}

func pairGoogle(ctx context.Context, profileName, account string, checkOnly bool) error {
	cfg := loadSetup()
	if profileName != "" {
		cfg.FirefoxProfile = profileName
	}
	if account != "" {
		cfg.Account = account
	}
	if checkOnly {
		cli, email, profile, err := googleClient(ctx, cfg.FirefoxProfile)
		if err != nil {
			return err
		}
		cli.Disconnect()
		fmt.Printf("%s (Firefox profile %s)\n", email, filepath.Base(profile))
		return nil
	}
	err := gaiaPair(ctx, cfg, func(email, profile string) {
		fmt.Printf("Pairing as %s (Firefox profile %s)\n", email, profile)
	}, func(emoji string) {
		fmt.Printf("\n    On the phone, tap   %s\n\n", emoji)
		_ = exec.Command("notify-send", "-a", "omadora-phone", "-u", "critical",
			"Pair your phone", "In Google Messages on the phone, tap "+emoji).Start()
	})
	if err != nil {
		return err
	}
	fmt.Println("paired; session saved to", sessionPath())
	return nil
}

func pairQR(ctx context.Context) error {
	cli := libgm.NewClient(libgm.NewAuthData(), nil, logger(), exhttp.SensibleClientSettings)
	done := make(chan *gmproto.PairedData, 1)
	cb := func(data *gmproto.PairedData) { done <- data }
	cli.PairCallback.Store(&cb)
	cli.SetEventHandler(func(evt any) {})
	if err := cli.FetchConfig(ctx); err != nil {
		return fmt.Errorf("fetch config: %w", err)
	}
	qr, err := cli.StartLogin(ctx)
	if err != nil {
		return fmt.Errorf("start login: %w", err)
	}
	defer cli.Disconnect()

	png := filepath.Join(os.TempDir(), fmt.Sprintf("omadora-phone-qr-%d.png", os.Getpid()))
	if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
		png = filepath.Join(dir, "omadora-phone-qr.png")
	}
	defer os.Remove(png)
	// A fresh viewer per code: imv caches an image it already has open, so
	// reloading the same path in place would keep showing the expired code.
	var viewer *exec.Cmd
	closeViewer := func() {
		if viewer != nil {
			_ = viewer.Process.Kill()
			_ = viewer.Wait()
			viewer = nil
		}
	}
	show := func(data string) error {
		if err := qrcode.WriteFile(data, qrcode.Medium, 512, png); err != nil {
			return err
		}
		closeViewer()
		viewer = exec.Command("imv", "-w", "omadora-phone pairing", png)
		if err := viewer.Start(); err != nil {
			viewer = nil
			fmt.Println("couldn't open imv; open this image yourself:", png)
		}
		return nil
	}
	defer closeViewer()
	if err := show(qr); err != nil {
		return err
	}
	fmt.Println("On the phone: Google Messages → profile picture → Device pairing → QR code scanner")

	for attempt := 0; attempt < 10; attempt++ {
		select {
		case data := <-done:
			if err := saveSession(cli.AuthData); err != nil {
				return fmt.Errorf("save session: %w", err)
			}
			fmt.Printf("paired with %s; session saved to %s\n", data.GetMobile().GetSourceID(), sessionPath())
			return nil
		case <-time.After(30 * time.Second):
			qr, err = cli.RefreshPhoneRelay()
			if err != nil {
				return fmt.Errorf("refresh QR: %w", err)
			}
			if err := show(qr); err != nil {
				return err
			}
			fmt.Println("QR code refreshed")
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return errors.New("pairing timed out")
}

// ------------------------------------------------------------ connection ----

func withClient(ctx context.Context, handler func(any), fn func(context.Context, *libgm.Client) error) error {
	ad, err := loadSession()
	if err != nil {
		return err
	}
	cli := libgm.NewClient(ad, nil, logger(), exhttp.SensibleClientSettings)
	ready := make(chan struct{}, 1)
	cli.SetEventHandler(func(evt any) {
		switch evt.(type) {
		case *gmproto.Settings:
			// The phone answers the "set active session" sent after connecting with its
			// settings (SIMs, RCS state): from then on requests reach it.
			select {
			case ready <- struct{}{}:
			default:
			}
		case *events.AuthTokenRefreshed:
			if err := saveSession(cli.AuthData); err != nil {
				fmt.Fprintln(os.Stderr, "omadora-phone: save session:", err)
			}
		}
		if handler != nil {
			handler(evt)
		}
	})
	if err := cli.FetchConfig(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "omadora-phone: fetch config:", err)
	}
	if err := cli.Connect(ctx); err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer cli.Disconnect()
	select {
	case <-ready:
	case <-time.After(20 * time.Second):
		fmt.Fprintln(os.Stderr, "omadora-phone: no settings from the phone after 20s; trying anyway")
	case <-ctx.Done():
		return ctx.Err()
	}
	_ = saveSession(cli.AuthData)
	return fn(ctx, cli)
}

func printEvent(evt any) {
	switch e := evt.(type) {
	case *libgm.WrappedMessage:
		if e.IsOld {
			return
		}
		fmt.Printf("%s  message  conv=%s from=%s status=%s  %q\n", time.Now().Format(time.TimeOnly),
			e.GetConversationID(), e.GetParticipantID(), e.GetMessageStatus().GetStatus(), text(e.Message))
	case *gmproto.Conversation:
		fmt.Printf("%s  conversation  %s %q (%s)\n", time.Now().Format(time.TimeOnly), e.GetConversationID(), e.GetName(), e.GetType())
	case *gmproto.TypingData:
		fmt.Printf("%s  typing  conv=%s %s\n", time.Now().Format(time.TimeOnly), e.GetConversationID(), e.GetType())
	case *events.PhoneNotResponding:
		fmt.Println("phone not responding")
	case *events.PhoneRespondingAgain:
		fmt.Println("phone responding again")
	}
}

// --------------------------------------------------------------- actions ----

func list(ctx context.Context, cli *libgm.Client) error {
	resp, err := cli.ListConversations(ctx, &gmproto.ListConversationsRequest{
		Count:  25,
		Folder: gmproto.ListConversationsRequest_INBOX,
	})
	if err != nil {
		return err
	}
	for _, c := range resp.GetConversations() {
		last := c.GetLatestMessage()
		fmt.Printf("%-8s %-4s %-28.28s %s  %.50q\n", c.GetConversationID(), short(c.GetType()), c.GetName(),
			time.UnixMicro(c.GetLastMessageTimestamp()).Format("01-02 15:04"), last.GetDisplayContent())
	}
	return nil
}

func messages(ctx context.Context, cli *libgm.Client, conv string) error {
	resp, err := cli.FetchMessages(ctx, conv, 15, nil)
	if err != nil {
		return err
	}
	msgs := resp.GetMessages()
	for i := len(msgs) - 1; i >= 0; i-- {
		m := msgs[i]
		who := "them"
		if m.GetMessageStatus().GetStatus() < 100 {
			who = "me"
		}
		fmt.Printf("%s  %-4s %-26s %q\n", time.UnixMicro(m.GetTimestamp()).Format("01-02 15:04"), who,
			m.GetMessageStatus().GetStatus(), text(m))
	}
	return nil
}

func send(ctx context.Context, cli *libgm.Client, convID, body string) error {
	conv, err := cli.GetConversation(ctx, convID)
	if err != nil {
		return fmt.Errorf("get conversation: %w", err)
	}
	tmp := fmt.Sprintf("tmp_%d", time.Now().UnixNano())
	req := &gmproto.SendMessageRequest{
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
	}
	resp, err := cli.SendMessage(ctx, req)
	if err != nil {
		return err
	}
	fmt.Printf("sent as %s: %s\n", short(conv.GetType()), resp.GetStatus())
	return nil
}

func text(m *gmproto.Message) string {
	var parts []string
	for _, info := range m.GetMessageInfo() {
		if c := info.GetMessageContent(); c != nil {
			parts = append(parts, c.GetContent())
		} else if media := info.GetMediaContent(); media != nil {
			parts = append(parts, "["+media.GetMimeType()+"]")
		}
	}
	return strings.Join(parts, " ")
}

func short(t gmproto.ConversationType) string {
	switch t {
	case gmproto.ConversationType_RCS:
		return "RCS"
	case gmproto.ConversationType_SMS:
		return "SMS"
	}
	return "?"
}

// setup pairs texting unless a session exists, then hands over to the panel,
// which walks through Bluetooth pairing for calls.
func setup(ctx context.Context) error {
	if _, err := os.Stat(sessionPath()); err == nil {
		fmt.Println("Texts: already paired")
	} else {
		if dialDaemon() != nil {
			fmt.Println("Texts: not paired; the panel's setup will pair them too.")
		} else if err := pairGoogle(ctx, "", "", false); err != nil {
			return err
		}
	}
	if err := exec.Command("qs", "ipc", "call", "phone", "setup").Run(); err != nil {
		fmt.Println("Open the phone panel (Super+P) → ⋯ → Set up phone to pair Bluetooth for calls.")
		return nil
	}
	fmt.Println("Continue in the phone panel to pair Bluetooth for calls.")
	return nil
}
