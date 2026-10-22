package main

// Calls through Bluetooth: the PC is a hands-free unit (HFP HF) for the phone,
// like a car kit. PipeWire's native backend does the Bluetooth part and
// exposes call control at org.pipewire.Telephony on the session bus; we
// mirror its objects as protocol events, and route call audio between the
// phone and the PC's default microphone and speakers while a call is up.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

const (
	telService   = "org.pipewire.Telephony"
	telRoot      = "/org/pipewire/Telephony"
	agIface      = "org.pipewire.Telephony.AudioGateway1"
	transIface   = "org.pipewire.Telephony.AudioGatewayTransport1"
	callIface    = "org.pipewire.Telephony.Call1"
	objMgrIface  = "org.freedesktop.DBus.ObjectManager"
	propsIface   = "org.freedesktop.DBus.Properties"
	bluezService = "org.bluez"
)

type Call struct {
	Path     string `json:"path"`
	Number   string `json:"number"`
	Name     string `json:"name"`
	State    string `json:"state"`
	Since    int64  `json:"since"`
	Incoming bool   `json:"incoming"`
}

type gateway struct {
	path, address, name, transport string
}

type calls struct {
	hub     *hub
	text    *texting
	onState func()

	mu       sync.Mutex
	bus      *dbus.Conn
	system   *dbus.Conn
	gateways []gateway
	calls    []Call
	since    map[string]Call // path -> last seen (for since/incoming)
	audio    *audioRoute
}

func newCalls(h *hub, t *texting) *calls {
	return &calls{hub: h, text: t, onState: func() {}, since: map[string]Call{}}
}

func (c *calls) run(ctx context.Context) {
	bus, err := dbus.ConnectSessionBus()
	if err != nil {
		fmt.Fprintln(os.Stderr, "calls disabled: session bus:", err)
		return
	}
	c.bus = bus
	if sys, err := dbus.ConnectSystemBus(); err == nil {
		c.system = sys
	}
	_ = bus.AddMatchSignal(dbus.WithMatchSender(telService))
	_ = bus.AddMatchSignal(dbus.WithMatchInterface("org.freedesktop.DBus"), dbus.WithMatchMember("NameOwnerChanged"),
		dbus.WithMatchArg(0, telService))
	signals := make(chan *dbus.Signal, 64)
	bus.Signal(signals)

	c.refresh()
	// Signals say *that* something changed; re-reading everything is simple
	// and there are only ever a handful of objects.
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-signals:
			// Coalesce bursts (a call state change emits several signals).
			timeout := time.After(50 * time.Millisecond)
		drain:
			for {
				select {
				case <-signals:
				case <-timeout:
					break drain
				}
			}
			c.refresh()
		case <-tick.C:
			c.refresh()
		case <-ctx.Done():
			c.stopAudio()
			return
		}
	}
}

func (c *calls) refresh() {
	objects := c.managedObjects(telRoot)
	// Each gateway is an ObjectManager of its own: its calls are listed there,
	// not at the root.
	for path, ifaces := range objects {
		if _, ok := ifaces[agIface]; ok {
			for callPath, callIfaces := range c.managedObjects(string(path)) {
				objects[callPath] = callIfaces
			}
		}
	}
	var gws []gateway
	var list []Call
	now := time.Now().UnixMilli()
	for path, ifaces := range objects {
		if props, ok := ifaces[agIface]; ok {
			gw := gateway{path: string(path), address: str(props["Address"])}
			gw.name = c.deviceName(gw.address)
			if tp, ok := ifaces[transIface]; ok {
				gw.transport = str(tp["State"])
			}
			gws = append(gws, gw)
		}
		if props, ok := ifaces[callIface]; ok {
			call := Call{
				Path:   string(path),
				Number: str(props["LineIdentification"]),
				Name:   str(props["Name"]),
				State:  str(props["State"]),
			}
			if call.State == "disconnected" {
				continue
			}
			list = append(list, call)
		}
	}
	sort.Slice(gws, func(i, j int) bool { return gws[i].path < gws[j].path })
	sort.Slice(list, func(i, j int) bool { return list[i].Path < list[j].Path })

	c.mu.Lock()
	seen := map[string]bool{}
	for i := range list {
		call := &list[i]
		seen[call.Path] = true
		prev, known := c.since[call.Path]
		call.Incoming = call.State == "incoming" || call.State == "waiting" || (known && prev.Incoming)
		call.Since = now
		if known && prev.State == call.State {
			call.Since = prev.Since
		}
		if call.Name == "" && c.text != nil {
			call.Name = c.text.nameFor(call.Number)
		}
		c.since[call.Path] = *call
	}
	for p := range c.since {
		if !seen[p] {
			delete(c.since, p)
		}
	}
	gwChanged := !sameGateways(c.gateways, gws)
	callsChanged := !sameCalls(c.calls, list)
	c.gateways, c.calls = gws, list
	c.mu.Unlock()

	if gwChanged {
		c.onState()
	}
	if callsChanged {
		fmt.Fprintf(os.Stderr, "calls: %+v\n", list)
		c.hub.event(nil, "calls", map[string]any{"calls": list})
	}
	if gwChanged {
		fmt.Fprintf(os.Stderr, "gateways: %+v\n", gws)
	}
	c.updateAudio(gws, list)
}

