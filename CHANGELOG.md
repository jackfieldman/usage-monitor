# Changelog

All notable changes to Usage Monitor are recorded here. Versions follow the
`CFBundleShortVersionString` in `build.sh`.

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
