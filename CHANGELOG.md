# Changelog

All notable changes to Usage Monitor are recorded here. Versions follow the
`CFBundleShortVersionString` in `build.sh`.

## 2.3

- **Smarter provider defaults.** New installs seed only providers that are
  signed in / installed on that Mac. Order is **Grok-first** on JV’s machines
  (user `jv` / personal Grok email); everyone else gets **Claude-first** when
  Claude is present, otherwise whatever they have.
- **One-time reorder** on upgrade for JV installs so Grok appears before Claude
  without wiping renames or toggles.

## 2.2

- **What's New.** Menu item with a blue **NEW** chip until you’ve opened it;
  in-app release notes for recent versions (activity click, multi-provider,
  Codex, Bar % Shows, …). Chip clears after you open the panel.

## 2.1

- **Codex provider.** Real gauges from ChatGPT’s WHAM usage endpoint (same
  source as Codex): weekly limit % + reset time, via `~/.codex/auth.json`
  (read-only). Activity from `session_index.jsonl` + live `codex` processes.
- **Cursor provider.** Add slot that opens Cursor desktop; live activity when
  the app is running (no public % API yet — bar off by default).
- **Add Provider fixed.** No more dead-end dialog: offers Codex / Cursor when
  missing, or another named Claude/Grok/… slot. **Remove** per provider.

## 2.0

- **Multi-provider slots.** Claude and Grok are configurable slots with personal
  names (“Claude Work”, “Grok Personal”), letter badges (C / G / …), and
  independent toggles for enabled / show in menu bar / show activity. **Add
  Provider…** for extra slots; the architecture is N-provider ready.
- **Menu Bar Layout.** Per-provider (letter + %), all gauges, or highest only —
  pick what the glyph packs.
- **Clickable activity.** Activity rows open the live host: Terminal tab (by
  TTY), iTerm session, Warp/Ghostty/Orbit/Claude desktop when that process is
  the parent, else the project folder. Process-aware via PID + cwd matching.
- **Two-line activity rows.** Dark header = letter + currently-working-on
  title (Claude `lastPrompt` / Grok session summary); light subline =
  project · branch · Live/time · tokens.

## 1.9

- **Grok usage.** Shows Grok credit / product limits alongside Claude: reads the
  Grok CLI session from `~/.grok/auth.json` (read-only — never refreshes the
  token) and polls the same billing endpoint Grok's `/usage` uses. Menu lists
  overall **Grok** plus any product rows that report a percent (Build, API,
  Chat, Imagine). The menu-bar glyph includes the overall Grok gauge with the
  Claude ones so the bar stays compact.
- **Grok activity.** New menu section lists live/recent Grok CLI sessions from
  the local registry (`active_sessions.json` + session summaries) — no chat
  content, no network.
- **Either provider is enough.** Setup and the menu work with Claude only,
  Grok only, or both. Onboarding covers both sign-ins; the Anthropic Admin
  key remains optional Claude API spend.

## 1.8

- **Claude Code activity.** New menu section shows which Claude Code CLI
  sessions (across terminals/projects/worktrees) are active or recently
  active, with a live/idle indicator and cumulative tokens sent/received per
  session. Reads only the local transcripts Claude Code already writes to
  `~/.claude/projects` — no network, no proxy, no message content, just
  per-turn token counts and metadata (project, git branch, timestamps).

## 1.7

- **Horizontal bar chart.** New **Bar Chart (Horizontal)** icon shape — one
  left-to-right bar per gauge, stacked; the sideways twin of the vertical bars.
- **Density.** New **Compact / Comfortable** menu setting: Comfortable widens
  the charts (bars, batteries) a touch for readability; Compact keeps the
  classic tight footprint.
- **One-click and automatic updates.** When the daily check finds a new
  release, the app now posts a notification (once per version) and the menu
  offers **Update to x.y Now** — it downloads the release zip, verifies the
  code signature is from the same Developer ID team, swaps itself in place,
  and relaunches. Turn on **Install Updates Automatically** to skip the ask.
  Any verification or download failure leaves the current install untouched
  and opens the release page instead.

