package main

import (
	"bufio"
	"database/sql"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	_ "modernc.org/sqlite"
)

// Google account pairing authenticates with the Google session of a browser
// that's signed in and has opened messages.google.com/web once.
var googleCookies = map[string]string{
	"OSID":             "messages.google.com",
	"SID":              ".google.com",
	"HSID":             ".google.com",
	"SSID":             ".google.com",
	"APISID":           ".google.com",
	"SAPISID":          ".google.com",
	"__Secure-1PSIDTS": ".google.com",
}

var requiredCookies = []string{"SID", "HSID", "OSID", "SSID", "APISID", "SAPISID"}

// firefoxProfile finds a profile by name (as in profiles.ini, or a directory
// path), or else the one Firefox launches by default: the install's Default=
// in installs.ini, else the newest *.default* profile.
func firefoxProfile(name string) (string, error) {
	home, _ := os.UserHomeDir()
	xdg := os.Getenv("XDG_CONFIG_HOME")
	if xdg == "" {
		xdg = filepath.Join(home, ".config")
	}
	roots := []string{filepath.Join(xdg, "mozilla/firefox"), filepath.Join(home, ".mozilla/firefox")}
	if name != "" {
		return namedProfile(roots, name)
	}
	for _, root := range roots {
		if f, err := os.Open(filepath.Join(root, "installs.ini")); err == nil {
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				if rel, ok := strings.CutPrefix(strings.TrimSpace(sc.Text()), "Default="); ok {
					p := filepath.Join(root, rel)
					if _, err := os.Stat(filepath.Join(p, "cookies.sqlite")); err == nil {
						f.Close()
						return p, nil
					}
				}
			}
			f.Close()
		}
		matches, _ := filepath.Glob(filepath.Join(root, "*.default*", "cookies.sqlite"))
		var best string
		var bestTime int64
		for _, m := range matches {
			if st, err := os.Stat(m); err == nil && st.ModTime().UnixNano() > bestTime {
				best, bestTime = filepath.Dir(m), st.ModTime().UnixNano()
			}
		}
		if best != "" {
			return best, nil
		}
	}
	return "", fmt.Errorf("no Firefox profile with cookies found")
}

func namedProfile(roots []string, name string) (string, error) {
	if st, err := os.Stat(name); err == nil && st.IsDir() {
		return name, nil
	}
	for _, root := range roots {
		f, err := os.Open(filepath.Join(root, "profiles.ini"))
		if err != nil {
			continue
		}
		var section map[string]string
		var sections []map[string]string
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if strings.HasPrefix(line, "[") {
				section = map[string]string{}
				sections = append(sections, section)
			} else if k, v, ok := strings.Cut(line, "="); ok && section != nil {
				section[k] = v
			}
		}
		f.Close()
		for _, s := range sections {
			if s["Name"] == name && s["Path"] != "" {
				if s["IsRelative"] == "1" {
					return filepath.Join(root, s["Path"]), nil
				}
				return s["Path"], nil
			}
		}
	}
	return "", fmt.Errorf("no Firefox profile named %q (create one with: firefox -CreateProfile %s)", name, name)
}

// firefoxCookies reads the Google cookies from a copy of the profile's cookie
// database (Firefox keeps the original locked while it runs).
func firefoxCookies(profile string) (map[string]string, error) {
	tmp, err := os.MkdirTemp("", "omadora-phone-cookies-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)
	for _, suffix := range []string{"", "-wal"} {
		if err := copyFile(filepath.Join(profile, "cookies.sqlite"+suffix), filepath.Join(tmp, "cookies.sqlite"+suffix)); err != nil && suffix == "" {
			return nil, err
		}
	}
	db, err := sql.Open("sqlite", "file:"+filepath.Join(tmp, "cookies.sqlite")+"?mode=ro")
	if err != nil {
		return nil, err
	}
	defer db.Close()

	cookies := map[string]string{}
	for name, host := range googleCookies {
		var value string
		err := db.QueryRow(`SELECT value FROM moz_cookies WHERE name = ? AND host = ?
			ORDER BY lastAccessed DESC LIMIT 1`, name, host).Scan(&value)
		if err == nil && value != "" {
			cookies[name] = value
		}
	}
	var missing []string
	for _, name := range requiredCookies {
		if cookies[name] == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("Firefox (%s) is missing Google cookies %s: sign in to Google in Firefox and open messages.google.com/web once",
			filepath.Base(profile), strings.Join(missing, ", "))
	}
	return cookies, nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