func (c *calls) managedObjects(path string) map[dbus.ObjectPath]map[string]map[string]dbus.Variant {
	var objects map[dbus.ObjectPath]map[string]map[string]dbus.Variant
	if err := c.bus.Object(telService, dbus.ObjectPath(path)).Call(objMgrIface+".GetManagedObjects", 0).Store(&objects); err != nil {
		return map[dbus.ObjectPath]map[string]map[string]dbus.Variant{} // service not running (no Bluetooth)
	}
	return objects
}

func sameGateways(a, b []gateway) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func sameCalls(a, b []Call) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func str(v dbus.Variant) string {
	s, _ := v.Value().(string)
	return s
}

// deviceName is the Bluetooth alias BlueZ knows the phone by.
func (c *calls) deviceName(address string) string {
	if c.system == nil || address == "" {
		return address
	}
	var objects map[dbus.ObjectPath]map[string]map[string]dbus.Variant
	if err := c.system.Object(bluezService, "/").Call(objMgrIface+".GetManagedObjects", 0).Store(&objects); err != nil {
		return address
	}
	for _, ifaces := range objects {
		if dev, ok := ifaces["org.bluez.Device1"]; ok && strings.EqualFold(str(dev["Address"]), address) {
			if alias := str(dev["Alias"]); alias != "" {
				return alias
			}
		}
	}
	return address
}

func (c *calls) bluetooth() map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.gateways) == 0 {
		return map[string]any{"connected": false, "name": "", "address": "", "audio": ""}
	}
	gw := c.gateways[0]
	return map[string]any{"connected": true, "name": gw.name, "address": gw.address, "audio": gw.transport}
}

func (c *calls) list() []Call {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.calls == nil {
		return []Call{}
	}
	return append([]Call(nil), c.calls...)
}

func (c *calls) gateway() (gateway, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.bus == nil || len(c.gateways) == 0 {
		return gateway{}, errors.New("the phone isn't connected over Bluetooth")
	}
	return c.gateways[0], nil
}

// dial places a call. Some phones answer the dial command with an error
// ("operation not allowed") yet place the call anyway, so an error only
// counts if no call shows up within a few seconds.
func (c *calls) dial(number string) error {
	number = cleanNumber(number)
	if number == "" {
		return errors.New("no number to call")
	}
	err := c.agMethod("Dial", number)
	if err == nil {
		return nil
	}
	fmt.Fprintln(os.Stderr, "dial:", err)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(300 * time.Millisecond)
		c.refresh()
		for _, call := range c.list() {
			if !call.Incoming {
				return nil
			}
		}
	}
	return fmt.Errorf("the phone didn't place the call (%v)", err)
}

func (c *calls) agMethod(method string, args ...any) error {
	gw, err := c.gateway()
	if err != nil {
		return err
	}
	if err := c.bus.Object(telService, dbus.ObjectPath(gw.path)).Call(agIface+"."+method, 0, args...).Err; err != nil {
		return friendly(err)
	}
	return nil
}

