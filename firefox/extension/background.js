"use strict";

// omadora Theme
// ---------------
// omadora-firefox-host (a native messaging host) sends the current theme's
// rendered firefox-theme.json when we connect, and again every time
// `omadora-theme set` changes it. Each one is applied with the theme API,
// which covers the browser chrome, menus, sidebar, the new tab page and the
// light/dark preference web pages see.
//
// The background page is persistent (MV2) so the port stays open; if the host
// exits or is missing, we reconnect with backoff.

const HOST = "omadora_theme";
let delay = 1000;

function connect() {
  let port;
  try {
    port = browser.runtime.connectNative(HOST);
  } catch (error) {
    console.error("[omadora-theme] can't start the native host:", error);
    return retry();
  }
  port.onMessage.addListener(async (theme) => {
    delay = 1000;
    if (!theme || typeof theme.colors !== "object") {
      return;
    }
    try {
      await browser.theme.update({ colors: theme.colors, properties: theme.properties || {} });
    } catch (error) {
      console.error("[omadora-theme] theme.update failed:", error);
    }
  });
  port.onDisconnect.addListener((p) => {
    if (p.error) {
      console.warn("[omadora-theme] native host disconnected:", p.error.message);
    }
    retry();
  });
}

function retry() {
  setTimeout(connect, delay);
  delay = Math.min(delay * 2, 60000);
}

connect();
