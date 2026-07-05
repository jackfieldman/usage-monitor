# Usage Monitor

A tiny macOS **menu-bar app** that shows your Claude usage limits as
battery-style gauges — session, all-models weekly, and per-model weekly —
so you can see how close you are to your limits without opening the app.

<!-- screenshot placeholder: three mini batteries in the menu bar -->

Green under 50%, amber 50–79%, red at 80%+. Click the item for a labelled
breakdown with reset times, a **Refresh now** button, and **Open at Login**.

## Requirements

- macOS 13 (Ventura) or later
- **Claude Code** installed and signed in (a Pro or Max subscription). The app
  reuses the login Claude Code already stores — there's nothing extra to log in to.
- To build from source: Xcode Command Line Tools (`xcode-select --install`).

## Install

### Build from source

```sh
git clone <repo-url> usage-monitor
cd usage-monitor
./build.sh
open UsageMonitor.app
```

Then use **Open at Login** in the menu to have it start automatically. Move
`UsageMonitor.app` to `/Applications` first if you want it to live there.

### From a downloaded build

Because the app isn't signed by an identified Apple developer, macOS
Gatekeeper quarantines it on first open. Clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /path/to/UsageMonitor.app
open /path/to/UsageMonitor.app
```

(If the download *is* a signed & notarized build, just double-click it.)

## How it works

The app reads the OAuth token Claude Code keeps in your macOS Keychain
(`Claude Code-credentials`) and calls the same endpoint the Claude Code
`/usage` panel uses (`GET https://api.anthropic.com/api/oauth/usage`). It maps
the response's `limits` array to the gauges, polls every 5 minutes, and
refreshes the token when it's near expiry (writing the new token back to the
same Keychain item, so Claude Code stays in sync).

### Privacy

Your token and usage data never leave your Mac except in the request to
Anthropic's own server — the same server Claude Code already talks to. There
is no third-party server, telemetry, or analytics.

### ⚠️ Unofficial

This is not affiliated with or endorsed by Anthropic. It relies on an
**undocumented** internal endpoint that Anthropic can change or remove at any
time, which would stop the gauges from updating until the app is updated. It
also isn't an investment/billing tool — it only mirrors what `/usage` shows.

## Uninstall

```sh
pkill -x UsageMonitor          # quit it
# turn off "Open at Login" from the menu first, or:
rm -rf /path/to/UsageMonitor.app
```

The app never installs background services or launch agents; removing the
`.app` is a complete uninstall. It does not delete or alter your Keychain
login (it only reads it and refreshes the token, exactly as Claude Code does).

## Colours

| Colour | Meaning        |
|--------|----------------|
| green  | under 50% used |
| amber  | 50–79% used    |
| red    | 80%+ used      |

## License

MIT — see [LICENSE](LICENSE).
