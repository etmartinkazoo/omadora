package main

// Google account pairing, shared by `omadora-phone pair` and the panel's
// "Set up phone" flow (the daemon's pairMessages command). The Firefox profile
// and account used last time are remembered, so setup needs no options.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"go.mau.fi/util/exhttp"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
)

type setupConfig struct {
	FirefoxProfile string `json:"firefoxProfile"` // a profile name or path ("" = Firefox's default)
	Account        string `json:"account"`        // refuse to pair any other Google account ("" = any)
}

func setupPath() string { return filepath.Join(stateDir(), "setup.json") }

func loadSetup() setupConfig {
	var c setupConfig
	if data, err := os.ReadFile(setupPath()); err == nil {
		_ = json.Unmarshal(data, &c)
	}
	return c
}

func saveSetup(c setupConfig) error {
	if err := os.MkdirAll(stateDir(), 0o700); err != nil {
		return err
	}
	data, _ := json.MarshalIndent(c, "", "  ")
	return os.WriteFile(setupPath(), append(data, '\n'), 0o600)
}

// googleClient prepares a pairing client from the Firefox profile's Google
// session and reports which account it is.
func googleClient(ctx context.Context, profileName string) (cli *libgm.Client, email, profile string, err error) {
	profile, err = firefoxProfile(profileName)
	if err != nil {
		return nil, "", "", err
	}
	cookies, err := firefoxCookies(profile)
	if err != nil {
		return nil, "", "", err
	}
	ad := libgm.NewAuthData()
	ad.SetCookies(cookies)
	cli = libgm.NewClient(ad, nil, logger(), exhttp.SensibleClientSettings)
	cli.SetEventHandler(func(evt any) {})
	if err := cli.FetchConfig(ctx); err != nil {
		return nil, "", "", fmt.Errorf("fetch config: %w", err)
	}
	email = cli.Config.GetDeviceInfo().GetEmail()
	if email == "" {
		return nil, "", "", fmt.Errorf("Google didn't accept the session in Firefox profile %s: open messages.google.com/web there, sign in, and try again",
			filepath.Base(profile))
	}
	return cli, email, profile, nil
}

// gaiaPair pairs through the Google account, calling onAccount once the
// account is known and onEmoji with the emoji to tap on the phone. On success
// the session and the profile/account used are saved.
func gaiaPair(ctx context.Context, cfg setupConfig, onAccount func(email, profile string), onEmoji func(string)) error {
	cli, email, profile, err := googleClient(ctx, cfg.FirefoxProfile)
	if err != nil {
		return err
	}
	defer cli.Disconnect()
	if cfg.Account != "" && !strings.EqualFold(email, cfg.Account) {
		return fmt.Errorf("Firefox profile %s is signed in to Google as %s, not %s", filepath.Base(profile), email, cfg.Account)
	}
	onAccount(email, filepath.Base(profile))
	err = cli.DoGaiaPairing(ctx, onEmoji)
	switch {
	case err == nil:
	case errors.Is(err, libgm.ErrNoDevicesFound):
		return errors.New("no phone found on this Google account: is Google Messages signed in to the same account?")
	case errors.Is(err, libgm.ErrIncorrectEmoji):
		return errors.New("the wrong emoji was tapped; try again")
	case errors.Is(err, libgm.ErrPairingTimeout):
		return errors.New("timed out waiting for the phone; try again")
	default:
		return err
	}
	if err := saveSession(cli.AuthData); err != nil {
		return fmt.Errorf("save session: %w", err)
	}
	if cfg.Account == "" {
		cfg.Account = email
	}
	_ = saveSetup(cfg)
	return nil
}