## 1.6

- **"%" beside the menu-bar number** — the glyph now reads e.g. "52%" instead
  of a bare "52", in every shape (bars, rings, battery, consolidated).
- **Update notices.** Once a day the app asks GitHub for the latest release
  (an anonymous HTTP request — no identifiers, no telemetry) and, when a newer
  version exists, shows an **Update Available — x.y…** menu item that opens the
  download page.
- **Subscribe to Updates…** menu item — join the release-announcement
  newsletter.
- **Join the Community…** menu item — opens the project's GitHub Discussions.

## 1.5

- **The app no longer refreshes the login token — fixes Claude Code getting
  logged out.** Refreshing rotated the refresh token the app shares with
  Claude Code; when both refreshed, the OAuth server's reuse detection could
  revoke the whole grant, signing Claude Code out. The credential is now
  strictly read-only: an expired token shows "Login token expired — Claude
  Code renews it on next use" (keeping the last good data), and the gauges
  recover automatically on the poll after you next use Claude Code.

## 1.4.1

- Enabling notifications now posts a one-time confirmation ("Notifications are
  on…") so you can see they work — once per enable.

## 1.4

- **Defaults changed** to **Bar chart** shape + **Greyscale** style — the most
  menu-bar-native look. (Your existing choice is preserved if you'd set one.)
- **Number Shows** menu — pick which limit's percentage appears beside the icon
  (highest by default, or a specific one like Session or a model).
- **Notifications no longer repeat** across relaunches: the "already alerted"
  state is persisted, so a limit stuck at 100% won't re-alert every launch.
  Turning notifications off now also clears any stacked banners.
- App icon re-registered so it resolves for notifications and Finder.

## 1.3

- **App icon.** A proper icon — a battery gauge with a green→amber→red charge on
  a slate squircle — now ships in the bundle, so it appears in Finder, the
  setup window, and macOS notifications. Regenerate it with
  `swift docs/make-icon.swift <size> <out.png>`.

## 1.2

- **Limit notifications.** New **Notify near a limit (80%)** menu toggle posts a
  macOS notification the moment any limit first crosses into the red zone —
  once per crossing, re-armed after it resets below 80%.
- **Hardened Admin-key storage.** The optional Admin API key is now written with
  the in-process Keychain (`SecItem`) APIs instead of shelling out to
  `security`, so the key is never passed as a command-line argument.
- **Reliability fixes** from a full code review of the cost/onboarding code:
  a valid Admin key is no longer rejected on a transient network error; a cost
  error is surfaced even when a previous value exists (no more silently stale
  spend); the "Scan this Mac" step can no longer hang on a slow shell profile;
  and Keychain reads no longer spawn a subprocess on the main thread each poll.
- **Internal:** deduplicated the HTTP wrapper, centralised the 50/80 severity
  thresholds, fixed a latent retain cycle, and stopped rebuilding the menu on
  every poll (it now rebuilds on open).

## 1.1

- **API dollar spend (optional).** Add an Admin API key and the menu shows your
  month-to-date pay-as-you-go API cost, read from the Console cost report.
- **Reworked, secure onboarding.** A second setup section adds the API key by
  scanning your Mac for an existing key (shown masked) or typing one into a
  hidden field; the key is verified before saving and stored only in the
  Keychain.
- **Sharper, larger menu-bar glyphs** with selectable **Icon Shape**
  (Battery / Bar chart / Rings), **Icon Style** (Colour / Greyscale / System
  battery), and a **Consolidated Icon** single-glyph mode.
- Fixed the disabled **Quit** menu item.

## 1.0

- First public release: a signed & notarized macOS menu-bar app showing Claude
  usage limits as battery-style gauges (session, all-models weekly, per-model
  weekly), with first-run onboarding and **Open at Login**.
