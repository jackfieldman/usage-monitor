<p align="center"><img src="docs/icon.png" width="128" alt="Usage Monitor icon"></p>

# Usage Monitor

A tiny macOS **menu-bar app** that shows your Claude usage limits as
battery-style gauges — session, all-models weekly, and per-model weekly —
so you can see how close you are to your limits without opening the app.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/icons-dark.png">
    <img alt="The menu-bar gauges, and the icon shape and style options" src="docs/icons-light.png" width="720">
  </picture>
</p>

Green under 50%, amber 50–79%, red at 80%+. Click the item for a labelled
breakdown with reset times, a **Refresh now** button, and **Open at Login**.

The icon is configurable from that menu:

- **Icon Shape** — **Bar chart** (default), **Battery**, or **Rings**.
- **Icon Style** — **Greyscale** (default; level as lightness), **Colour**
  (traffic-light), or **System Battery** (monochrome until the red zone).
- **Consolidated Icon** — for the battery shape, stacks all three gauges in one
  glyph, to save menu-bar space.
- **Number Shows** — choose which limit's percentage sits beside the icon: the
  highest by default, or a specific one (Session, All models, or a model).

Each gauge's number is the percent used; the shapes and styles above all show
the same three example gauges (21% / 58% / 93%).

Turn on **Notify near a limit (80%)** in the menu to get a macOS notification
the moment any limit first crosses into the red zone — so you hear about it
without watching the menu bar. It alerts once per crossing and re-arms after the
limit resets below 80%.

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

On first launch (or any time it's not signed in) a **setup window** walks you
through installing Claude Code and signing in. The same window has an optional
**API dollar spend** section — add an Admin API key and the menu also shows
your month-to-date pay-as-you-go API cost. You can either let the app **scan
your Mac** for a key it already finds (shell profiles, the `ant` CLI config),
or **type one in confidentially** (hidden field). The key is verified against
the cost endpoint before it's saved, stored only in your macOS Keychain, and
used solely to read your cost report. Reopen setup any time from the menu-bar
**Set Up…** item.

Then use **Open at Login** in the menu to have it start automatically. Move
`UsageMonitor.app` to `/Applications` first if you want it to live there.

### From a downloaded build

A signed & notarized build (from the Releases page) opens with a normal
double-click. If you built or received an **unsigned/ad-hoc** copy, macOS
Gatekeeper quarantines it on first open — clear the flag once:

```sh
xattr -dr com.apple.quarantine /path/to/UsageMonitor.app
open /path/to/UsageMonitor.app
```

## How it works

**Gauges (subscription usage).** The app reads the OAuth token Claude Code
keeps in your macOS Keychain (`Claude Code-credentials`) and calls the same
endpoint the Claude Code `/usage` panel uses
(`GET https://api.anthropic.com/api/oauth/usage`). It maps the response's
`limits` array to the gauges, polls every 5 minutes, and refreshes the token
when it's near expiry (writing the new token back to the same Keychain item, so
Claude Code stays in sync).

**Dollar spend (optional, API only).** If you add an Admin API key, the app
calls the Console Admin API
(`GET https://api.anthropic.com/v1/organizations/cost_report`) once per poll,
sums the current month's buckets, and shows the total in the menu. This is
separate from subscription usage — it reflects metered pay-as-you-go API
billing, so it only shows anything if you have an API organization. The Admin
key is stored in its own Keychain item (`UsageMonitor-admin-key`), entered via
a hidden field or picked from a masked list of keys already on your Mac, and
sent only to Anthropic over HTTPS.

### Privacy

Your token and usage data never leave your Mac except in the request to
Anthropic's own server — the same server Claude Code already talks to. There
is no third-party server, telemetry, or analytics. If you add an Admin API key,
it lives only in your macOS Keychain, is never written to disk or logged, and
is sent only to Anthropic over HTTPS to read your cost report.

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