func (c *calls) callMethod(path, method string) error {
	if c.bus == nil {
		return errors.New("calls unavailable")
	}
	if !strings.HasPrefix(path, telRoot+"/") {
		return errors.New("not a call")
	}
	if err := c.bus.Object(telService, dbus.ObjectPath(path)).Call(callIface+"."+method, 0).Err; err != nil {
		return friendly(err)
	}
	return nil
}

func friendly(err error) error {
	var de dbus.Error
	if errors.As(err, &de) && len(de.Body) > 0 {
		if s, ok := de.Body[0].(string); ok && s != "" {
			return errors.New(s)
		}
	}
	return err
}

// ------------------------------------------------------------- audio ----

// audioRoute is two loopbacks while a call is up: phone → speakers and
// microphone → phone. WirePlumber doesn't link a hands-free gateway's nodes
// to anything by itself.
type audioRoute struct {
	address  string
	rx, tx   *exec.Cmd
	rxTarget string
	txTarget string
}

func (c *calls) updateAudio(gws []gateway, list []Call) {
	live := false
	for _, call := range list {
		switch call.State {
		case "active", "dialing", "alerting", "held":
			live = true
		}
	}
	if !live || len(gws) == 0 {
		c.stopAudio()
		return
	}
	gw := gws[0]
	if gw.transport != "" && gw.transport != "active" {
		// Pull the audio to us (the phone may be holding it on its earpiece).
		_ = c.bus.Object(telService, dbus.ObjectPath(gw.path)).Call(transIface+".Activate", 0).Err
	}
	source, sink := bluezNodes(gw.address)
	if source == "" || sink == "" {
		return // transport not up yet; the next refresh tries again
	}
	c.mu.Lock()
	cur := c.audio
	c.mu.Unlock()
	if cur != nil && cur.rxTarget == source && cur.txTarget == sink && alive(cur.rx) && alive(cur.tx) {
		return
	}
	c.stopAudio()
	route := &audioRoute{address: gw.address, rxTarget: source, txTarget: sink}
	route.rx = loopback("omadora-phone-rx",
		"target.object="+source+" node.dont-reconnect=true stream.dont-remix=true",
		"media.role=Communication")
	route.tx = loopback("omadora-phone-tx",
		"media.role=Communication",
		"target.object="+sink+" node.dont-reconnect=true")
	c.mu.Lock()
	c.audio = route
	c.mu.Unlock()
}

func loopback(name, captureProps, playbackProps string) *exec.Cmd {
	cmd := exec.Command("pw-loopback", "--name", name,
		"--capture-props", "node.name="+name+"-in "+captureProps,
		"--playback-props", "node.name="+name+"-out "+playbackProps)
	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "pw-loopback:", err)
		return nil
	}
	go cmd.Wait()
	return cmd
}

func alive(cmd *exec.Cmd) bool {
	return cmd != nil && cmd.Process != nil && cmd.ProcessState == nil
}

func (c *calls) stopAudio() {
	c.mu.Lock()
	route := c.audio
	c.audio = nil
	c.mu.Unlock()
	if route == nil {
		return
	}
	for _, cmd := range []*exec.Cmd{route.rx, route.tx} {
		if cmd != nil && cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}
}

// bluezNodes finds the phone's hands-free nodes: the source carries the
// caller's voice, the sink takes ours.
func bluezNodes(address string) (source, sink string) {
	out, err := exec.Command("pw-dump").Output()
	if err != nil {
		return "", ""
	}
	var objs []struct {
		Type string `json:"type"`
		Info struct {
			Props map[string]any `json:"props"`
		} `json:"info"`
	}
	if json.Unmarshal(out, &objs) != nil {
		return "", ""
	}
	for _, o := range objs {
		if o.Type != "PipeWire:Interface:Node" {
			continue
		}
		p := o.Info.Props
		addr, _ := p["api.bluez5.address"].(string)
		if !strings.EqualFold(addr, address) {
			continue
		}
		name, _ := p["node.name"].(string)
		switch p["media.class"] {
		case "Audio/Source", "Stream/Output/Audio":
			if source == "" {
				source = name
			}
		case "Audio/Sink", "Stream/Input/Audio":
			if sink == "" {
				sink = name
			}
		}
	}
	return source, sink
}
