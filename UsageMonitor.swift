// UsageMonitor — a self-contained macOS menu-bar app that shows multi-provider
// AI usage limits as tiny battery gauges. No external dependencies.
//
// PUBLIC PRODUCT VOICE (non-negotiable):
// - Never ship maintainer-specific copy (names, “my Mac”, private emails, etc.).
// - Release notes, UI strings, and defaults must read as a professional public app.
// - Prefer “this Mac” / “you” over any personal branding in user-visible text.
//
// Providers are configurable slots (Claude, Grok, …) with custom names and
// letter badges. Credentials are always read-only — each CLI owns refresh.
//
// Build:  ./build.sh      Run:  open UsageMonitor.app
import AppKit
import CoreWLAN
import IOKit.pwr_mgt
import ServiceManagement
import Security
import UserNotifications

// MARK: - Model

struct Gauge { let label: String; let percent: Double; let sub: String }

/// Built-in adapter kinds. New kinds plug in here; the UI is N-slot generic.
enum ProviderKind: String, CaseIterable, Codable {
    case claude, grok, codex, cursor
    var defaultName: String {
        switch self {
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
    var defaultLetter: String {
        switch self {
        case .claude: return "C"
        case .grok: return "G"
        case .codex: return "X"
        case .cursor: return "U"
        }
    }
    var processNames: [String] {
        switch self {
        case .claude: return ["claude"]
        case .grok: return ["grok"]
        case .codex: return ["codex"]
        case .cursor: return ["Cursor"]
        }
    }
    /// True when this kind can fetch subscription gauges (vs activity/open only).
    var supportsUsage: Bool {
        switch self {
        case .claude, .grok, .codex: return true
        case .cursor: return false   // no stable public usage endpoint yet
        }
    }
}

/// One user-facing provider slot — rename, badge letter, bar/menu toggles.
struct ProviderConfig: Codable, Equatable {
    var id: String
    var kind: ProviderKind
    var displayName: String
    var letter: String
    var enabled: Bool
    var showInMenuBar: Bool
    var showActivity: Bool

    static func make(_ kind: ProviderKind, name: String? = nil, letter: String? = nil) -> ProviderConfig {
        ProviderConfig(
            id: kind.rawValue,
            kind: kind,
            displayName: name ?? kind.defaultName,
            letter: (letter ?? kind.defaultLetter).uppercased(),
            enabled: true,
            showInMenuBar: true,
            showActivity: true)
    }
}

/// Live gauge snapshot for one provider slot.
struct ProviderGauges {
    let config: ProviderConfig
    let gauges: [Gauge]
}

/// Menu-bar drawing unit: letter badge + one or more gauges for a provider.
struct IconCluster {
    let letter: String
    let name: String
    let gauges: [Gauge]
}

/// How the menu-bar packs multiple providers.
enum MenuBarLayout: String, CaseIterable {
    case perProvider   // letter + highest% per shown provider (default)
    case allGauges     // every gauge (Claude session/weekly/…) + Grok primary
    case highestOnly   // single global highest across shown providers
    var title: String {
        switch self {
        case .perProvider: return "Per Provider (letter + %)"
        case .allGauges: return "All Gauges"
        case .highestOnly: return "Highest Only"
        }
    }
}

/// Unified activity row (any provider). Click opens the host terminal/app.
struct ActivitySession {
    let id: String
    let providerId: String
    let providerLetter: String
    let providerName: String
    let project: String
    let cwd: String?
    let branch: String?
    /// Dark header line — "currently working on" / session title.
    let title: String?
    let tokensIn: Int?
    let tokensOut: Int?
    let model: String?
    let lastActivity: Date
    let live: Bool
    let pid: Int?
    let tty: String?
}

/// NSMenuItem.representedObject must be a class — Swift structs often fail
/// `as? ActivitySession` on click, so the action no-ops. This box fixes that.
final class ActivitySessionBox: NSObject {
    let session: ActivitySession
    init(_ session: ActivitySession) { self.session = session }
}

// MARK: - What's New (in-app release notes + blue “NEW” chips)

enum WhatsNew {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Menu / product features with the version they first shipped.
    /// Chips appear when the user’s baseline is older than `introduced`.
    enum Feature: String, CaseIterable {
        case terminalSessions
        case multiProvider
        case barPercent
        case menuBarLayout
        case codexCursor
        case whatsNewPanel
        case laptopMode

        /// First app version that included this surface.
        var introduced: String {
            switch self {
            case .terminalSessions: return "2.0"   // clickable activity / sessions
            case .multiProvider: return "2.0"
            case .barPercent: return "2.0"
            case .menuBarLayout: return "2.0"
            case .codexCursor: return "2.1"
            case .whatsNewPanel: return "2.2"
            case .laptopMode: return "2.5"
            }
        }
    }

    /// Newest first. Keep in sync with CHANGELOG.md for the current series.
    /// PUBLIC VOICE: no maintainer names, private machines, or insider jokes.
    static let releases: [(version: String, title: String, bullets: [String])] = [
        ("2.6.1", "Open the real terminal session", [
            "Clicking Active AI terminals selects the existing Terminal/iTerm tab by TTY",
            "Never launches a new Terminal window for a process that is already running",
        ]),
        ("2.6", "Smarter updates", [
            "Checks for new releases ~4 times per day",
            "When an update is waiting: “Update available” scrolls across the menu bar once an hour",
            "Updates menu: install now, auto-update, skip this version, skip all, pause for days/weeks",
        ]),
        ("2.5.2", "Caffeinate Mode & polish", [
            "Caffeinate Mode: keep desktops and laptops awake; laptop lid-shut option",
            "Glowing menu-bar cup while active — click for a reminder",
            "Active AI desktops: only real apps (no false ChatGPT Live)",
            "Tighter menu-bar gauges — less dead space next to G:/C:",
            "Horizontal bars: limited to 1 provider (clearer wording)",
        ]),
        ("2.4.1", "Closed Lid Mode & Active AI", [
            "Closed Lid Mode: amber Active / grey Inactive on the menu row",
            "Active AI terminals (live only) and Active AI desktops (Claude, ChatGPT, …)",
            "Hotspot from known networks first; Wi‑Fi scan only after consent (no admin)",
            "Horizontal bars greyed when more than one menu-bar cluster is shown",
        ]),
        ("2.4", "Closed Lid Mode (introduced)", [
            "Join a favorite hotspot and keep the Mac awake with the lid closed",
            "No admin password — Location prompt only if you choose to scan Wi‑Fi",
        ]),
        ("2.3.4", "Terminal sessions reliability", [
            "Sessions appear immediately (Grok first; Claude loads without blocking)",
            "Menu no longer freezes while scanning transcripts",
        ]),
        ("2.3.3", "Public polish", [
            "Neutral product copy in What’s New and release notes",
            "Same smart defaults for every user",
        ]),
        ("2.3", "Smarter defaults", [
            "Seeds providers from what you actually use (signed-in CLIs)",
            "Stable order: Claude, Grok, Codex, Cursor — only kinds present on this Mac",
        ]),
        ("2.2", "What's New polish", [
            "Blue NEW chip on What’s New until you’ve opened it",
            "In-app release notes window (this panel)",
        ]),
        ("2.1", "Codex, Cursor & Add Provider", [
            "Codex gauges from ChatGPT usage (weekly % + reset)",
            "Cursor slot — open the desktop app; live when running",
            "Add Provider offers real adapters (no dead-end dialog)",
            "Remove a provider from its submenu",
        ]),
        ("2.0", "Multi-provider & clickable activity", [
            "Rename providers and letter badges (C: / G: / …)",
            "Menu bar layout: per-provider, all gauges, or highest",
            "Click an activity row to open its Terminal tab / app",
            "Bar % Shows — pick which limit each letter displays",
        ]),
        ("1.9", "Grok usage", [
            "Grok credit & product limits in the menu bar",
            "Grok activity from local sessions",
            "Works with Claude only, Grok only, or both",
        ]),
    ]

    private static let seenKey = "whatsNewSeenVersion"
    private static let lastLaunchKey = "lastLaunchedVersion"
    private static let upgradeFromKey = "upgradeFromVersion"

    static var seenVersion: String {
        get { UserDefaults.standard.string(forKey: seenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    /// Call once at launch. Remembers the previous install version for “new since last time”.
    static func recordLaunch() {
        let current = appVersion
        let prior = UserDefaults.standard.string(forKey: lastLaunchKey) ?? ""
        if prior != current {
            // Empty prior = first install; keep upgradeFrom empty so we don’t spam every chip.
            UserDefaults.standard.set(prior, forKey: upgradeFromKey)
        }
        UserDefaults.standard.set(current, forKey: lastLaunchKey)
    }

    /// Version the user has already acknowledged via What’s New (or empty).
    /// Falls back to the version they upgraded from so chips survive until they open What’s New.
    static var baselineVersion: String {
        if !seenVersion.isEmpty { return seenVersion }
        return UserDefaults.standard.string(forKey: upgradeFromKey) ?? ""
    }

    /// True if this release (or feature intro version) is newer than the user’s baseline.
    static func isNew(since introduced: String) -> Bool {
        let base = baselineVersion
        if base.isEmpty { return false }   // first install: only use What’s New entry, not every row
        return isNewer(introduced, than: base)
    }

    static func isNew(_ feature: Feature) -> Bool { isNew(since: feature.introduced) }

    /// Show the blue chip on What’s New until they open it for this version.
    static var hasUnseen: Bool {
        seenVersion != appVersion && (!baselineVersion.isEmpty || seenVersion.isEmpty)
    }

    static func markSeen() {
        seenVersion = appVersion
        UserDefaults.standard.set(appVersion, forKey: upgradeFromKey)
    }

    /// Numeric dotted-version compare: "2.3.4" > "2.3".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0, y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static var chipBlue: NSColor {
        NSColor(srgbRed: 0.20, green: 0.48, blue: 0.98, alpha: 1)
    }
    static var chipBlueSoft: NSColor {
        NSColor(srgbRed: 0.20, green: 0.48, blue: 0.98, alpha: 0.14)
    }
    static var chipBlueLight: NSColor {
        NSColor(srgbRed: 0.40, green: 0.65, blue: 1.0, alpha: 1)
    }

    /// Tiny pill badge. `light: true` = softer fill for inline menu “feature lights”.
    static func newChipImage(height: CGFloat = 16, light: Bool = false) -> NSImage {
        let text = "NEW"
        let font = NSFont.systemFont(ofSize: max(9, height * 0.58), weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: light ? chipBlue : NSColor.white,
            .kern: 0.4,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let textSize = s.size()
        let padX: CGFloat = 6
        let w = ceil(textSize.width) + padX * 2
        let h = height
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let rect = NSRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: (h - 1) / 2, yRadius: (h - 1) / 2)
            if light {
                chipBlueSoft.setFill()
                path.fill()
                chipBlue.setStroke()
            } else {
                chipBlue.setFill()
                path.fill()
                chipBlueLight.setStroke()
            }
            path.lineWidth = 1
            path.stroke()
            let ty = ((h - textSize.height) / 2).rounded() - 0.5
            s.draw(at: NSPoint(x: padX, y: ty))
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Attach a light NEW chip when this feature is new since the user’s baseline.
    static func applyFeatureChip(_ item: NSMenuItem, _ feature: Feature) {
        guard isNew(feature) else { return }
        item.image = newChipImage(height: 14, light: true)
        let tip = item.toolTip ?? item.title
        item.toolTip = tip + "\nNew since your previous version"
    }
}

/// Lightweight panel listing recent releases. Marks the current version seen on open.
final class WhatsNewController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func present() {
        WhatsNew.markSeen()
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let width: CGFloat = 420
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        win.title = "What's New"
        win.delegate = self
        win.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: .zero)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 16, right: 22)

        // Header: app icon + title + blue NEW chip
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let title = NSTextField(labelWithString: "Usage Monitor \(WhatsNew.appVersion)")
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let chip = NSImageView(image: WhatsNew.newChipImage(height: 18))
        chip.imageScaling = .scaleNone

        let titleRow = NSStackView(views: [title, chip])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .centerY

        let subtitle = NSTextField(labelWithString: "Recent highlights — click activity rows to jump to terminals.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = width - 44

        let headingCol = NSStackView(views: [titleRow, subtitle])
        headingCol.orientation = .vertical
        headingCol.alignment = .leading
        headingCol.spacing = 4

        let heading = NSStackView(views: [icon, headingCol])
        heading.orientation = .horizontal
        heading.spacing = 12
        heading.alignment = .centerY
        stack.addArrangedSubview(heading)

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: width - 44).isActive = true
        stack.addArrangedSubview(rule)

        for rel in WhatsNew.releases {
            // Light up any release the user hasn't lived through yet.
            let highlight = WhatsNew.isNew(since: rel.version)
                || rel.version == WhatsNew.appVersion && WhatsNew.hasUnseen
            stack.addArrangedSubview(releaseBlock(rel.version, rel.title, rel.bullets, highlight: highlight))
        }

        let gotIt = NSButton(title: "Got it", target: self, action: #selector(close))
        gotIt.bezelStyle = .rounded
        gotIt.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), gotIt])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: width - 44).isActive = true
        stack.addArrangedSubview(footer)

        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        scroll.documentView = doc

        // Force layout so scroll document gets a real height.
        doc.layoutSubtreeIfNeeded()
        let contentH = stack.fittingSize.height
        doc.frame = NSRect(x: 0, y: 0, width: width, height: max(contentH, 100))

        let content = NSView()
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: min(520, max(320, contentH + 8))),
        ])
        win.contentView = content
        win.setContentSize(NSSize(width: width, height: min(520, max(320, contentH + 8))))
        self.window = win
    }

    private func releaseBlock(_ version: String, _ title: String, _ bullets: [String], highlight: Bool) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        if highlight {
            card.layer?.backgroundColor = WhatsNew.chipBlueSoft.cgColor
            card.layer?.borderWidth = 1
            card.layer?.borderColor = WhatsNew.chipBlue.withAlphaComponent(0.45).cgColor
        } else {
            card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
        }

        let ver = NSTextField(labelWithString: "v\(version)")
        ver.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        ver.textColor = highlight ? WhatsNew.chipBlue : .secondaryLabelColor

        var headerViews: [NSView] = [ver]
        if highlight {
            let chip = NSImageView(image: WhatsNew.newChipImage(height: 15))
            headerViews.append(chip)
        }
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        headerViews.append(name)

        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY

        var rows: [NSView] = [header]
        for b in bullets {
            let line = NSTextField(wrappingLabelWithString: "·  \(b)")
            line.font = .systemFont(ofSize: 12)
            line.textColor = .labelColor
            line.preferredMaxLayoutWidth = 360
            rows.append(line)
        }
        let inner = NSStackView(views: rows)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 5
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.widthAnchor.constraint(equalToConstant: 376),
        ])
        return card
    }

    @objc func close() {
        window?.close()
    }
}

enum IconShape: String, CaseIterable {
    case battery, bars, hbars, rings
    var title: String {
        switch self {
        case .battery: return "Battery"
        case .bars: return "Bar Chart (Vertical)"
        case .hbars: return "Bar Chart (Horizontal)"
        case .rings: return "Rings"
        }
    }
}

/// How a battery glyph is filled — length of the charge bar.
enum BatteryFillMode: String, CaseIterable {
    case used, remaining
    var title: String {
        switch self {
        case .used: return "Fill Shows Used"
        case .remaining: return "Fill Shows Remaining"
        }
    }
    var subtitle: String {
        switch self {
        case .used: return "Charge bar = % of limit used"
        case .remaining: return "Charge bar = % of limit left"
        }
    }
}

/// How wide the glyphs draw. Comfortable widens the charts a touch for
/// readability; Compact is the classic tight menu-bar footprint.
enum Density: String, CaseIterable {
    case compact, comfortable
    var title: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        }
    }
}

enum IconStyle: String, CaseIterable {
    case colour, greyscale, battery
    var title: String {
        switch self {
        case .colour: return "Colour"
        case .greyscale: return "Greyscale"
        case .battery: return "System Battery"
        }
    }
}

enum UsageError: LocalizedError {
    case noCredential, tokenExpired, http(Int), keychain(OSStatus)
    case noGrokCredential, grokTokenExpired
    case noCodexCredential, codexTokenExpired
    var errorDescription: String? {
        switch self {
        case .noCredential: return "Not signed in to Claude Code"
        case .tokenExpired: return "Login token expired — Claude Code renews it on next use"
        case .noGrokCredential: return "Not signed in to Grok"
        case .grokTokenExpired: return "Grok login expired — Grok renews it on next use"
        case .noCodexCredential: return "Not signed in to Codex"
        case .codexTokenExpired: return "Codex login expired — run codex login"
        case .http(let c): return "Usage API returned HTTP \(c)"
        case .keychain(let s): return "Keychain error \(s)"
        }
    }
}

/// Usage severity. The 50/80 thresholds live here only, so the colour and
/// its greyscale/battery shade can never drift apart.
enum Level {
    case low, mid, high
    init(_ pct: Double) { self = pct >= 80 ? .high : (pct >= 50 ? .mid : .low) }
}

func levelColor(_ pct: Double) -> NSColor {
    switch Level(pct) {
    case .high: return NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)
    case .mid:  return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)
    case .low:  return NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    }
}

/// JSONSerialization boxes numbers as NSNumber — plain `as? Int` often fails.
func jsonInt(_ any: Any?) -> Int? {
    if let i = any as? Int { return i }
    if let n = any as? NSNumber { return n.intValue }
    if let d = any as? Double { return Int(d) }
    if let s = any as? String { return Int(s) }
    return nil
}

func jsonDouble(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let n = any as? NSNumber { return n.doubleValue }
    if let i = any as? Int { return Double(i) }
    if let s = any as? String { return Double(s) }
    return nil
}

/// Runs a command-line tool synchronously, capturing stdout+stderr.
/// MUST be called off the main thread for anything slow.
@discardableResult
func runTool(_ path: String, _ args: [String]) -> (status: Int32, text: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return (-1, "") }
    p.waitUntilExit()
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, text)
}

/// Synchronous HTTP: performs `req` and blocks until it completes. MUST be called
/// off the main thread. Returns (body, statusCode); throws on transport failure.
func httpSync(_ req: URLRequest) throws -> (Data, Int) {
    let sem = DispatchSemaphore(value: 0)
    var result: (Data, Int)?
    var failure: Error?
    URLSession.shared.dataTask(with: req) { d, resp, e in
        if let e { failure = e } else {
            result = (d ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        sem.signal()
    }.resume()
    sem.wait()
    if let failure { throw failure }
    return result!
}

// MARK: - Keychain (Claude Code item via /usr/bin/security; our Admin key via SecItem)

enum Keychain {
    static let service = "Claude Code-credentials"
    /// Our own item, separate from Claude Code's, holding the optional Admin API key.
    static let adminService = "UsageMonitor-admin-key"

    static func read() throws -> [String: Any] {
        let out = try run(["find-generic-password", "-s", service, "-a", NSUserName(), "-w"])
        guard let data = out.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageError.noCredential }
        return obj
    }

    /// The Admin API key is stored only here, in the macOS Keychain — never in
    /// UserDefaults, a file, or a log. Unlike the Claude Code item (read via the
    /// `security` CLI), this uses the in-process Security APIs so the long-lived
    /// key is never passed as a command-line argument visible to `ps`.
    private static func adminQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: adminService,
         kSecAttrAccount as String: NSUserName()]
    }

    static func readAdminKey() -> String? {
        var q = adminQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    static func storeAdminKey(_ key: String) throws {
        let value = [kSecValueData as String: Data(key.utf8)] as CFDictionary
        let status = SecItemUpdate(adminQuery() as CFDictionary, value)
        if status == errSecItemNotFound {
            var add = adminQuery()
            add[kSecValueData as String] = Data(key.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw UsageError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw UsageError.keychain(status)
        }
    }

    static func deleteAdminKey() {
        SecItemDelete(adminQuery() as CFDictionary)
    }

    @discardableResult
    private static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UsageError.noCredential }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Key scanner (find existing Anthropic keys already on this Mac)

/// A candidate key found on disk/in the environment, with where it came from.
struct FoundKey: Hashable {
    let key: String
    let source: String
    var isAdmin: Bool { key.hasPrefix("sk-ant-admin") }
    /// Masked for display — we never show a full key in the UI.
    var masked: String {
        let tail = key.count > 4 ? String(key.suffix(4)) : "****"
        let head = key.hasPrefix("sk-ant-admin") ? "sk-ant-admin…" : "sk-ant-…"
        return "\(head)\(tail)"
    }
}

/// Best-effort read-only scan of common locations for `sk-ant-…` keys. Reads
/// files the user already owns; never writes, never transmits.
enum KeyScanner {
    static func scan() -> [FoundKey] {
        var found: [FoundKey] = []
        var seen = Set<String>()
        let home = NSHomeDirectory()

        // 1. Shell profiles that commonly export ANTHROPIC_API_KEY / _ADMIN_KEY.
        let profiles = [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile"]
        for name in profiles {
            let path = "\(home)/\(name)"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for key in keys(in: text) where seen.insert(key).inserted {
                found.append(FoundKey(key: key, source: "~/\(name)"))
            }
        }

        // 2. The `ant` CLI credential store.
        let antDir = "\(home)/.config/anthropic"
        if let items = try? FileManager.default.contentsOfDirectory(atPath: antDir) {
            for item in items {
                guard let text = try? String(contentsOfFile: "\(antDir)/\(item)", encoding: .utf8) else { continue }
                for key in keys(in: text) where seen.insert(key).inserted {
                    found.append(FoundKey(key: key, source: "~/.config/anthropic/\(item)"))
                }
            }
        }

        // 3. The login shell's environment (captures keys exported but not in the files above).
        if let text = loginShellEnv() {
            for line in text.split(separator: "\n") where line.contains("ANTHROPIC") {
                for key in keys(in: String(line)) where seen.insert(key).inserted {
                    found.append(FoundKey(key: key, source: "shell environment"))
                }
            }
        }

        // Admin keys first — those are the ones cost reporting needs.
        return found.sorted { $0.isAdmin && !$1.isAdmin }
    }

    private static func keys(in text: String) -> [String] {
        let pattern = "sk-ant-[A-Za-z0-9_-]{20,}"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    private static func loginShellEnv() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lic", "env"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice   // never block waiting on stdin
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // A slow or hung profile (prompt, network in .zshrc, nvm/pyenv init) must
        // not wedge the scan forever — give up after a few seconds.
        if done.wait(timeout: .now() + 3) == .timedOut { p.terminate(); return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

// MARK: - Cost client (Anthropic Admin API — org billing)

/// Fetches month-to-date API spend via the Admin API cost report.
/// Uses the Admin key only to read `cost_report`; the key never leaves this Mac
/// except in the HTTPS request to Anthropic's own server.
final class CostClient {
    let base = "https://api.anthropic.com/v1/organizations/cost_report"

    /// Month-to-date spend in USD. Throws `.http` on auth/other failure so the
    /// caller can tell an invalid key from a network blip.
    func fetchMonthToDate(adminKey: String) throws -> Double {
        var cents = 0.0
        var page: String?
        let start = Self.startOfMonthUTC()
        repeat {
            var comps = URLComponents(string: base)!
            comps.queryItems = [
                URLQueryItem(name: "starting_at", value: start),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31"),
            ]
            if let page { comps.queryItems?.append(URLQueryItem(name: "page", value: page)) }

            var req = URLRequest(url: comps.url!)
            req.setValue(adminKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let (data, code) = try httpSync(req)
            guard code == 200 else { throw UsageError.http(code) }

            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            for bucket in obj["data"] as? [[String: Any]] ?? [] {
                for item in bucket["results"] as? [[String: Any]] ?? [] {
                    // amount is a decimal string in the lowest currency unit (cents).
                    if let s = item["amount"] as? String, let v = Double(s) { cents += v }
                }
            }
            page = (obj["has_more"] as? Bool == true) ? obj["next_page"] as? String : nil
        } while page != nil
        return cents / 100.0
    }

    private static func startOfMonthUTC() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month], from: Date())
        let start = cal.date(from: comps) ?? Date()
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: start)
    }
}

// MARK: - Provider store (UserDefaults — names, letters, bar placement)

enum ProviderStore {
    private static let key = "providerConfigs.v1"
    private static let layoutKey = "menuBarLayout"

    static var layout: MenuBarLayout {
        get { MenuBarLayout(rawValue: UserDefaults.standard.string(forKey: layoutKey) ?? "") ?? .perProvider }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: layoutKey) }
    }

    static func load() -> [ProviderConfig] {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        let seed = smartDefaults()
        save(seed)
        return seed
    }

    static func save(_ configs: [ProviderConfig]) {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Seed from what's actually signed in / installed on this Mac.
    /// Public product: same rules for every user — no maintainer-specific ordering.
    static func smartDefaults() -> [ProviderConfig] {
        let present = presentKinds()
        let order = preferredKindOrder()
        let kinds = order.filter { present.contains($0) }
        if kinds.isEmpty {
            // Nothing signed in yet — seed the first two adapters for setup.
            return preferredKindOrder().prefix(2).map { ProviderConfig.make($0) }
        }
        return kinds.map { ProviderConfig.make($0) }
    }

    /// Back-compat alias.
    static func defaults() -> [ProviderConfig] { smartDefaults() }

    static func update(_ id: String, mutate: (inout ProviderConfig) -> Void) {
        var all = load()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        mutate(&all[i])
        save(all)
    }

    // MARK: detection

    /// Canonical public order. Only kinds present on the machine are seeded.
    static func preferredKindOrder() -> [ProviderKind] {
        [.claude, .grok, .codex, .cursor]
    }

    /// Which adapters look usable right now (signed in / installed).
    static func presentKinds() -> Set<ProviderKind> {
        var s = Set<ProviderKind>()
        if signedInToClaude() { s.insert(.claude) }
        if signedInToGrok() { s.insert(.grok) }
        if signedInToCodex() { s.insert(.codex) }
        if cursorInstalled() { s.insert(.cursor) }
        return s
    }
}

// MARK: - Process focus (open the terminal / app hosting a session)

/// Resolves a live CLI PID to its host app (Terminal tab, iTerm, Warp, Orbit,
/// Claude desktop) and brings **that existing surface** to the front.
/// Never opens a brand-new Terminal window when a live session PID/TTY exists.
enum ProcessFocus {
    /// Known host bundle ids we can activate.
    private static let hostBundles: [(names: [String], bundle: String)] = [
        (["Terminal"], "com.apple.Terminal"),
        (["iTerm2", "iTerm"], "com.googlecode.iterm2"),
        (["Warp"], "dev.warp.Warp-Stable"),
        (["ghostty", "Ghostty"], "com.mitchellh.ghostty"),
        (["Orbit", "orbit"], "com.ofx.orbit"),
        (["Orbit Dev", "orbit"], "com.ofx.orbit.dev"),
        (["Claude"], "com.anthropic.claudefordesktop"),
    ]

    /// Best-effort: focus the tab/window for `pid`, else activate a sensible app.
    /// Safe from a background queue — UI work hops to the main thread.
    static func open(pid: Int?, tty: String?, cwd: String?, providerKind: ProviderKind) {
        // Resolve process matching off the main thread (ps/lsof).
        var usePid = pid
        var useTTY = tty
        if usePid == nil || !(usePid.map(processAlive) ?? false) {
            if let cwd, let found = findProcess(names: providerKind.processNames, cwd: cwd) {
                usePid = found.pid
                useTTY = found.tty
            }
        }
        // Fresh TTY from ps (and parent chain) when we have a live pid.
        if let pid = usePid, processAlive(pid) {
            if let info = procInfo(pid), info.tty != "??", !info.tty.isEmpty {
                useTTY = info.tty
            } else if let chainTTY = processChain(from: pid).map(\.tty)
                .first(where: { $0 != "??" && !$0.isEmpty }) {
                useTTY = chainTTY
            }
        }
        let resolvedPid = usePid
        let resolvedTTY = useTTY
        let kind = providerKind
        let hadLiveProcess = (resolvedPid.map(processAlive) ?? false)
        // Wait for the status menu to finish dismissing — mid-menu activate is flaky.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSLog("UsageMonitor: open kind=\(kind.rawValue) pid=\(resolvedPid.map(String.init) ?? "-") tty=\(resolvedTTY ?? "-") live=\(hadLiveProcess)")

            // 1) Live PID → walk parent chain to the host app, then select the right tab.
            if let pid = resolvedPid, processAlive(pid) {
                if focusExistingSession(pid: pid, tty: resolvedTTY) { return }
            }

            // 2) TTY alone (host may not appear in short process chain as a GUI pid).
            if let tty = resolvedTTY, !tty.isEmpty, tty != "??" {
                if selectTerminalTab(tty: tty, activateOnlyIfRunning: true) { return }
                if selectITermSession(tty: tty, activateOnlyIfRunning: true) { return }
            }

            // 3) Provider desktop fallbacks (Claude / Cursor apps) — only when no live TTY host.
            if !hadLiveProcess {
                if kind == .claude, activateExisting("com.anthropic.claudefordesktop") { return }
                if kind == .cursor {
                    for bid in ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor", "com.anysphere.cursor"] {
                        if activateExisting(bid) { return }
                    }
                }
            }

            // 4) Last resort: activate an already-running host — never spawn a new Terminal
            //    window for a session that was supposed to be live.
            if hadLiveProcess {
                for bid in ["com.apple.Terminal", "com.googlecode.iterm2",
                            "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                            "com.ofx.orbit", "com.ofx.orbit.dev"] {
                    if activateExisting(bid) {
                        NSLog("UsageMonitor: open — activated existing \(bid) (tab select missed)")
                        return
                    }
                }
                NSSound.beep()
                NSLog("UsageMonitor: open — live process but could not focus host (check Automation for Terminal)")
                return
            }

            // 5) Cold path (nothing live): open the installed app if any.
            if kind == .claude, activateBundle("com.anthropic.claudefordesktop") { return }
            if kind == .cursor {
                for bid in ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor", "com.anysphere.cursor"] {
                    if activateBundle(bid) { return }
                }
            }
            // Do NOT launch Terminal here — that is what created the “new window” bug.
            NSSound.beep()
        }
    }

    private static func activateApp(_ app: NSRunningApplication) {
        // Bring our process out of accessory limbo, then force the target front.
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            app.activate(from: NSRunningApplication.current)
        } else {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    /// Public: activate an already-resolved running app (desktop AI rows).
    static func activateRunningApp(_ app: NSRunningApplication) {
        activateApp(app)
    }

    /// Focus the existing host of a live CLI process — never open a new Terminal window.
    @discardableResult
    private static func focusExistingSession(pid: Int, tty: String?) -> Bool {
        let chain = processChain(from: pid)
        let resolvedTTY: String? = {
            if let tty, !tty.isEmpty, tty != "??" { return tty }
            return chain.map(\.tty).first { $0 != "??" && !$0.isEmpty }
        }()
        NSLog("UsageMonitor: focusExisting pid=\(pid) tty=\(resolvedTTY ?? "nil") chain=\(chain.map { "\($0.comm):\($0.pid)" }.joined(separator: "→"))")

        // a) TTY tab select first (most precise) while host is already running.
        if let resolvedTTY {
            if selectTerminalTab(tty: resolvedTTY, activateOnlyIfRunning: true) { return true }
            if selectITermSession(tty: resolvedTTY, activateOnlyIfRunning: true) { return true }
        }

        // b) GUI host in the parent chain (Warp / Ghostty / Terminal / Orbit / …).
        for step in chain {
            if let app = NSRunningApplication(processIdentifier: pid_t(step.pid)),
               let bid = app.bundleIdentifier,
               hostBundles.contains(where: { $0.bundle == bid }) {
                activateApp(app)
                if bid == "com.apple.Terminal", let resolvedTTY {
                    _ = selectTerminalTab(tty: resolvedTTY, activateOnlyIfRunning: true)
                } else if bid == "com.googlecode.iterm2", let resolvedTTY {
                    _ = selectITermSession(tty: resolvedTTY, activateOnlyIfRunning: true)
                }
                return true
            }
            let comm = (step.comm as NSString).lastPathComponent
            for host in hostBundles where host.names.contains(where: {
                comm.caseInsensitiveCompare($0) == .orderedSame
                    || comm.localizedCaseInsensitiveContains($0)
            }) {
                // Only activate an already-running host — never launch.
                if activateExisting(host.bundle) {
                    if host.bundle == "com.apple.Terminal", let resolvedTTY {
                        _ = selectTerminalTab(tty: resolvedTTY, activateOnlyIfRunning: true)
                    } else if host.bundle == "com.googlecode.iterm2", let resolvedTTY {
                        _ = selectITermSession(tty: resolvedTTY, activateOnlyIfRunning: true)
                    }
                    return true
                }
            }
        }

        // c) Activate the process itself if it's somehow a GUI app.
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)),
           app.activationPolicy == .regular {
            activateApp(app)
            return true
        }
        return false
    }

    /// Normalize TTY tokens so `ttys001`, `/dev/ttys001`, and `s001` all match.
    private static func ttyNeedles(_ tty: String) -> [String] {
        var raw = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != "??" else { return [] }
        raw = raw.replacingOccurrences(of: "/dev/", with: "")
        var set: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !set.contains(t) else { return }
            set.append(t)
        }
        add(raw)
        add("/dev/\(raw)")
        if raw.hasPrefix("tty") { add(String(raw.dropFirst(3))) } // s001 from ttys001
        if !raw.hasPrefix("tty") { add("tty\(raw)") }
        return set
    }

    /// Returns true if a matching Terminal tab was selected (and Terminal activated).
    /// When `activateOnlyIfRunning` is true, never launches Terminal (avoids a new window).
    @discardableResult
    private static func selectTerminalTab(tty: String, activateOnlyIfRunning: Bool) -> Bool {
        let needles = ttyNeedles(tty)
        guard !needles.isEmpty else { return false }

        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty
        if activateOnlyIfRunning {
            guard running else { return false }
            _ = activateExisting("com.apple.Terminal")
        } else {
            guard activateBundle("com.apple.Terminal") else { return false }
        }

        // AppleScript list for `contains` checks — Terminal reports "/dev/ttys00N".
        let listLiteral = needles.map { "\"\($0)\"" }.joined(separator: ", ")
        let script = """
        tell application "Terminal"
          set needles to {\(listLiteral)}
          repeat with w in windows
            try
              set tabCount to count of tabs of w
              repeat with i from 1 to tabCount
                try
                  set t to tab i of w
                  set ttyName to (tty of t as text)
                  repeat with needle in needles
                    if ttyName contains needle then
                      set frontmost of w to true
                      set index of w to 1
                      try
                        set selected tab of w to t
                      end try
                      try
                        set selected of t to true
                      end try
                      activate
                      return "ok:" & ttyName
                    end if
                  end repeat
                end try
              end repeat
            end try
          end repeat
          return "miss"
        end tell
        """
        var err: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return false }
        let result = apple.executeAndReturnError(&err)
        if let err {
            NSLog("UsageMonitor: Terminal tab select error: \(err)")
            return false
        }
        let val = result.stringValue ?? ""
        NSLog("UsageMonitor: Terminal tab select → \(val) for \(needles.joined(separator: "|"))")
        return val.hasPrefix("ok")
    }

    @discardableResult
    private static func selectITermSession(tty: String, activateOnlyIfRunning: Bool) -> Bool {
        let needles = ttyNeedles(tty)
        guard !needles.isEmpty else { return false }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").isEmpty
        if activateOnlyIfRunning {
            guard running else { return false }
            _ = activateExisting("com.googlecode.iterm2")
        } else {
            guard activateBundle("com.googlecode.iterm2") else { return false }
        }
        let listLiteral = needles.map { "\"\($0)\"" }.joined(separator: ", ")
        let script = """
        tell application "iTerm"
          set needles to {\(listLiteral)}
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  set ttyName to (tty of s as text)
                  repeat with needle in needles
                    if ttyName contains needle then
                      select s
                      select t
                      activate
                      return "ok:" & ttyName
                    end if
                  end repeat
                end try
              end repeat
            end repeat
          end repeat
          return "miss"
        end tell
        """
        var err: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return false }
        let result = apple.executeAndReturnError(&err)
        if err != nil { return false }
        let val = result.stringValue ?? ""
        NSLog("UsageMonitor: iTerm session select → \(val)")
        return val.hasPrefix("ok")
    }

    /// Activate only if already running — never launch (no new window).
    @discardableResult
    static func activateExisting(_ id: String) -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        guard let app = apps.first else { return false }
        activateApp(app)
        return true
    }

    @discardableResult
    static func activateBundle(_ id: String) -> Bool {
        if activateExisting(id) { return true }
        // Launch if installed (desktop apps / cold start only).
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            return true
        }
        return false
    }

    /// Public entry for menu actions (desktop AI apps).
    @discardableResult
    static func activateBundlePublic(_ id: String) -> Bool { activateBundle(id) }

    static func processAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0
    }

    struct ProcInfo { let pid: Int; let ppid: Int; let tty: String; let comm: String }

    static func processChain(from pid: Int) -> [ProcInfo] {
        var out: [ProcInfo] = []
        var cur = pid
        for _ in 0..<10 {
            guard let info = procInfo(cur) else { break }
            out.append(info)
            if info.ppid <= 1 { break }
            cur = info.ppid
        }
        return out
    }

    static func procInfo(_ pid: Int) -> ProcInfo? {
        let (status, text) = runTool("/bin/ps", ["-o", "pid=,ppid=,tty=,comm=", "-p", "\(pid)"])
        guard status == 0 else { return nil }
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 4, let p = Int(parts[0]), let pp = Int(parts[1]) else { return nil }
        return ProcInfo(pid: p, ppid: pp, tty: parts[2], comm: parts[3...].joined(separator: " "))
    }

    /// Find a live process whose command matches and cwd equals (or is under) path.
    static func findProcess(names: [String], cwd: String) -> (pid: Int, tty: String)? {
        let (status, text) = runTool("/bin/ps", ["-axo", "pid=,tty=,comm="])
        guard status == 0 else { return nil }
        let target = (cwd as NSString).standardizingPath
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 3, let pid = Int(parts[0]) else { continue }
            let comm = parts[2...].joined(separator: " ")
            guard names.contains(where: { comm == $0 || comm.hasSuffix("/\($0)") }) else { continue }
            guard let pcwd = cwdOf(pid: pid) else { continue }
            let std = (pcwd as NSString).standardizingPath
            if std == target || std.hasPrefix(target + "/") || target.hasPrefix(std + "/") {
                return (pid, parts[1])
            }
        }
        return nil
    }

    static func cwdOf(pid: Int) -> String? {
        // macOS: lsof -a -p PID -d cwd -Fn  (slow if called per-pid — prefer indexCLI)
        let (status, text) = runTool("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        guard status == 0 else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    /// Index of live CLI processes: name → [(pid, tty, cwd)].
    /// Uses one `ps` + one `lsof` per command name (never per-PID lsof storms).
    static func indexCLI(names: [String]) -> [(name: String, pid: Int, tty: String, cwd: String)] {
        let (status, text) = runTool("/bin/ps", ["-axo", "pid=,tty=,comm="])
        guard status == 0 else { return [] }
        var byPid: [Int: (name: String, tty: String)] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 3, let pid = Int(parts[0]) else { continue }
            let comm = (parts[2] as NSString).lastPathComponent
            guard names.contains(comm) else { continue }
            byPid[pid] = (comm, parts[1])
        }
        guard !byPid.isEmpty else { return [] }

        // Batch cwd lookup: one lsof invocation per command name.
        var cwdByPid: [Int: String] = [:]
        for name in names {
            let (st, out) = runTool("/usr/sbin/lsof", ["-a", "-c", name, "-d", "cwd", "-Fn"])
            guard st == 0 else { continue }
            var curPid: Int?
            for line in out.split(separator: "\n") {
                if line.hasPrefix("p"), let p = Int(line.dropFirst()) { curPid = p }
                else if line.hasPrefix("n"), let p = curPid {
                    cwdByPid[p] = String(line.dropFirst())
                }
            }
        }

        return byPid.map { pid, meta in
            (meta.name, pid, meta.tty, cwdByPid[pid] ?? "")
        }
    }
}

// MARK: - Claude Code activity (local session transcripts)

/// Surfaces which Claude Code CLI sessions (across terminals/projects) are
/// active or recently active, and how many tokens each has sent/received.
/// Reads only transcript metadata — no message content (except the short
/// `lastPrompt` summary field Claude already stores for session lists).
final class ClaudeActivityMonitor {
    private struct Cache {
        var offset: UInt64 = 0
        var tokensIn = 0
        var tokensOut = 0
        var cwd = ""
        var branch: String?
        var lastActivity = Date.distantPast
        var awaitingReply = false
        var lastPrompt: String?
        var entrypoint: String?
    }

    private var cache: [String: Cache] = [:]
    private let recentWindow: TimeInterval = 30 * 60
    private let liveWindow: TimeInterval = 5 * 60
    private let root = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")

    /// Max bytes to read on first sight of a huge transcript (metadata lives in recent lines).
    private let bootstrapTail: UInt64 = 256 * 1024
    /// Don't open more than this many recent files per scan (menu stays snappy).
    private let maxFilesPerScan = 40

    /// Blocking; call off the main thread. `config` supplies letter/name for rows.
    func scan(config: ProviderConfig) -> [ActivitySession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-recentWindow)
        var candidates: [(url: URL, mtime: Date)] = []

        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, mtime > cutoff else { continue }
                candidates.append((file, mtime))
            }
        }
        // Newest first; hard cap so a cluttered ~/.claude never freezes the scanner.
        candidates.sort { $0.mtime > $1.mtime }
        if candidates.count > maxFilesPerScan {
            candidates = Array(candidates.prefix(maxFilesPerScan))
        }
        var seen = Set<String>()
        for item in candidates {
            seen.insert(item.url.path)
            update(item.url)
        }
        cache = cache.filter { seen.contains($0.key) || $0.value.lastActivity > cutoff }

        // Match live `claude` processes by cwd (one batched lsof).
        let liveProcs = ProcessFocus.indexCLI(names: ["claude"])

        return cache.compactMap { path, c -> ActivitySession? in
            guard c.lastActivity > cutoff || liveProcs.contains(where: { proc in
                guard !c.cwd.isEmpty, !proc.cwd.isEmpty else { return false }
                let a = (c.cwd as NSString).standardizingPath
                let b = (proc.cwd as NSString).standardizingPath
                return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
            }) else { return nil }

            let id = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
            let match = liveProcs.first { proc in
                guard !c.cwd.isEmpty, !proc.cwd.isEmpty else { return false }
                let a = (c.cwd as NSString).standardizingPath
                let b = (proc.cwd as NSString).standardizingPath
                return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
            }
            let awaiting = c.awaitingReply && Date().timeIntervalSince(c.lastActivity) < liveWindow
            let live = awaiting || match != nil
            return ActivitySession(
                id: id,
                providerId: config.id,
                providerLetter: config.letter,
                providerName: config.displayName,
                project: Self.projectLabel(c.cwd),
                cwd: c.cwd.isEmpty ? nil : c.cwd,
                branch: c.branch,
                title: c.lastPrompt.map(Self.shorten),
                tokensIn: c.tokensIn, tokensOut: c.tokensOut,
                model: nil,
                lastActivity: c.lastActivity,
                live: live,
                pid: match?.pid,
                tty: match?.tty)
        }.sorted { $0.lastActivity > $1.lastActivity }
    }

    private func update(_ file: URL) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var c = cache[file.path] ?? Cache()
        if size < c.offset { c = Cache() }   // truncated/rotated
        guard size > c.offset else { cache[file.path] = c; return }

        // First sight of a huge file: only tail — never re-read multi‑MB histories.
        var start = c.offset
        var skipPartialLine = false
        if c.offset == 0, size > bootstrapTail {
            start = size - bootstrapTail
            skipPartialLine = true
        }
        try? handle.seek(toOffset: start)
        var data = handle.readDataToEndOfFile()
        if skipPartialLine, let nl = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data.suffix(from: data.index(after: nl))
        }
        c.offset = size
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            apply(obj, to: &c)
        }
        // If we only tailed, token totals are lower-bound — fine for the menu.
        cache[file.path] = c
    }

    private func apply(_ obj: [String: Any], to c: inout Cache) {
        if let cwd = obj["cwd"] as? String { c.cwd = cwd }
        if let branch = obj["gitBranch"] as? String, !branch.isEmpty { c.branch = branch }
        if let ts = obj["timestamp"] as? String, let d = isoTimestamp.date(from: ts) { c.lastActivity = d }
        if let p = obj["lastPrompt"] as? String, !p.isEmpty { c.lastPrompt = p }
        if let e = obj["entrypoint"] as? String { c.entrypoint = e }
        let type = obj["type"] as? String
        if type == "user" { c.awaitingReply = true }
        if type == "system", (obj["subtype"] as? String) == "turn_duration" { c.awaitingReply = false }
        if let message = obj["message"] as? [String: Any], let u = message["usage"] as? [String: Any] {
            c.tokensIn += (jsonInt(u["input_tokens"]) ?? 0)
                + (jsonInt(u["cache_creation_input_tokens"]) ?? 0)
                + (jsonInt(u["cache_read_input_tokens"]) ?? 0)
            c.tokensOut += (jsonInt(u["output_tokens"]) ?? 0)
        }
    }

    private let isoTimestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func projectLabel(_ cwd: String) -> String {
        let comps = cwd.split(separator: "/")
        if let idx = comps.firstIndex(of: ".claude"), idx > 0 { return String(comps[idx - 1]) }
        return (cwd as NSString).lastPathComponent
    }

    /// First line / ~72 chars of a lastPrompt for the dark header.
    static func shorten(_ s: String) -> String {
        let one = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if one.count <= 72 { return one }
        return String(one.prefix(69)) + "…"
    }
}

func abbreviateTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
    return "\(n)"
}

// MARK: - Update preferences (check cadence, skip, pause)

/// User choices for update checks and surfacing. No telemetry — only GitHub
/// latest-release requests on the schedule below.
enum UpdatePrefs {
    /// Four checks per day ≈ every 6 hours.
    static let checkInterval: TimeInterval = 6 * 60 * 60
    /// Marquee “Update available” in the menu bar at most once per hour.
    static let marqueeInterval: TimeInterval = 60 * 60

    private static let lastCheckKey = "lastUpdateCheck"
    private static let skipAllKey = "updates.skipAll"
    private static let skipVersionKey = "updates.skipVersion"
    private static let pauseUntilKey = "updates.pauseUntil"
    private static let lastMarqueeKey = "updates.lastMarquee"
    private static let autoKey = "autoUpdate"

    static var lastCheckAt: TimeInterval {
        get { UserDefaults.standard.double(forKey: lastCheckKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastCheckKey) }
    }

    static var skipAllFuture: Bool {
        get { UserDefaults.standard.bool(forKey: skipAllKey) }
        set { UserDefaults.standard.set(newValue, forKey: skipAllKey) }
    }

    /// Specific version the user chose to ignore (e.g. “2.6.0”).
    static var skippedVersion: String {
        get { UserDefaults.standard.string(forKey: skipVersionKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: skipVersionKey) }
    }

    static var pauseUntil: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: pauseUntilKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let d = newValue {
                UserDefaults.standard.set(d.timeIntervalSince1970, forKey: pauseUntilKey)
            } else {
                UserDefaults.standard.removeObject(forKey: pauseUntilKey)
            }
        }
    }

    static var lastMarqueeAt: TimeInterval {
        get { UserDefaults.standard.double(forKey: lastMarqueeKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastMarqueeKey) }
    }

    static var autoUpdateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    static var isPaused: Bool {
        guard let until = pauseUntil else { return false }
        if until <= Date() {
            pauseUntil = nil
            return false
        }
        return true
    }

    /// Network check allowed now?
    static func shouldNetworkCheck(force: Bool = false) -> Bool {
        if force { return true }
        if skipAllFuture { return false }
        if isPaused { return false }
        return Date().timeIntervalSince1970 - lastCheckAt >= checkInterval
    }

    /// Should this version appear in UI / marquee / auto-install?
    static func shouldSurface(version: String) -> Bool {
        if skipAllFuture { return false }
        if isPaused { return false }
        if !skippedVersion.isEmpty, skippedVersion == version { return false }
        return true
    }

    static func shouldMarquee() -> Bool {
        Date().timeIntervalSince1970 - lastMarqueeAt >= marqueeInterval
    }

    static func pause(for days: Int) {
        pauseUntil = Calendar.current.date(byAdding: .day, value: days, to: Date())
    }

    static func pause(forWeeks weeks: Int) {
        pause(for: weeks * 7)
    }

    static func clearPause() { pauseUntil = nil }

    static func clearSkipVersion() { skippedVersion = "" }

    static func resumeAll() {
        skipAllFuture = false
        clearSkipVersion()
        clearPause()
    }
}

// MARK: - Update check (GitHub releases)

/// Asks GitHub for the latest release (cadence owned by `UpdatePrefs`).
/// Only the standard HTTP request is sent — no identifiers, no telemetry.
final class UpdateChecker {
    let latestURL = URL(string: "https://api.github.com/repos/jackfieldman/usage-monitor/releases/latest")!

    /// Blocking; call off the main thread. Returns (version, release page,
    /// zip asset) when a newer release exists, else nil. `zip` is nil when the
    /// release has no UsageMonitor.zip asset — then we can only open the page.
    func check() -> (version: String, page: URL, zip: URL?)? {
        var req = URLRequest(url: latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, code) = try? httpSync(req), code == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let page = URL(string: obj["html_url"] as? String ?? "") else { return nil }
        var zip: URL?
        for asset in obj["assets"] as? [[String: Any]] ?? []
        where asset["name"] as? String == "UsageMonitor.zip" {
            zip = URL(string: asset["browser_download_url"] as? String ?? "")
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return Self.isNewer(latest, than: current) ? (latest, page, zip) : nil
    }

    /// Downloads `zip`, verifies the app inside is signed by the SAME
    /// Developer ID team as the running app, and swaps it into the running
    /// bundle's path. Returns false (leaving the current install untouched)
    /// on any download, signature, or filesystem failure. Blocking.
    func downloadAndInstall(_ zip: URL) -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("UsageMonitorUpdate-\(getpid())")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let (data, code) = try httpSync(URLRequest(url: zip))
            guard code == 200, !data.isEmpty else { return false }
            let zipPath = tmp.appendingPathComponent("UsageMonitor.zip")
            try data.write(to: zipPath)
            guard runTool("/usr/bin/ditto", ["-xk", zipPath.path, tmp.path]).status == 0 else { return false }
            let newApp = tmp.appendingPathComponent("UsageMonitor.app")
            guard fm.fileExists(atPath: newApp.path), signedBySameTeam(newApp) else { return false }
            let current = URL(fileURLWithPath: Bundle.main.bundlePath)
            // Move the running bundle aside, the new one into place; restore
            // the old one if the second move fails.
            let aside = tmp.appendingPathComponent("UsageMonitor-old.app")
            try fm.moveItem(at: current, to: aside)
            do { try fm.moveItem(at: newApp, to: current) }
            catch { try? fm.moveItem(at: aside, to: current); return false }
            return true
        } catch { return false }
    }

    /// True only if `app` passes strict codesign verification AND carries the
    /// same TeamIdentifier as the running app. Ad-hoc builds ("not set")
    /// never match, so development copies won't self-update.
    private func signedBySameTeam(_ app: URL) -> Bool {
        guard runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0,
              let new = teamID(app.path), new != "not set",
              new == teamID(Bundle.main.bundlePath) else { return false }
        return true
    }

    private func teamID(_ path: String) -> String? {
        let (status, text) = runTool("/usr/bin/codesign", ["-dvv", path])
        guard status == 0 else { return nil }
        return text.split(separator: "\n")
            .first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    /// Numeric dotted-version compare: "1.10" > "1.9", "1.5" == "1.5.0".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0, y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

// MARK: - Usage client

final class UsageClient {
    let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Blocking; call off the main thread.
    ///
    /// Read-only by design: the access token is used exactly as Claude Code
    /// left it, and an expired token is reported — never refreshed. Refreshing
    /// rotates the shared refresh token, and if Claude Code refreshes with its
    /// (now stale) copy the server's reuse detection can revoke the whole
    /// grant, logging Claude Code out. Claude Code renews the token whenever
    /// it's used; the next poll then picks the fresh one up automatically.
    func fetchUsage() throws -> [Gauge] {
        let cred = try Keychain.read()
        let oauth = cred["claudeAiOauth"] as? [String: Any] ?? [:]
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.noCredential
        }
        let (data, code) = try get(token)
        if code == 401 || code == 403 { throw UsageError.tokenExpired }
        guard code == 200 else { throw UsageError.http(code) }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let limits = obj["limits"] as? [[String: Any]] ?? []
        return limits.map(gauge(from:))
    }

    private func get(_ token: String) throws -> (Data, Int) {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return try httpSync(req)
    }

    // limits[] -> Gauge
    private func gauge(from lim: [String: Any]) -> Gauge {
        let kind = lim["kind"] as? String ?? ""
        let label: String
        switch kind {
        case "session": label = "Session"
        case "weekly_all": label = "All models"
        default:
            let scope = lim["scope"] as? [String: Any]
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            label = model ?? "Weekly"
        }
        let pct = (lim["percent"] as? NSNumber)?.doubleValue ?? 0
        return Gauge(label: label, percent: pct.rounded(), sub: resetSub(lim["resets_at"] as? String))
    }

    private func resetSub(_ iso: String?) -> String {
        guard let iso else { return "" }
        let cleaned = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        guard let dt = f.date(from: cleaned) else { return "" }
        let delta = dt.timeIntervalSinceNow
        if delta <= 0 { return "resetting…" }
        let df = DateFormatter()
        if delta < 3600 { return "resets in \(Int(delta / 60)) min" }
        df.dateFormat = delta < 12 * 3600 ? "h:mm a" : "EEE h:mm a"
        return "resets " + df.string(from: dt)
    }
}

// MARK: - Grok auth + billing (session token in ~/.grok/auth.json)

/// Read-only access to the Grok CLI session stored at `~/.grok/auth.json`.
/// Grok owns refresh; we never rewrite the file (same reason as Claude: a
/// concurrent refresh race can invalidate the CLI's session).
enum GrokAuth {
    static let authPath = NSHomeDirectory() + "/.grok/auth.json"

    /// Best available access token (`key` field) across OIDC/API entries.
    static func readAccessToken() throws -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !obj.isEmpty
        else { throw UsageError.noGrokCredential }

        // Prefer the most recently created entry that still has a token.
        var best: (token: String, created: String)?
        for (_, value) in obj {
            guard let entry = value as? [String: Any] else { continue }
            let token = (entry["key"] as? String)
                ?? (entry["access_token"] as? String)
                ?? ""
            guard !token.isEmpty else { continue }
            let created = entry["create_time"] as? String ?? ""
            if best == nil || created > (best?.created ?? "") {
                best = (token, created)
            }
        }
        guard let token = best?.token else { throw UsageError.noGrokCredential }
        return token
    }
}

/// Fetches Grok credit/usage gauges via the same billing endpoint the Grok
/// CLI `/usage` command uses (`GET …/v1/billing?format=credits`).
final class GrokUsageClient {
    let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    /// Blocking; call off the main thread. Returns gauges: overall "Grok"
    /// plus any product rows that report a usage percent (Build, API, …).
    func fetchUsage() throws -> [Gauge] {
        let token = try GrokAuth.readAccessToken()
        var req = URLRequest(url: billingURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        let (data, code) = try httpSync(req)
        if code == 401 || code == 403 { throw UsageError.grokTokenExpired }
        guard code == 200 else { throw UsageError.http(code) }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let config = obj["config"] as? [String: Any] ?? obj
        let reset = resetSub(
            (config["billingPeriodEnd"] as? String)
                ?? ((config["currentPeriod"] as? [String: Any])?["end"] as? String))

        var gauges: [Gauge] = []
        if let pct = number(config["creditUsagePercent"]) {
            gauges.append(Gauge(label: "Grok", percent: pct.rounded(), sub: reset))
        }
        for product in config["productUsage"] as? [[String: Any]] ?? [] {
            guard let name = product["product"] as? String,
                  let pct = number(product["usagePercent"]) else { continue }
            gauges.append(Gauge(label: Self.productLabel(name),
                                percent: pct.rounded(), sub: reset))
        }
        // If the API shape drifts and we got nothing, surface a clear error.
        if gauges.isEmpty { throw UsageError.http(200) }
        return gauges
    }

    private func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func productLabel(_ product: String) -> String {
        switch product {
        case "GrokBuild": return "Grok Build"
        case "Api", "API": return "Grok API"
        case "GrokChat": return "Grok Chat"
        case "GrokImagine": return "Grok Imagine"
        default:
            return product.hasPrefix("Grok") ? product : "Grok \(product)"
        }
    }

    private func resetSub(_ iso: String?) -> String {
        guard let iso else { return "" }
        let cleaned = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "+00:00", with: "Z")
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        var dt = f.date(from: cleaned)
        if dt == nil {
            // Fractional seconds / offset variants the ISO formatter sometimes misses.
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            dt = f2.date(from: iso)
        }
        guard let dt else { return "" }
        let delta = dt.timeIntervalSinceNow
        if delta <= 0 { return "resetting…" }
        let df = DateFormatter()
        if delta < 3600 { return "resets in \(Int(delta / 60)) min" }
        df.dateFormat = delta < 12 * 3600 ? "h:mm a" : "EEE h:mm a"
        return "resets " + df.string(from: dt)
    }
}

// MARK: - Codex auth + usage (ChatGPT session in ~/.codex/auth.json)

/// Read-only access to Codex CLI auth at `~/.codex/auth.json`.
enum CodexAuth {
    static let authPath = NSHomeDirectory() + "/.codex/auth.json"

    static func readTokens() throws -> (access: String, accountId: String?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageError.noCodexCredential }
        let tokens = obj["tokens"] as? [String: Any] ?? [:]
        let access = tokens["access_token"] as? String ?? ""
        guard !access.isEmpty else { throw UsageError.noCodexCredential }
        let account = tokens["account_id"] as? String
        return (access, account)
    }
}

/// Fetches Codex rate-limit gauges via ChatGPT's WHAM usage endpoint
/// (same data Codex / the ChatGPT Codex UI shows).
final class CodexUsageClient {
    let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// Blocking; call off the main thread.
    func fetchUsage() throws -> [Gauge] {
        let (access, accountId) = try CodexAuth.readTokens()
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, code) = try httpSync(req)
        if code == 401 || code == 403 { throw UsageError.codexTokenExpired }
        guard code == 200 else { throw UsageError.http(code) }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var gauges: [Gauge] = []

        if let rl = obj["rate_limit"] as? [String: Any] {
            if let primary = rl["primary_window"] as? [String: Any],
               let pct = number(primary["used_percent"]) {
                gauges.append(Gauge(label: "Codex", percent: pct.rounded(),
                                    sub: resetSub(primary)))
            }
            if let secondary = rl["secondary_window"] as? [String: Any],
               let pct = number(secondary["used_percent"]) {
                gauges.append(Gauge(label: "Codex 2", percent: pct.rounded(),
                                    sub: resetSub(secondary)))
            }
        }
        // Credits balance as a soft gauge only when the account has a credit pool.
        if let credits = obj["credits"] as? [String: Any],
           credits["has_credits"] as? Bool == true,
           let bal = number(credits["balance"]) {
            // Balance is remaining credits (not a percent) — skip if we can't normalize.
            _ = bal
        }
        if gauges.isEmpty { throw UsageError.http(200) }
        return gauges
    }

    private func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    private func resetSub(_ window: [String: Any]) -> String {
        if let resetAt = window["reset_at"] as? Int ?? (window["reset_at"] as? NSNumber)?.intValue {
            let dt = Date(timeIntervalSince1970: TimeInterval(resetAt))
            let delta = dt.timeIntervalSinceNow
            if delta <= 0 { return "resetting…" }
            if delta < 3600 { return "resets in \(Int(delta / 60)) min" }
            let df = DateFormatter()
            df.dateFormat = delta < 12 * 3600 ? "h:mm a" : "EEE h:mm a"
            return "resets " + df.string(from: dt)
        }
        if let secs = window["reset_after_seconds"] as? Int
            ?? (window["reset_after_seconds"] as? NSNumber)?.intValue {
            if secs <= 0 { return "resetting…" }
            if secs < 3600 { return "resets in \(secs / 60) min" }
            if secs < 86400 { return "resets in \(secs / 3600)h" }
            return "resets in \(secs / 86400)d"
        }
        return ""
    }
}

/// Codex activity from `~/.codex/session_index.jsonl` + live `codex` processes.
final class CodexActivityMonitor {
    private let indexPath = NSHomeDirectory() + "/.codex/session_index.jsonl"
    private let recentWindow: TimeInterval = 30 * 60
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func scan(config: ProviderConfig) -> [ActivitySession] {
        guard let text = try? String(contentsOfFile: indexPath, encoding: .utf8) else { return [] }
        let cutoff = Date().addingTimeInterval(-recentWindow)
        let liveProcs = ProcessFocus.indexCLI(names: ["codex"])
        var out: [ActivitySession] = []
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String else { continue }
            let title = obj["thread_name"] as? String
            let updated = parseDate(obj["updated_at"] as? String) ?? Date.distantPast
            let cwd = obj["cwd"] as? String
            let match = liveProcs.first { proc in
                guard let cwd, !proc.cwd.isEmpty else { return false }
                let a = (cwd as NSString).standardizingPath
                let b = (proc.cwd as NSString).standardizingPath
                return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
            }
            let live = match != nil
            guard live || updated > cutoff else { continue }
            let project: String
            if let cwd, !cwd.isEmpty {
                project = (cwd as NSString).lastPathComponent
            } else {
                project = title.map { ClaudeActivityMonitor.shorten($0) } ?? "codex"
            }
            out.append(ActivitySession(
                id: id,
                providerId: config.id,
                providerLetter: config.letter,
                providerName: config.displayName,
                project: project,
                cwd: cwd,
                branch: nil,
                title: title.map(ClaudeActivityMonitor.shorten),
                tokensIn: nil, tokensOut: nil,
                model: nil,
                lastActivity: updated,
                live: live,
                pid: match?.pid,
                tty: match?.tty))
        }
        return out.sorted { $0.lastActivity > $1.lastActivity }
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }
}

/// Cursor activity — lightweight: if Cursor.app is running, one “app open” row.
/// (No stable public usage endpoint; click opens the desktop app.)
final class CursorActivityMonitor {
    func scan(config: ProviderConfig) -> [ActivitySession] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.todesktop.230313mzl4w4u92")
            + NSWorkspace.shared.runningApplications.filter {
                ($0.localizedName ?? "").localizedCaseInsensitiveContains("Cursor")
                    && ($0.bundleURL?.path.contains("Cursor.app") ?? false)
            }
        guard let app = apps.first, app.processIdentifier > 0 else { return [] }
        return [ActivitySession(
            id: "cursor-app",
            providerId: config.id,
            providerLetter: config.letter,
            providerName: config.displayName,
            project: "Cursor",
            cwd: nil,
            branch: nil,
            title: "Desktop app open",
            tokensIn: nil, tokensOut: nil,
            model: nil,
            lastActivity: Date(),
            live: true,
            pid: Int(app.processIdentifier),
            tty: nil)]
    }
}

// MARK: - Grok activity (local session registry — no chat content)

/// Surfaces which Grok CLI sessions are live or recent. Reads only the
/// registry + summary metadata Grok already writes under `~/.grok/sessions`
/// — no network, no message content.
final class GrokActivityMonitor {
    private let recentWindow: TimeInterval = 30 * 60
    private let sessionsRoot = URL(fileURLWithPath: NSHomeDirectory() + "/.grok/sessions")
    private let activePath = NSHomeDirectory() + "/.grok/active_sessions.json"
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Blocking file I/O; call off the main thread. Sorted most-recent first.
    func scan(config: ProviderConfig) -> [ActivitySession] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: activePath)),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let cutoff = Date().addingTimeInterval(-recentWindow)
        var out: [ActivitySession] = []
        for row in rows {
            guard let id = row["session_id"] as? String else { continue }
            let cwd = row["cwd"] as? String ?? ""
            // pid arrives as NSNumber from JSONSerialization — never use bare `as? Int`.
            let pid = jsonInt(row["pid"])
            let live = pid.map(ProcessFocus.processAlive) ?? false
            let opened = parseDate(row["opened_at"] as? String) ?? Date.distantPast

            var last = opened
            var branch: String?
            var model: String?
            var title: String?
            if let summary = loadSummary(cwd: cwd, id: id) {
                if let t = parseDate(summary["last_active_at"] as? String
                                     ?? summary["updated_at"] as? String) {
                    last = t
                }
                branch = summary["head_branch"] as? String
                model = summary["current_model_id"] as? String
                let raw = (summary["session_summary"] as? String)
                    ?? (summary["generated_title"] as? String)
                title = raw.map(ClaudeActivityMonitor.shorten)
            }
            // TTY from a single cheap `ps -p` (not a full process table walk).
            var tty: String?
            if let pid, live, let info = ProcessFocus.procInfo(pid), info.tty != "??" {
                tty = info.tty
            }
            // Always keep live processes; recent idle only within the window.
            guard live || last > cutoff else { continue }
            out.append(ActivitySession(
                id: id,
                providerId: config.id,
                providerLetter: config.letter,
                providerName: config.displayName,
                project: (cwd as NSString).lastPathComponent,
                cwd: cwd.isEmpty ? nil : cwd,
                branch: branch.flatMap { $0.isEmpty ? nil : $0 },
                title: title,
                tokensIn: nil, tokensOut: nil,
                model: model,
                lastActivity: last,
                live: live,
                pid: pid,
                tty: tty))
        }
        return out.sorted { $0.lastActivity > $1.lastActivity }
    }

    private func loadSummary(cwd: String, id: String) -> [String: Any]? {
        let encoded = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
            .replacingOccurrences(of: "/", with: "%2F") ?? cwd
        let url = sessionsRoot
            .appendingPathComponent(encoded)
            .appendingPathComponent(id)
            .appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }
}

// MARK: - Onboarding

func claudeInstalled() -> Bool {
    let paths = ["\(NSHomeDirectory())/.local/bin/claude",
                 "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    if paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return true }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["which", "claude"]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}

func grokInstalled() -> Bool {
    let paths = ["\(NSHomeDirectory())/.grok/bin/grok",
                 "\(NSHomeDirectory())/.local/bin/grok",
                 "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
    if paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return true }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["which", "grok"]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}

func signedInToClaude() -> Bool {
    guard let cred = try? Keychain.read(),
          let oauth = cred["claudeAiOauth"] as? [String: Any],
          let t = oauth["accessToken"] as? String else { return false }
    return !t.isEmpty
}

func signedInToGrok() -> Bool {
    (try? GrokAuth.readAccessToken()) != nil
}

func signedInToCodex() -> Bool {
    (try? CodexAuth.readTokens()) != nil
}

func cursorInstalled() -> Bool {
    FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
        || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") != nil
}

func anyProviderSignedIn() -> Bool {
    signedInToClaude() || signedInToGrok() || signedInToCodex() || cursorInstalled()
}

func apiKeyConfigured() -> Bool { Keychain.readAdminKey() != nil }

/// First-run window: sets up Claude Code and/or Grok (for the gauges) and,
/// optionally, an Anthropic Admin API key (for Claude dollar spend).
final class OnboardingController: NSObject, NSWindowDelegate {
    var onReady: (() -> Void)?
    var onKeyChanged: (() -> Void)?
    private var window: NSWindow?
    private var body: NSTextField?
    private var grokBody: NSTextField?
    private var apiStatus: NSTextField?
    private var status: NSTextField?
    private var primary: NSButton?
    private var apiButtons: [NSButton] = []
    private let cost = CostClient()
    private var busy = false

    func present() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Usage Monitor Setup"
        win.delegate = self
        win.isReleasedWhenClosed = false

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 44).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let title = NSTextField(labelWithString: "Welcome to Usage Monitor")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        let heading = NSStackView(views: [iconView, title])
        heading.orientation = .horizontal
        heading.spacing = 12
        heading.alignment = .centerY

        // Section 1 — Claude Code subscription (powers Claude % gauges).
        let sub = sectionTitle("Claude usage gauges")
        let body = NSTextField(wrappingLabelWithString: "")
        body.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.body = body
        let copyBtn = button("Copy Claude install", #selector(copyInstall))
        let recheck = button("Re-check", #selector(refresh))
        let subRow = NSStackView(views: [copyBtn, NSView(), recheck])
        subRow.orientation = .horizontal; subRow.spacing = 8

        // Section 1b — Grok CLI (powers Grok % gauges). Either provider is enough.
        let grokTitle = sectionTitle("Grok usage gauges")
        let grokBody = NSTextField(wrappingLabelWithString: "")
        grokBody.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.grokBody = grokBody
        let copyGrok = button("Copy Grok install", #selector(copyGrokInstall))
        let grokRow = NSStackView(views: [copyGrok, NSView()])
        grokRow.orientation = .horizontal; grokRow.spacing = 8

        // Section 2 — optional Admin API key (powers Claude dollar spend).
        let apiTitle = sectionTitle("Claude API dollar spend  (optional)")
        let apiBody = NSTextField(wrappingLabelWithString:
            "To also show what you've spent on the Anthropic pay-as-you-go API, add an "
            + "Admin API key (starts with sk-ant-admin) from console.anthropic.com. "
            + "It's stored only in your macOS Keychain and used solely to read your "
            + "cost report — never shared. Skip this if you only use a Pro/Max plan.")
        apiBody.font = .systemFont(ofSize: 11)
        apiBody.textColor = .secondaryLabelColor
        let apiStatus = NSTextField(labelWithString: "")
        apiStatus.font = .systemFont(ofSize: 12, weight: .medium)
        self.apiStatus = apiStatus
        let getBtn = button("Get a key…", #selector(openConsole))
        let scanBtn = button("Scan Mac…", #selector(scanForKeys))
        let enterBtn = button("Enter manually…", #selector(enterKey))
        let removeBtn = button("Remove", #selector(removeKey))
        apiButtons = [getBtn, scanBtn, enterBtn, removeBtn]
        let apiRow = NSStackView(views: [getBtn, scanBtn, enterBtn, removeBtn, NSView()])
        apiRow.orientation = .horizontal; apiRow.spacing = 8

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        self.status = status
        let primary = button("Get Started", #selector(finish))
        primary.keyEquivalent = "\r"
        self.primary = primary
        let footer = NSStackView(views: [status, NSView(), primary])
        footer.orientation = .horizontal; footer.spacing = 8

        let stack = NSStackView(views: [heading, sub, body, subRow,
                                        separator(), grokTitle, grokBody, grokRow,
                                        separator(), apiTitle, apiBody, apiStatus, apiRow,
                                        separator(), footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: 432),
            grokBody.widthAnchor.constraint(equalToConstant: 432),
            apiBody.widthAnchor.constraint(equalToConstant: 432),
            footer.widthAnchor.constraint(equalToConstant: 432),
        ])
        win.contentView = content
        self.window = win
    }

    private func sectionTitle(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        return t
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }
    private func separator() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 432).isActive = true
        return b
    }

    @objc func refresh() {
        let hasClaude = claudeInstalled()
        let claudeIn = signedInToClaude()
        let hasGrok = grokInstalled()
        let grokIn = signedInToGrok()
        func mark(_ ok: Bool) -> String { ok ? "✅" : "⬜️" }
        body?.stringValue = """
        \(mark(hasClaude))  1. Install Claude Code
              curl -fsSL https://claude.ai/install.sh | bash

        \(mark(claudeIn))  2. Sign in to Claude Code
              Run  claude  in a terminal and complete sign-in.
              (Requires a Claude Pro or Max subscription.)
        """
        grokBody?.stringValue = """
        \(mark(hasGrok))  1. Install Grok CLI
              See https://docs.x.ai  (or your usual Grok install path)

        \(mark(grokIn))  2. Sign in to Grok
              Run  grok login  in a terminal and complete sign-in.
        """
        if apiKeyConfigured() {
            apiStatus?.stringValue = "✅  API key configured — Claude dollar spend is on."
            apiStatus?.textColor = .labelColor
        } else {
            apiStatus?.stringValue = "⬜️  No API key — Claude dollar spend is off."
            apiStatus?.textColor = .secondaryLabelColor
        }
        // Either provider is enough to start; the Admin key is optional.
        let ready = (hasClaude && claudeIn) || (hasGrok && grokIn) || claudeIn || grokIn
        primary?.isEnabled = ready
        if ready {
            var parts: [String] = []
            if claudeIn { parts.append("Claude") }
            if grokIn { parts.append("Grok") }
            status?.stringValue = "Ready (\(parts.joined(separator: " + "))). Admin API key is optional."
        } else {
            status?.stringValue = "Sign in to Claude and/or Grok, then Re-check."
        }
    }

    @objc func copyInstall() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("curl -fsSL https://claude.ai/install.sh | bash", forType: .string)
        status?.stringValue = "Claude install command copied — paste it into a terminal."
    }

    @objc func copyGrokInstall() {
        NSPasteboard.general.clearContents()
        // Grok's install path varies by channel; point people at login once installed.
        NSPasteboard.general.setString("grok login", forType: .string)
        status?.stringValue = "“grok login” copied — paste it into a terminal after installing Grok."
    }

    // MARK: API key — scan / manual / remove

    @objc func openConsole() {
        if let url = URL(string: "https://console.anthropic.com/settings/keys") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func scanForKeys() {
        guard !busy else { return }
        setBusy(true)
        apiStatus?.stringValue = "Scanning…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = KeyScanner.scan()
            DispatchQueue.main.async { self?.setBusy(false); self?.presentScanResults(found) }
        }
    }

    private func setBusy(_ on: Bool) {
        busy = on
        apiButtons.forEach { $0.isEnabled = !on }
    }

    private func presentScanResults(_ found: [FoundKey]) {
        guard let window else { return }
        guard !found.isEmpty else {
            let a = NSAlert()
            a.messageText = "No keys found on this Mac"
            a.informativeText = "Couldn't find an Anthropic key in your shell profiles or "
                + "the ant CLI config. Use “Enter key…” to type one in."
            a.beginSheetModal(for: window) { _ in }
            refresh(); return
        }
        let alert = NSAlert()
        alert.messageText = "Use a key found on this Mac?"
        alert.informativeText = "Only the masked key is shown. Cost reporting needs an "
            + "Admin key (sk-ant-admin); other keys can't read the cost report."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for f in found { popup.addItem(withTitle: "\(f.masked)   —   \(f.source)") }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use This Key")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { self?.refresh(); return }
            self?.validateAndStore(found[popup.indexOfSelectedItem].key)
        }
    }

    @objc func enterKey() {
        guard !busy, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Enter your Admin API key"
        alert.informativeText = "Starts with sk-ant-admin. Input is hidden and stored "
            + "only in your macOS Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-admin-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            self?.validateAndStore(key)
        }
    }

    /// Verify the key before storing it. A clear auth rejection (401/403) means
    /// the key is wrong. A network or transient failure must NOT reject a good
    /// key — we store it and let the next refresh confirm it.
    private func validateAndStore(_ key: String) {
        enum Outcome { case ok, invalid, unverified }
        setBusy(true)
        apiStatus?.stringValue = "Verifying key…"
        apiStatus?.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome: Outcome
            do { _ = try self.cost.fetchMonthToDate(adminKey: key); outcome = .ok }
            catch let UsageError.http(code) where code == 401 || code == 403 { outcome = .invalid }
            catch { outcome = .unverified }
            DispatchQueue.main.async {
                self.setBusy(false)
                if outcome != .invalid {
                    try? Keychain.storeAdminKey(key)
                    self.onKeyChanged?()
                }
                self.refresh()
                switch outcome {
                case .unverified:
                    self.apiStatus?.stringValue = "Saved — couldn't reach Anthropic to verify; will check on next refresh."
                    self.apiStatus?.textColor = .secondaryLabelColor
                case .invalid:
                    if let window = self.window {
                        let a = NSAlert()
                        a.messageText = "That key didn't work"
                        a.informativeText = "It was rejected as unauthorized. Make sure it's an "
                            + "Admin key (sk-ant-admin) with billing access."
                        a.beginSheetModal(for: window) { _ in }
                    }
                case .ok:
                    break
                }
            }
        }
    }

    @objc func removeKey() {
        Keychain.deleteAdminKey()
        onKeyChanged?()
        refresh()
    }

    @objc func finish() {
        window?.close()
        onReady?()
    }
}

// MARK: - App

// MARK: - Caffeinate Mode (keep awake + optional lid-shut + hotspot)

/// “Caffeinate Mode” keeps this Mac from sleeping due to idle — desktops and
/// laptops. On a portable Mac, an extra option holds a stronger assertion so
/// work can continue with the lid closed. Optional favorite-hotspot join.
///
/// Security: prefer known/preferred networks and Keychain passwords — never
/// require an admin password. CoreWLAN scans may prompt for Location (system
/// dialog); callers must warn the user first.
final class LaptopModeController {
    static let shared = LaptopModeController()

    /// Short names so they surface cleanly in `pmset -g assertions`.
    static let idleAssertionName = "Usage Monitor Caffeinate"
    static let lidAssertionName = "Usage Monitor Lid Shut"

    private let hotspotKey = "laptopMode.favoriteHotspot"
    private let joinKey = "laptopMode.joinHotspot"
    private let clamshellKey = "laptopMode.clamshell"   // lid-shut option
    private let activeKey = "laptopMode.wasActive"
    private let keychainService = "com.usagemonitor.app.hotspot"

    private var idleAssertionID: IOPMAssertionID = 0
    private var idleAssertionHeld = false
    private var lidAssertionID: IOPMAssertionID = 0
    private var lidAssertionHeld = false
    private var caffeinate: Process?
    private(set) var lastProof: String = ""
    private(set) var lastError: String?

    /// True on MacBooks / portables (internal battery or clamshell hardware).
    static var isPortableMac: Bool = {
        // Internal battery present → almost certainly a laptop.
        let batt = Process()
        batt.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        batt.arguments = ["-r", "-c", "AppleSmartBattery", "-d", "1"]
        let pipe = Pipe()
        batt.standardOutput = pipe
        batt.standardError = FileHandle.nullDevice
        try? batt.run(); batt.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if out.contains("AppleSmartBattery") { return true }
        // Clamshell keys exist on lid-equipped Macs even if battery probe failed.
        let clam = Process()
        clam.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        clam.arguments = ["-r", "-k", "AppleClamshellState", "-d", "1"]
        let pipe2 = Pipe()
        clam.standardOutput = pipe2
        clam.standardError = FileHandle.nullDevice
        try? clam.run(); clam.waitUntilExit()
        let out2 = String(data: pipe2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out2.contains("AppleClamshellState")
    }()

    var favoriteHotspot: String {
        get { UserDefaults.standard.string(forKey: hotspotKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hotspotKey) }
    }

    /// Default on so a configured hotspot is used when activating.
    var joinHotspotOnActivate: Bool {
        get {
            if UserDefaults.standard.object(forKey: joinKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: joinKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: joinKey) }
    }

    /// Laptop only — keep running with the lid closed (stronger sleep block).
    /// Defaults on for portables; forced off on desktops.
    var lidShutOnActivate: Bool {
        get {
            guard Self.isPortableMac else { return false }
            if UserDefaults.standard.object(forKey: clamshellKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: clamshellKey)
        }
        set {
            guard Self.isPortableMac else { return }
            UserDefaults.standard.set(newValue, forKey: clamshellKey)
        }
    }

    /// Back-compat alias used by older menu selectors / self-test.
    var clamshellOnActivate: Bool {
        get { lidShutOnActivate }
        set { lidShutOnActivate = newValue }
    }

    var isActive: Bool {
        get { UserDefaults.standard.bool(forKey: activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }

    /// True when the base keep-awake (caffeinate) assertion is held.
    var caffeinateEngaged: Bool { idleAssertionHeld }
    /// True when the lid-shut (PreventSystemSleep) assertion is held.
    var lidShutEngaged: Bool { lidAssertionHeld }
    /// Back-compat.
    var clamshellEngaged: Bool { lidAssertionHeld || idleAssertionHeld }

    // MARK: activate / deactivate

    @discardableResult
    func activate() -> (ok: Bool, proof: String) {
        lastError = nil
        var lines: [String] = []
        var ok = true

        // 1) Always hold idle keep-awake when Caffeinate Mode is on.
        let idle = engageIdleKeepAwake()
        lines.append(idle.line)
        if !idle.ok { ok = false; lastError = idle.line }

        // 2) Optional lid-shut (portable Macs only).
        if Self.isPortableMac && lidShutOnActivate {
            let lid = engageLidShut()
            lines.append(lid.line)
            if !lid.ok { ok = false; lastError = lid.line }
        } else {
            releaseLidShut()
            if Self.isPortableMac {
                lines.append("Lid shut: off (option disabled)")
            } else {
                lines.append("Lid shut: n/a (desktop Mac)")
            }
        }

        // 3) Optional hotspot join.
        if joinHotspotOnActivate {
            let ssid = favoriteHotspot.trimmingCharacters(in: .whitespacesAndNewlines)
            if ssid.isEmpty {
                lines.append("Hotspot: skipped (set a favorite SSID first)")
            } else {
                let result = joinWiFi(ssid: ssid)
                lines.append(result.line)
                if !result.ok { ok = false; lastError = result.line }
            }
        } else {
            lines.append("Hotspot: skipped (join toggle off)")
        }

        isActive = idleAssertionHeld
        if !isActive {
            lines.append("Caffeinate Mode could not engage keep-awake.")
            ok = false
        }

        lines.append(contentsOf: statusSnapshot())
        lastProof = lines.joined(separator: "\n")
        NSLog("UsageMonitor Caffeinate Mode activate:\n\(lastProof)")
        return (ok, lastProof)
    }

    func deactivate() {
        releaseLidShut()
        releaseIdleKeepAwake()
        isActive = false
        lastProof = (["Caffeinate Mode turned off.", "Sleep assertions released."]
            + statusSnapshot()).joined(separator: "\n")
        NSLog("UsageMonitor Caffeinate Mode deactivate:\n\(lastProof)")
    }

    /// Re-assert after relaunch if the user left Caffeinate Mode on.
    func restoreIfNeeded() {
        guard isActive else { return }
        _ = engageIdleKeepAwake()
        if Self.isPortableMac && lidShutOnActivate { _ = engageLidShut() }
        // Do not force a Wi‑Fi rejoin on every launch — only re-hold sleep.
    }

    // MARK: Wi‑Fi

    func currentSSID() -> String? {
        if let s = CWWiFiClient.shared().interface()?.ssid(), !s.isEmpty { return s }
        // Fallback when CoreWLAN returns nil (common without Location permission).
        guard let dev = wifiDevice() else { return nil }
        let out = shell("/usr/sbin/networksetup -getairportnetwork \(dev)")
        // "Current Wi-Fi Network: Foo" or "You are not associated..."
        if let r = out.range(of: "Current Wi-Fi Network: ") {
            let name = String(out[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    func wifiDevice() -> String? {
        let out = shell("/usr/sbin/networksetup -listallhardwareports")
        var takeNext = false
        for line in out.components(separatedBy: "\n") {
            if line.contains("Wi-Fi") || line.contains("AirPort") {
                takeNext = true
            } else if takeNext, line.hasPrefix("Device:") {
                return line.split(separator: " ").last.map(String.init)
            } else if line.hasPrefix("Hardware Port:") {
                takeNext = false
            }
        }
        return CWWiFiClient.shared().interface()?.interfaceName
    }

    /// Networks this Mac already knows (preferred list) — no admin, no Location.
    func preferredNetworkNames() -> [String] {
        guard let dev = wifiDevice() else { return [] }
        let out = shell("/usr/sbin/networksetup -listpreferredwirelessnetworks \(dev)")
        var names: [String] = []
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("Preferred networks") { continue }
            // Lines are typically "\tSSID"
            names.append(t)
        }
        return names
    }

    /// Nearby SSIDs via CoreWLAN. May trigger Location permission — call only after consent.
    func scanNearbyNetworkNames() -> [String] {
        guard let iface = CWWiFiClient.shared().interface() else { return [] }
        do {
            let nets = try iface.scanForNetworks(withName: nil)
            let names = nets.compactMap { $0.ssid }.filter { !$0.isEmpty }
            return Array(Set(names)).sorted()
        } catch {
            NSLog("UsageMonitor Wi‑Fi scan: \(error.localizedDescription)")
            return []
        }
    }

    private func joinWiFi(ssid: String) -> (ok: Bool, line: String) {
        if let cur = currentSSID(), cur.caseInsensitiveCompare(ssid) == .orderedSame {
            return (true, "Hotspot: already on “\(ssid)”")
        }

        let password = loadHotspotPassword(for: ssid) ?? ""

        // 1) CoreWLAN associate when we can see the network.
        if let iface = CWWiFiClient.shared().interface() {
            do {
                let networks = try iface.scanForNetworks(withName: ssid)
                if let net = networks.first {
                    try iface.associate(to: net, password: password.isEmpty ? nil : password)
                    Thread.sleep(forTimeInterval: 1.2)
                    if let cur = currentSSID(), cur.caseInsensitiveCompare(ssid) == .orderedSame {
                        return (true, "Hotspot: joined “\(ssid)” (CoreWLAN)")
                    }
                }
            } catch {
                NSLog("UsageMonitor CoreWLAN join: \(error.localizedDescription)")
            }
        }

        // 2) networksetup — uses the system preferred-network password when known.
        guard let dev = wifiDevice() else {
            return (false, "Hotspot: no Wi‑Fi device found")
        }
        let escapedSSID = shellEscape(ssid)
        let cmd: String
        if password.isEmpty {
            cmd = "/usr/sbin/networksetup -setairportnetwork \(dev) \(escapedSSID)"
        } else {
            cmd = "/usr/sbin/networksetup -setairportnetwork \(dev) \(escapedSSID) \(shellEscape(password))"
        }
        let out = shell(cmd)
        Thread.sleep(forTimeInterval: 1.5)
        if let cur = currentSSID(), cur.caseInsensitiveCompare(ssid) == .orderedSame {
            return (true, "Hotspot: joined “\(ssid)”")
        }
        let detail = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if password.isEmpty {
            return (false, "Hotspot: could not join “\(ssid)” — set the password under Caffeinate Mode"
                + (detail.isEmpty ? "" : " (\(detail))"))
        }
        return (false, "Hotspot: could not join “\(ssid)”"
            + (detail.isEmpty ? "" : " — \(detail)"))
    }

    // MARK: sleep assertions

    /// Base keep-awake: prevent idle sleep (desktops + laptops).
    private func engageIdleKeepAwake() -> (ok: Bool, line: String) {
        if idleAssertionHeld {
            startCaffeinateHelper(lidShut: lidAssertionHeld)
            return (true, "Caffeinate: already holding NoIdleSleep (#\(idleAssertionID))")
        }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.idleAssertionName as CFString,
            &id)
        guard status == kIOReturnSuccess else {
            return (false, "Caffeinate: failed to create idle assertion (IOReturn \(status))")
        }
        idleAssertionID = id
        idleAssertionHeld = true
        startCaffeinateHelper(lidShut: false)
        return (true, "Caffeinate: system stays awake (NoIdleSleep #\(id))")
    }

    private func releaseIdleKeepAwake() {
        stopCaffeinateHelper()
        if idleAssertionHeld {
            IOPMAssertionRelease(idleAssertionID)
            idleAssertionHeld = false
            idleAssertionID = 0
        }
    }

    /// Stronger: prevent system sleep so a laptop can stay on with the lid shut.
    private func engageLidShut() -> (ok: Bool, line: String) {
        if lidAssertionHeld {
            startCaffeinateHelper(lidShut: true)
            return (true, "Lid shut: already holding PreventSystemSleep (#\(lidAssertionID))")
        }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.lidAssertionName as CFString,
            &id)
        guard status == kIOReturnSuccess else {
            return (false, "Lid shut: failed to create system-sleep assertion (IOReturn \(status))")
        }
        lidAssertionID = id
        lidAssertionHeld = true
        startCaffeinateHelper(lidShut: true)
        return (true, "Lid shut: PreventSystemSleep held (#\(id)) — lid may stay closed")
    }

    private func releaseLidShut() {
        if lidAssertionHeld {
            IOPMAssertionRelease(lidAssertionID)
            lidAssertionHeld = false
            lidAssertionID = 0
        }
        // Downgrade caffeinate helper flags if idle is still held.
        if idleAssertionHeld { startCaffeinateHelper(lidShut: false) }
    }

    /// `caffeinate` helper mirrors assertions (belt-and-braces).
    private func startCaffeinateHelper(lidShut: Bool) {
        stopCaffeinateHelper()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -i idle sleep, -d display, -m disk; -s system sleep (AC) when lid-shut
        p.arguments = lidShut ? ["-s", "-i", "-d", "-m"] : ["-i", "-d", "-m"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            caffeinate = p
        } catch {
            NSLog("UsageMonitor caffeinate start failed: \(error)")
            caffeinate = nil
        }
    }

    private func stopCaffeinateHelper() {
        if let p = caffeinate, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        caffeinate = nil
    }

    // MARK: proof / status

    func statusSnapshot() -> [String] {
        var lines: [String] = []
        lines.append("Mode: \(isActive ? "ACTIVE" : "off")")
        lines.append("Hardware: \(Self.isPortableMac ? "laptop / portable" : "desktop")")
        lines.append("Wi‑Fi now: \(currentSSID() ?? "(not associated)")")
        if let fav = optionalNonEmpty(favoriteHotspot) {
            lines.append("Favorite hotspot: \(fav)")
        } else {
            lines.append("Favorite hotspot: (not set)")
        }
        lines.append("Join on activate: \(joinHotspotOnActivate ? "yes" : "no")")
        if Self.isPortableMac {
            lines.append("Lid shut option: \(lidShutOnActivate ? "yes" : "no")")
        }
        lines.append("Idle keep-awake: \(idleAssertionHeld ? "yes #\(idleAssertionID)" : "no")")
        lines.append("Lid-shut assertion: \(lidAssertionHeld ? "yes #\(lidAssertionID)" : "no")")
        if let pid = caffeinate?.processIdentifier {
            lines.append("caffeinate helper: pid \(pid)")
        }
        Thread.sleep(forTimeInterval: 0.35)
        let pm = shell("/usr/bin/pmset -g assertions")
        if idleAssertionHeld && pm.contains(Self.idleAssertionName) {
            lines.append("pmset: caffeinate assertion listed ✓")
        } else if idleAssertionHeld {
            lines.append("pmset: idle assertion held in-process (#\(idleAssertionID))")
        }
        if lidAssertionHeld && pm.contains(Self.lidAssertionName) {
            lines.append("pmset: lid-shut assertion listed ✓")
        } else if lidAssertionHeld {
            lines.append("pmset: lid assertion held in-process (#\(lidAssertionID))")
        }
        if !idleAssertionHeld && !lidAssertionHeld {
            lines.append("pmset: no Caffeinate Mode assertions")
        }
        let batt = shell("/usr/bin/pmset -g batt")
        if batt.lowercased().contains("ac power") {
            lines.append("Power: AC (best for long keep-awake / lid shut)")
        } else if batt.lowercased().contains("battery") {
            lines.append("Power: Battery — will drain; avoid closed bag (heat)")
        }
        return lines
    }

    func refreshProof() -> String {
        lastProof = statusSnapshot().joined(separator: "\n")
        return lastProof
    }

    // MARK: password Keychain (app-scoped; optional)

    func saveHotspotPassword(_ password: String, for ssid: String) {
        let ssid = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else { return }
        let data = password.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: ssid,
        ]
        SecItemDelete(query as CFDictionary)
        if password.isEmpty { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func loadHotspotPassword(for ssid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    func hasStoredPassword(for ssid: String) -> Bool {
        loadHotspotPassword(for: ssid) != nil
    }

    // MARK: helpers

    private func optionalNonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shell(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ""
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    deinit {
        releaseLidShut()
        releaseIdleKeepAwake()
    }
}

// MARK: - Caffeinate Mode notice (modern panel)

/// Compact, modern card explaining that Caffeinate Mode is on (or reminding
/// when the menu-bar glow is clicked). Not a plain NSAlert.
final class CaffeinateNoticeController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onTurnOff: (() -> Void)?

    enum Kind { case activated, reminder }

    func present(kind: Kind, lidShut: Bool, isPortable: Bool, onBattery: Bool) {
        window?.close()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        panel.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        // Accent pill
        let pill = NSTextField(labelWithString: kind == .activated ? "NOW ACTIVE" : "STILL ON")
        pill.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        pill.textColor = NSColor(srgbRed: 1, green: 0.78, blue: 0.28, alpha: 1)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.15, alpha: 0.14).cgColor
        pill.layer?.cornerRadius = 6
        pill.drawsBackground = false
        // Pad via container
        let pillBox = NSView()
        pillBox.wantsLayer = true
        pillBox.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.15, alpha: 0.14).cgColor
        pillBox.layer?.cornerRadius = 6
        pillBox.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        pillBox.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: pillBox.leadingAnchor, constant: 10),
            pill.trailingAnchor.constraint(equalTo: pillBox.trailingAnchor, constant: -10),
            pill.topAnchor.constraint(equalTo: pillBox.topAnchor, constant: 4),
            pill.bottomAnchor.constraint(equalTo: pillBox.bottomAnchor, constant: -4),
        ])
        stack.addArrangedSubview(pillBox)

        let title = NSTextField(labelWithString: "Caffeinate Mode is on")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        stack.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: kind == .activated
            ? "This Mac will stay awake instead of sleeping from idle. Your usage gauges keep running in the menu bar."
            : "Reminder: Caffeinate Mode is still preventing sleep. Click the glowing cup in the menu bar anytime for this note.")
        subtitle.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        subtitle.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(subtitle)

        // Feature rows
        stack.addArrangedSubview(noticeRow(
            symbol: "cup.and.saucer.fill",
            title: "Keeps the system on",
            body: "Desktops and laptops stay awake through idle — same idea as the caffeinate command."))
        if isPortable {
            stack.addArrangedSubview(noticeRow(
                symbol: lidShut ? "laptopcomputer" : "laptopcomputer.slash",
                title: lidShut ? "Lid-shut keep-awake is on" : "Lid-shut keep-awake is off",
                body: lidShut
                    ? "The laptop can keep working with the lid closed (when the system allows)."
                    : "Closing the lid may still sleep the Mac. Turn on “Keep laptop on with lid shut” if you need that."))
        }

        // Warnings card
        let warnCard = NSView()
        warnCard.wantsLayer = true
        warnCard.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0.45, blue: 0.2, alpha: 0.1).cgColor
        warnCard.layer?.cornerRadius = 10
        warnCard.layer?.borderWidth = 1
        warnCard.layer?.borderColor = NSColor(srgbRed: 1, green: 0.5, blue: 0.25, alpha: 0.28).cgColor
        warnCard.translatesAutoresizingMaskIntoConstraints = false
        let warnStack = NSStackView()
        warnStack.orientation = .vertical
        warnStack.alignment = .leading
        warnStack.spacing = 6
        warnStack.translatesAutoresizingMaskIntoConstraints = false
        warnCard.addSubview(warnStack)
        NSLayoutConstraint.activate([
            warnStack.leadingAnchor.constraint(equalTo: warnCard.leadingAnchor, constant: 14),
            warnStack.trailingAnchor.constraint(equalTo: warnCard.trailingAnchor, constant: -14),
            warnStack.topAnchor.constraint(equalTo: warnCard.topAnchor, constant: 12),
            warnStack.bottomAnchor.constraint(equalTo: warnCard.bottomAnchor, constant: -12),
        ])
        let warnTitle = NSTextField(labelWithString: "Please keep in mind")
        warnTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        warnTitle.textColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.4, alpha: 1)
        warnStack.addArrangedSubview(warnTitle)
        var warns = [
            "Let the Mac breathe — don’t leave it running sealed in a bag (heat risk).",
            "Keep-awake uses more power; plug in for long sessions.",
        ]
        if onBattery {
            warns.append("You’re on battery right now — expect faster drain.")
        }
        if lidShut && isPortable {
            warns.append("Lid closed + bag is a bad combo. Open lid or use a hard surface if it gets warm.")
        }
        for w in warns {
            let line = NSTextField(wrappingLabelWithString: "·  \(w)")
            line.font = NSFont.systemFont(ofSize: 12)
            line.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
            line.preferredMaxLayoutWidth = 330
            warnStack.addArrangedSubview(line)
        }
        stack.addArrangedSubview(warnCard)

        // Buttons
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(spacer)

        let offBtn = NSButton(title: "Turn off", target: self, action: #selector(turnOff))
        offBtn.bezelStyle = .rounded
        offBtn.keyEquivalent = ""
        buttons.addArrangedSubview(offBtn)

        let okBtn = NSButton(title: "Got it", target: self, action: #selector(close))
        okBtn.bezelStyle = .rounded
        okBtn.keyEquivalent = "\r"
        if #available(macOS 11, *) {
            okBtn.hasDestructiveAction = false
        }
        buttons.addArrangedSubview(okBtn)
        stack.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
        ])

        panel.contentView = root
        // Size to fit content
        root.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        let h = max(320, fitting.height + 60)
        panel.setContentSize(NSSize(width: 420, height: h))
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }

    private func noticeRow(symbol: String, title: String, body: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        let icon = NSImageView()
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            icon.image = img.withSymbolConfiguration(cfg)
        }
        icon.contentTintColor = NSColor(srgbRed: 1, green: 0.78, blue: 0.28, alpha: 1)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        t.textColor = .white
        let b = NSTextField(wrappingLabelWithString: body)
        b.font = NSFont.systemFont(ofSize: 12)
        b.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        b.preferredMaxLayoutWidth = 320
        col.addArrangedSubview(t)
        col.addArrangedSubview(b)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(col)
        return row
    }

    @objc private func turnOff() {
        window?.close()
        onTurnOff?()
    }

    @objc private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    static func isOnBattery() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "batt"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.lowercased().contains("battery power")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statusMenu = NSMenu()    // built once; rebuilt on open via NSMenuDelegate
    /// Glowing cup in the menu bar while Caffeinate Mode is on — click for reminder.
    var caffeinateStatusItem: NSStatusItem?
    var caffeinateGlowTimer: Timer?
    var caffeinateGlowPhase: CGFloat = 0
    let caffeinateNotice = CaffeinateNoticeController()
    let client = UsageClient()
    let grokClient = GrokUsageClient()
    let codexClient = CodexUsageClient()
    let costClient = CostClient()
    let activityMonitor = ClaudeActivityMonitor()
    let grokActivity = GrokActivityMonitor()
    let codexActivity = CodexActivityMonitor()
    let cursorActivity = CursorActivityMonitor()
    let onboarding = OnboardingController()
    let whatsNew = WhatsNewController()
    let updates = UpdateChecker()
    let laptopMode = LaptopModeController.shared
    let newsletterURL = URL(string: "https://buttondown.com/jaco")!
    let communityURL = URL(string: "https://github.com/jackfieldman/usage-monitor/discussions")!
    var timer: Timer?
    /// Configured provider slots (names, letters, bar placement).
    var providerConfigs: [ProviderConfig] = ProviderStore.load()
    /// Live gauge groups for enabled providers that returned data.
    var providerGauges: [ProviderGauges] = []
    var lastError: String?
    var lastUpdated: Date?
    var updateAvailable: (version: String, page: URL, zip: URL?)?
    var updating = false
    /// Hourly marquee state (“Update available” scrolling across the bar).
    var marqueeTickTimer: Timer?
    var marqueeAnimTimer: Timer?
    var marqueeActive = false
    var marqueeOffset: CGFloat = 0
    var marqueeText = "Update available"
    var marqueeFullWidth: CGFloat = 0
    var monthSpend: Double?
    var costError: String?
    var hasAdminKey = false
    var notifiedHigh = Set<String>()
    /// Unified activity across all providers that have showActivity on.
    var activity: [ActivitySession] = []
    /// True after at least one background activity scan has finished (success or empty).
    var activityScanCompleted = false
    var sessionTimer: Timer?
    /// Serialize activity scans so a slow Claude pass can't stack up.
    private let activityQueue = DispatchQueue(label: "com.usagemonitor.activity", qos: .utility)

    var allGauges: [Gauge] { providerGauges.flatMap(\.gauges) }

    /// Clusters drawn in the menu bar, driven by layout + per-provider showInMenuBar.
    var iconClusters: [IconCluster] {
        let shown = providerGauges.filter { $0.config.showInMenuBar && $0.config.enabled }
        switch ProviderStore.layout {
        case .highestOnly:
            let flat = shown.flatMap { g in g.gauges.map { (g.config, $0) } }
            guard let best = flat.max(by: { $0.1.percent < $1.1.percent }) else { return [] }
            return [IconCluster(letter: best.0.letter, name: best.0.displayName, gauges: [best.1])]
        case .allGauges:
            return shown.map { group in
                IconCluster(letter: group.config.letter, name: group.config.displayName, gauges: group.gauges)
            }
        case .perProvider:
            return shown.compactMap { group in
                guard let g = Self.primaryGauge(for: group) else { return nil }
                return IconCluster(letter: group.config.letter, name: group.config.displayName, gauges: [g])
            }
        }
    }

    /// Which gauge drives a provider’s letter+% in the menu bar.
    /// Empty preference → that provider’s highest; otherwise the named limit.
    static func numberShowsKey(_ providerId: String) -> String { "numberShows.\(providerId)" }

    static func numberShows(for providerId: String) -> String {
        UserDefaults.standard.string(forKey: numberShowsKey(providerId)) ?? ""
    }

    static func setNumberShows(_ label: String, for providerId: String) {
        UserDefaults.standard.set(label, forKey: numberShowsKey(providerId))
    }

    static func primaryGauge(for group: ProviderGauges) -> Gauge? {
        let pref = numberShows(for: group.config.id)
        if !pref.isEmpty, let g = group.gauges.first(where: { $0.label == pref }) {
            return g
        }
        // Kind-aware defaults when “Highest” is selected (or preference stale).
        switch group.config.kind {
        case .grok:
            return group.gauges.first(where: { $0.label == "Grok" })
                ?? group.gauges.max(by: { $0.percent < $1.percent })
        case .codex:
            return group.gauges.first(where: { $0.label == "Codex" })
                ?? group.gauges.max(by: { $0.percent < $1.percent })
        case .claude, .cursor:
            return group.gauges.max(by: { $0.percent < $1.percent })
        }
    }

    /// Flat gauges for shapes that still expect a single list (legacy drawing helpers).
    var iconGauges: [Gauge] { iconClusters.flatMap(\.gauges) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hasAdminKey = apiKeyConfigured()
        notifiedHigh = Set(UserDefaults.standard.stringArray(forKey: "notifiedHigh") ?? [])
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        onboarding.onReady = { [weak self] in self?.poll() }
        onboarding.onKeyChanged = { [weak self] in
            guard let self else { return }
            self.hasAdminKey = apiKeyConfigured()
            self.pollCost()
        }
        WhatsNew.recordLaunch()
        laptopMode.restoreIfNeeded()
        caffeinateNotice.onTurnOff = { [weak self] in self?.deactivateLaptopModeQuiet() }
        render()
        updateCaffeinateGlow()
        poll()
        pollSessions()
        if notifyEnabled && !notifyConfirmed { requestAuthThenConfirm() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Activity cache — keep warm so the menu never blocks on scan.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pollSessions()
        }
        // Update marquee: check every minute whether an hourly scroll is due.
        marqueeTickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.maybeRunUpdateMarquee()
        }
        if let t = marqueeTickTimer { RunLoop.main.add(t, forMode: .common) }
        if !anyProviderSignedIn() { onboarding.present() }
    }

    @objc func openSetup() { onboarding.present() }

    /// Background-only. Never call from menuNeedsUpdate (that freezes the menu
    /// tracking loop and steals the keyboard until the scan finishes).
    ///
    /// Fast providers (Grok registry, Cursor) publish first so the menu is never
    /// stuck on “scanning…” while Claude digests large transcripts.
    func pollSessions() {
        let configs = providerConfigs
        activityQueue.async { [weak self] in
            guard let self else { return }

            // 1) Fast path — Grok + Cursor (+ Codex index) in milliseconds.
            var fast: [ActivitySession] = []
            for cfg in configs where cfg.enabled && cfg.showActivity {
                switch cfg.kind {
                case .grok: fast.append(contentsOf: self.grokActivity.scan(config: cfg))
                case .cursor: fast.append(contentsOf: self.cursorActivity.scan(config: cfg))
                case .codex: fast.append(contentsOf: self.codexActivity.scan(config: cfg))
                case .claude: break
                }
            }
            fast.sort { $0.lastActivity > $1.lastActivity }
            DispatchQueue.main.async {
                // Publish immediately so the menu never sticks on “scanning…”.
                self.activity = fast
                self.activityScanCompleted = true
            }

            // 2) Slow path — Claude transcripts (capped + tail-only on large files).
            var full = fast
            for cfg in configs where cfg.enabled && cfg.showActivity && cfg.kind == .claude {
                full.append(contentsOf: self.activityMonitor.scan(config: cfg))
            }
            full.sort { $0.lastActivity > $1.lastActivity }
            DispatchQueue.main.async {
                self.activity = full
            }
        }
    }

    /// Kick a background refresh when the menu is about to open — do not wait.
    func menuWillOpen(_ menu: NSMenu) {
        pollSessions()
    }

    @objc func poll() {
        pollCost()
        checkForUpdate()
        let configs = providerConfigs
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var groups: [ProviderGauges] = []
            var errors: [String] = []

            for cfg in configs where cfg.enabled {
                switch cfg.kind {
                case .claude:
                    guard signedInToClaude() else { continue }
                    do {
                        let g = try self.client.fetchUsage()
                        if !g.isEmpty { groups.append(ProviderGauges(config: cfg, gauges: g)) }
                    } catch {
                        errors.append("\(cfg.displayName): "
                            + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                    }
                case .grok:
                    guard signedInToGrok() else { continue }
                    do {
                        let g = try self.grokClient.fetchUsage()
                        if !g.isEmpty { groups.append(ProviderGauges(config: cfg, gauges: g)) }
                    } catch {
                        errors.append("\(cfg.displayName): "
                            + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                    }
                case .codex:
                    guard signedInToCodex() else { continue }
                    do {
                        let g = try self.codexClient.fetchUsage()
                        if !g.isEmpty { groups.append(ProviderGauges(config: cfg, gauges: g)) }
                    } catch {
                        errors.append("\(cfg.displayName): "
                            + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                    }
                case .cursor:
                    // No usage gauges yet — activity/open only.
                    continue
                }
            }

            if groups.isEmpty && errors.isEmpty {
                errors.append("No enabled provider is signed in")
            }

            DispatchQueue.main.async {
                let flat = groups.flatMap(\.gauges)
                if !flat.isEmpty {
                    self.checkNotifications(flat)
                    self.providerGauges = groups
                    self.lastUpdated = Date()
                    self.lastError = errors.isEmpty ? nil : errors.joined(separator: " · ")
                } else if self.providerGauges.isEmpty {
                    self.lastError = errors.joined(separator: " · ")
                } else {
                    self.lastError = errors.joined(separator: " · ")
                }
                self.render()
            }
        }
    }

    /// GitHub latest-release check — up to **4× per day** (every 6 hours).
    /// Respects skip-all, skip-version, and pause. Call with `force: true`
    /// from “Check for Updates Now” to ignore the schedule (still honours skip-all
    /// only as a soft preference: force still checks, but won’t surface skipped).
    func checkForUpdate(force: Bool = false) {
        guard UpdatePrefs.shouldNetworkCheck(force: force) else { return }
        // Record attempt so we don't hammer GitHub on repeated polls.
        if !force { UpdatePrefs.lastCheckAt = Date().timeIntervalSince1970 }
        else { UpdatePrefs.lastCheckAt = Date().timeIntervalSince1970 }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let found = self.updates.check()
            DispatchQueue.main.async {
                guard let found else {
                    // No newer release (or network fail) — clear stale banner only on success path.
                    // Keep existing updateAvailable if we already know of one and check failed silently.
                    if force { self.updateAvailable = nil }
                    return
                }
                if UpdatePrefs.shouldSurface(version: found.version) {
                    let isNew = self.updateAvailable?.version != found.version
                    self.updateAvailable = found
                    if UpdatePrefs.autoUpdateEnabled {
                        self.installUpdate()
                    } else {
                        self.notifyUpdateOnce(found.version)
                        // First sighting: marquee soon (don't wait a full hour).
                        if isNew { UpdatePrefs.lastMarqueeAt = 0; self.maybeRunUpdateMarquee() }
                    }
                } else {
                    // User skipped this version / paused — don't show.
                    if self.updateAvailable?.version == found.version {
                        self.updateAvailable = nil
                    }
                }
            }
        }
    }

    var autoUpdateEnabled: Bool {
        get { UpdatePrefs.autoUpdateEnabled }
        set { UpdatePrefs.autoUpdateEnabled = newValue }
    }

    @objc func toggleAutoUpdate() {
        autoUpdateEnabled.toggle()
        // Enabling auto-update while paused/skipped still installs if something is pending.
        if autoUpdateEnabled {
            UpdatePrefs.skipAllFuture = false
            if updateAvailable != nil { installUpdate() }
        }
    }

    @objc func checkForUpdateNow() {
        checkForUpdate(force: true)
    }

    @objc func skipThisUpdate() {
        guard let v = updateAvailable?.version else { return }
        UpdatePrefs.skippedVersion = v
        updateAvailable = nil
        stopUpdateMarquee(restore: true)
        render()
    }

    @objc func toggleSkipAllFutureUpdates() {
        UpdatePrefs.skipAllFuture.toggle()
        if UpdatePrefs.skipAllFuture {
            updateAvailable = nil
            stopUpdateMarquee(restore: true)
        }
        render()
    }

    @objc func pauseUpdatesDays(_ sender: NSMenuItem) {
        let days = sender.tag
        guard days > 0 else { return }
        UpdatePrefs.pause(for: days)
        updateAvailable = nil
        stopUpdateMarquee(restore: true)
        render()
    }

    @objc func clearUpdatePause() {
        UpdatePrefs.clearPause()
        checkForUpdate(force: true)
    }

    @objc func resumeUpdateChecks() {
        UpdatePrefs.resumeAll()
        checkForUpdate(force: true)
    }

    /// One notification per version, so a quietly ignored update doesn't nag.
    func notifyUpdateOnce(_ version: String) {
        guard UserDefaults.standard.string(forKey: "notifiedUpdate") != version else { return }
        UserDefaults.standard.set(version, forKey: "notifiedUpdate")
        let c = UNMutableNotificationContent()
        c.title = "Usage Monitor \(version) is available"
        c.body = "Open Updates in the menu — or wait for the menu-bar scroll once an hour."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "update-\(version)", content: c, trigger: nil))
    }

    /// Installs in place and relaunches. Any failure falls back to opening
    /// the release page so the user can update by hand.
    @objc func installUpdate() {
        guard let up = updateAvailable, !updating else { return }
        // Manual install from the Updates menu always allowed if we still hold the release.
        guard let zip = up.zip else { openUpdatePage(); return }
        updating = true
        stopUpdateMarquee(restore: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ok = self.updates.downloadAndInstall(zip)
            DispatchQueue.main.async {
                self.updating = false
                if ok { self.relaunch() } else { self.openUpdatePage() }
            }
        }
    }

    /// Relaunch the (just-replaced) bundle: the `open` runs after we exit.
    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc func openUpdatePage() {
        if let page = updateAvailable?.page {
            NSWorkspace.shared.open(page)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/jackfieldman/usage-monitor/releases")!)
        }
    }

    // MARK: Update marquee (menu bar scroll once per hour)

    /// If an update is pending and an hour has passed, scroll “Update available”.
    func maybeRunUpdateMarquee() {
        guard !marqueeActive, !updating else { return }
        guard let up = updateAvailable, UpdatePrefs.shouldSurface(version: up.version) else { return }
        guard UpdatePrefs.shouldMarquee() else { return }
        startUpdateMarquee(version: up.version)
    }

    func startUpdateMarquee(version: String) {
        guard let button = statusItem.button else { return }
        marqueeActive = true
        UpdatePrefs.lastMarqueeAt = Date().timeIntervalSince1970
        marqueeText = "  Update available · \(version)  ·  open Updates menu  ·  "
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attr = NSAttributedString(string: marqueeText,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        marqueeFullWidth = ceil(attr.size().width)
        marqueeOffset = 0
        // Viewport ≈ current gauges width (or a readable minimum).
        let viewport = max(statusItem.length > 10 ? statusItem.length : 96, 88)
        statusItem.length = viewport

        marqueeAnimTimer?.invalidate()
        marqueeAnimTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.marqueeOffset += 1.6
            // One full pass of the text, then stop.
            if self.marqueeOffset > self.marqueeFullWidth + viewport {
                self.stopUpdateMarquee(restore: true)
                return
            }
            let img = self.marqueeImage(viewport: viewport, offset: self.marqueeOffset, text: self.marqueeText)
            button.image = img
            button.imageScaling = .scaleNone
            button.imagePosition = .imageOnly
            button.appearsDisabled = false
        }
        if let t = marqueeAnimTimer { RunLoop.main.add(t, forMode: .common) }
    }

    func stopUpdateMarquee(restore: Bool) {
        marqueeAnimTimer?.invalidate()
        marqueeAnimTimer = nil
        marqueeActive = false
        marqueeOffset = 0
        if restore { render() }
    }

    private func marqueeImage(viewport: CGFloat, offset: CGFloat, text: String) -> NSImage {
        let h: CGFloat = 18
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let accent = NSColor(srgbRed: 0.35, green: 0.55, blue: 1.0, alpha: 1)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accent]
        let s = NSAttributedString(string: text, attributes: attr)
        let fullW = max(marqueeFullWidth, ceil(s.size().width))
        let img = NSImage(size: NSSize(width: viewport, height: h), flipped: false) { _ in
            // Soft blue wash so it reads as “update”, not a gauge.
            NSColor(srgbRed: 0.25, green: 0.45, blue: 0.95, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 1, width: viewport, height: h - 2),
                         xRadius: 4, yRadius: 4).fill()
            let y = ((h - s.size().height) / 2).rounded()
            // Draw two copies for seamless loop.
            let x0 = -offset
            s.draw(at: NSPoint(x: x0, y: y))
            s.draw(at: NSPoint(x: x0 + fullW, y: y))
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Updates submenu — install, auto, skip, pause.
    func updatesMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Updates", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        // Status line
        if updating {
            sub.addItem(disabled("Status: installing…"))
        } else if let up = updateAvailable, UpdatePrefs.shouldSurface(version: up.version) {
            let row = disabled("Status: \(up.version) available")
            row.attributedTitle = NSAttributedString(
                string: "Status: \(up.version) available",
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor(srgbRed: 0.35, green: 0.55, blue: 1.0, alpha: 1),
                ])
            sub.addItem(row)
        } else if UpdatePrefs.skipAllFuture {
            sub.addItem(disabled("Status: all future updates skipped"))
        } else if UpdatePrefs.isPaused, let until = UpdatePrefs.pauseUntil {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            sub.addItem(disabled("Status: paused until \(fmt.string(from: until))"))
        } else if !UpdatePrefs.skippedVersion.isEmpty {
            sub.addItem(disabled("Status: skipped \(UpdatePrefs.skippedVersion)"))
        } else {
            sub.addItem(disabled("Status: up to date"))
        }

        sub.addItem(.separator())

        if let up = updateAvailable, UpdatePrefs.shouldSurface(version: up.version) {
            if updating {
                sub.addItem(disabled("Updating to \(up.version)…"))
            } else {
                let now = NSMenuItem(title: "Update to \(up.version) Now",
                                     action: #selector(installUpdate), keyEquivalent: "")
                now.target = self
                sub.addItem(now)
                let page = NSMenuItem(title: "Release page…",
                                      action: #selector(openUpdatePage), keyEquivalent: "")
                page.target = self
                sub.addItem(page)
            }
            sub.addItem(.separator())
        }

        let auto = NSMenuItem(title: "Install Updates Automatically",
                              action: #selector(toggleAutoUpdate), keyEquivalent: "")
        auto.target = self
        auto.state = autoUpdateEnabled ? .on : .off
        auto.toolTip = "When on, a found update downloads, signature-checks, and installs without asking."
        sub.addItem(auto)

        let check = NSMenuItem(title: "Check for Updates Now",
                               action: #selector(checkForUpdateNow), keyEquivalent: "")
        check.target = self
        check.toolTip = "Checks GitHub now (normally 4 times per day)."
        sub.addItem(check)

        sub.addItem(.separator())

        if let up = updateAvailable {
            let skipOne = NSMenuItem(title: "Skip This Version (\(up.version))",
                                     action: #selector(skipThisUpdate), keyEquivalent: "")
            skipOne.target = self
            skipOne.toolTip = "Hide this release. You’ll still hear about later versions."
            sub.addItem(skipOne)
        } else if !UpdatePrefs.skippedVersion.isEmpty {
            let skipped = NSMenuItem(title: "Clear Skip for \(UpdatePrefs.skippedVersion)",
                                     action: #selector(resumeUpdateChecks), keyEquivalent: "")
            skipped.target = self
            sub.addItem(skipped)
        }

        let skipAll = NSMenuItem(title: "Skip All Future Updates",
                                 action: #selector(toggleSkipAllFutureUpdates), keyEquivalent: "")
        skipAll.target = self
        skipAll.state = UpdatePrefs.skipAllFuture ? .on : .off
        skipAll.toolTip = "Stops checking and banners. Turn off anytime, or use Check for Updates Now."
        sub.addItem(skipAll)

        // Pause submenu
        let pauseRoot = NSMenuItem(title: "Pause Updates", action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        let pauses: [(String, Int)] = [
            ("For 1 day", 1),
            ("For 3 days", 3),
            ("For 1 week", 7),
            ("For 2 weeks", 14),
            ("For 4 weeks", 28),
        ]
        for (title, days) in pauses {
            let i = NSMenuItem(title: title, action: #selector(pauseUpdatesDays(_:)), keyEquivalent: "")
            i.target = self
            i.tag = days
            pauseMenu.addItem(i)
        }
        if UpdatePrefs.isPaused {
            pauseMenu.addItem(.separator())
            let clear = NSMenuItem(title: "Resume Now", action: #selector(clearUpdatePause), keyEquivalent: "")
            clear.target = self
            pauseMenu.addItem(clear)
        }
        pauseRoot.submenu = pauseMenu
        pauseRoot.toolTip = "Temporarily stop checks and the menu-bar scroll."
        sub.addItem(pauseRoot)

        if UpdatePrefs.skipAllFuture || UpdatePrefs.isPaused || !UpdatePrefs.skippedVersion.isEmpty {
            sub.addItem(.separator())
            let resume = NSMenuItem(title: "Resume Normal Update Checks",
                                    action: #selector(resumeUpdateChecks), keyEquivalent: "")
            resume.target = self
            sub.addItem(resume)
        }

        sub.addItem(.separator())
        sub.addItem(disabled("Checks ~4× per day · scroll once per hour when pending"))

        root.submenu = sub
        // Badge the parent when an update is waiting.
        if let up = updateAvailable, UpdatePrefs.shouldSurface(version: up.version), !updating {
            let attr = NSMutableAttributedString(
                string: "Updates  ·  ",
                attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
            attr.append(NSAttributedString(
                string: up.version,
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor(srgbRed: 0.35, green: 0.55, blue: 1.0, alpha: 1),
                ]))
            root.attributedTitle = attr
        }
        return root
    }

    @objc func openNewsletter() { NSWorkspace.shared.open(newsletterURL) }
    @objc func openCommunity() { NSWorkspace.shared.open(communityURL) }

    /// Menu row: “What's New” with a solid NEW chip while this version is unread.
    func whatsNewMenuItem() -> NSMenuItem {
        let i = NSMenuItem(title: "What's New", action: #selector(showWhatsNew), keyEquivalent: "")
        i.target = self
        if WhatsNew.hasUnseen || WhatsNew.isNew(.whatsNewPanel) {
            i.image = WhatsNew.newChipImage(height: 15, light: false)
            i.toolTip = "New since your previous version — open to review"
        } else {
            i.toolTip = "Release notes for Usage Monitor"
        }
        return i
    }

    @objc func showWhatsNew() {
        whatsNew.present()
        // Rebuild next open so the chip disappears after “Got it” / open.
    }

    func pollCost() {
        guard hasAdminKey else { monthSpend = nil; costError = nil; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let key = Keychain.readAdminKey() else { return }
            do {
                let usd = try self.costClient.fetchMonthToDate(adminKey: key)
                DispatchQueue.main.async { self.monthSpend = usd; self.costError = nil; self.render() }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async { self.costError = msg; self.render() }
            }
        }
    }

    func render() {
        // Don't stomp the hourly “Update available” scroll mid-animation.
        if marqueeActive { return }
        guard let button = statusItem.button else { return }
        let clusters = iconClusters
        if clusters.isEmpty {
            applyMenuBarImage(warningImage(), to: statusItem, button: button)
            button.toolTip = lastError
        } else {
            let img = clusterImage(clusters)
            applyMenuBarImage(img, to: statusItem, button: button)
            var tip: [String] = []
            for group in providerGauges {
                tip.append("— \(group.config.displayName) —")
                tip.append(contentsOf: group.gauges.map { "\($0.label): \(Int($0.percent))%" })
            }
            if let up = updateAvailable, UpdatePrefs.shouldSurface(version: up.version) {
                tip.append("")
                tip.append("Update \(up.version) available — open Updates in the menu")
            }
            if laptopMode.isActive {
                tip.append("")
                tip.append("Caffeinate Mode is on — glowing cup keeps the system awake.")
                if laptopMode.lidShutEngaged {
                    tip.append("Lid-shut keep-awake is also on.")
                }
            }
            button.toolTip = tip.joined(separator: "\n")
        }
        updateCaffeinateGlow()
    }

    /// Pin status-item width to the bitmap so macOS doesn’t pad a “variable” slot
    /// wider than the gauges. Keeps the menu bar lean.
    private func applyMenuBarImage(_ image: NSImage, to item: NSStatusItem, button: NSStatusBarButton) {
        image.isTemplate = false
        // Point size must match pixels-at-1x used when drawing (no extra margin).
        let w = max(1, ceil(image.size.width))
        let h = max(1, ceil(image.size.height))
        image.size = NSSize(width: w, height: h)
        button.image = image
        button.imageScaling = .scaleNone
        button.imagePosition = .imageOnly
        button.appearsDisabled = false
        // Explicit length ≈ image width. `variableLength` often leaves dead air
        // on either side of multi-glyph images.
        item.length = w
    }

    // MARK: Caffeinate glow (menu-bar cup)

    func updateCaffeinateGlow() {
        if laptopMode.isActive {
            if caffeinateStatusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.target = self
                item.button?.action = #selector(caffeinateGlowClicked)
                item.button?.sendAction(on: [.leftMouseUp])
                caffeinateStatusItem = item
            }
            applyCaffeinateGlowImage(alpha: 0.55 + 0.45 * abs(sin(caffeinateGlowPhase)))
            if caffeinateGlowTimer == nil {
                caffeinateGlowTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.caffeinateGlowPhase += 0.12
                    let a = 0.55 + 0.45 * abs(sin(self.caffeinateGlowPhase))
                    self.applyCaffeinateGlowImage(alpha: a)
                }
                if let t = caffeinateGlowTimer {
                    RunLoop.main.add(t, forMode: .common)
                }
            }
            var tip = "Caffeinate Mode is on — click for details"
            if laptopMode.lidShutEngaged { tip += "\nLid-shut keep-awake engaged" }
            caffeinateStatusItem?.button?.toolTip = tip
        } else {
            caffeinateGlowTimer?.invalidate()
            caffeinateGlowTimer = nil
            if let item = caffeinateStatusItem {
                NSStatusBar.system.removeStatusItem(item)
                caffeinateStatusItem = nil
            }
        }
    }

    func applyCaffeinateGlowImage(alpha: CGFloat) {
        guard let button = caffeinateStatusItem?.button else { return }
        let amber = NSColor(srgbRed: 1, green: 0.72, blue: 0.2, alpha: max(0.35, min(1, alpha)))
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            // Soft amber halo
            let halo = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14))
            amber.withAlphaComponent(amber.alphaComponent * 0.35).setFill()
            halo.fill()
            if let cup = NSImage(systemSymbolName: "cup.and.saucer.fill",
                                 accessibilityDescription: "Caffeinate Mode") {
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                let sym = (cup.withSymbolConfiguration(cfg) ?? cup).copy() as! NSImage
                let draw = NSRect(x: 2.5, y: 2.5, width: 11, height: 11)
                sym.isTemplate = true
                // Tint: fill then destinationIn
                NSGraphicsContext.saveGraphicsState()
                amber.set()
                draw.fill()
                sym.draw(in: draw, from: .zero, operation: .destinationIn, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                amber.setFill()
                NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 8, height: 8)).fill()
            }
            return true
        }
        if let item = caffeinateStatusItem {
            applyMenuBarImage(img, to: item, button: button)
            // Cup is a small hit target — allow 1pt either side without looking padded.
            item.length = max(16, ceil(img.size.width))
        }
    }

    @objc func caffeinateGlowClicked() {
        showCaffeinateNotice(kind: .reminder)
    }

    func showCaffeinateNotice(kind: CaffeinateNoticeController.Kind) {
        caffeinateNotice.onTurnOff = { [weak self] in self?.deactivateLaptopModeQuiet() }
        caffeinateNotice.present(
            kind: kind,
            lidShut: laptopMode.lidShutEngaged || (laptopMode.isActive && laptopMode.lidShutOnActivate),
            isPortable: LaptopModeController.isPortableMac,
            onBattery: CaffeinateNoticeController.isOnBattery())
    }

    /// Draws letter-badged clusters, respecting **Icon Shape** for the glyph
    /// next to each letter (`G:▮ 11%` / battery / rings / horizontal).
    /// Layout is intentionally tight — menu-bar real estate is scarce.
    func clusterImage(_ clusters: [IconCluster]) -> NSImage {
        // Classic multi-gauge shapes when one provider shows all its gauges.
        if clusters.count == 1, clusters[0].gauges.count > 1 {
            let gauges = clusters[0].gauges
            let body: NSImage
            switch iconShape {
            case .battery: body = consolidated ? consolidatedImage(gauges) : gaugeImage(gauges)
            case .bars: body = barsImage(gauges)
            case .hbars: body = hbarsImage(gauges)
            case .rings: body = ringsImage(gauges)
            }
            // Prefix the letter badge so multi-gauge still shows C:/G:.
            return letterPrefixed(clusters[0].letter, body: body)
        }

        let comfortable = density == .comfortable
        let h: CGFloat = 18
        // Proportional letter (not full monospaced) — “G:” was wider than it looked.
        let letterFont = NSFont.systemFont(ofSize: comfortable ? 11.5 : 11, weight: .semibold)
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: comfortable ? 11.5 : 11, weight: .medium)
        let gap: CGFloat = comfortable ? 5 : 3          // between providers
        let pad: CGFloat = 0                             // no outer dead air
        let letterGap: CGFloat = comfortable ? 2 : 1.5   // letter → glyph
        let pctGap: CGFloat = comfortable ? 2 : 1.5      // glyph → %
        let ink = NSColor.labelColor

        // Per-cluster glyph size depends on Icon Shape.
        let glyphW: CGFloat = {
            switch iconShape {
            case .bars: return comfortable ? 5.5 : 4.5
            case .hbars: return comfortable ? 16 : 12
            case .rings: return comfortable ? 14 : 12
            case .battery: return comfortable ? 18 : 15
            }
        }()
        let glyphH: CGFloat = comfortable ? 13 : 12

        struct Laid {
            let letter: NSAttributedString
            let pct: NSAttributedString
            let percent: Double
            let width: CGFloat
        }
        let laid: [Laid] = clusters.map { c in
            let used = c.gauges.map(\.percent).max() ?? 0
            let shown = batteryDisplayPercent(used)
            let badge = c.letter.count == 1 ? "\(c.letter):" : c.letter
            let letter = NSAttributedString(string: badge,
                attributes: [.font: letterFont, .foregroundColor: ink])
            let pct = NSAttributedString(string: "\(Int(shown))%",
                attributes: [.font: numFont, .foregroundColor: ink])
            let w = ceil(letter.size().width) + letterGap + glyphW + pctGap + ceil(pct.size().width)
            return Laid(letter: letter, pct: pct, percent: used, width: w)
        }
        // No trailing gap after the last cluster (only between items).
        let total = pad * 2 + laid.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, laid.count - 1))

        let shape = iconShape
        let img = NSImage(size: NSSize(width: total, height: h), flipped: false) { [weak self] _ in
            guard let self else { return false }
            var x = pad
            for (idx, item) in laid.enumerated() {
                let ly = ((h - item.letter.size().height) / 2).rounded()
                item.letter.draw(at: NSPoint(x: x, y: ly))
                x += ceil(item.letter.size().width) + letterGap

                let gy = ((h - glyphH) / 2).rounded()
                let gRect = NSRect(x: x, y: gy, width: glyphW, height: glyphH)
                self.drawShapeGlyph(shape, usedPercent: item.percent, in: gRect)
                x += glyphW + pctGap

                let py = ((h - item.pct.size().height) / 2).rounded()
                item.pct.draw(at: NSPoint(x: x, y: py))
                x += ceil(item.pct.size().width)
                if idx < laid.count - 1 { x += gap }
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Mini gauge for one percent, matching the selected Icon Shape.
    /// `usedPercent` is always “% of limit used”; battery fill mode may invert length.
    private func drawShapeGlyph(_ shape: IconShape, usedPercent: Double, in rect: NSRect) {
        let fillPct = shape == .battery ? batteryDisplayPercent(usedPercent) : usedPercent
        let p = max(0, min(100, fillPct)) / 100
        // Severity colour always tracks usage, even when the bar shows remaining.
        let colorPct = usedPercent
        switch shape {
        case .bars:
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2).fill()
            if p > 0 {
                let bh = max(rect.width, rect.height * p)
                fillColor(colorPct).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: bh),
                             xRadius: rect.width / 2, yRadius: rect.width / 2).fill()
            }
        case .hbars:
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            if p > 0 {
                let bw = max(rect.height, rect.width * p)
                fillColor(colorPct).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: bw, height: rect.height),
                             xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            }
        case .rings:
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r = min(rect.width, rect.height) / 2 - 1.2
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.2
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            track.stroke()
            if p > 0.01 {
                let arc = NSBezierPath()
                arc.lineWidth = 2.2
                arc.lineCapStyle = .round
                arc.appendArc(withCenter: c, radius: r,
                              startAngle: 90, endAngle: 90 - p * 360, clockwise: true)
                fillColor(colorPct).setStroke()
                arc.stroke()
            }
        case .battery:
            let body = rect.insetBy(dx: 0, dy: 1)
            let tint = NSColor.labelColor.withAlphaComponent(0.5)
            let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: 2, yRadius: 2)
            outline.lineWidth = 1
            tint.setStroke()
            outline.stroke()
            let cap = NSRect(x: body.maxX + 0.5, y: body.midY - 2, width: 1.5, height: 4)
            tint.setFill()
            NSBezierPath(roundedRect: cap, xRadius: 0.5, yRadius: 0.5).fill()
            if p > 0 {
                let inner = body.insetBy(dx: 2, dy: 2)
                let w = max(1, inner.width * p)
                fillColor(colorPct).setFill()
                NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height),
                             xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    /// Prepends a bold letter badge to a classic multi-gauge image.
    private func letterPrefixed(_ letter: String, body: NSImage) -> NSImage {
        let badge = letter.count == 1 ? "\(letter):" : letter
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let s = NSAttributedString(string: badge,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let gap: CGFloat = 2, pad: CGFloat = 0
        let h = max(18, body.size.height)
        let w = pad + ceil(s.size().width) + gap + body.size.width + pad
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let ly = ((h - s.size().height) / 2).rounded()
            s.draw(at: NSPoint(x: pad, y: ly))
            let bx = pad + ceil(s.size().width) + gap
            let by = ((h - body.size.height) / 2).rounded()
            body.draw(in: NSRect(x: bx, y: by, width: body.size.width, height: body.size.height))
            return true
        }
        img.isTemplate = false
        return img
    }

    // MARK: notifications — alert when a limit crosses into the red zone

    var notifyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "notifyEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "notifyEnabled") }
    }
    /// Whether we've shown the one-time "notifications are on" confirmation.
    var notifyConfirmed: Bool {
        get { UserDefaults.standard.bool(forKey: "notifyConfirmed") }
        set { UserDefaults.standard.set(newValue, forKey: "notifyConfirmed") }
    }

    @objc func toggleNotify() {
        notifyEnabled.toggle()
        if notifyEnabled {
            requestAuthThenConfirm()
        } else {
            // Turning off clears our stacked banners so they can all be dismissed at once.
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            notifiedHigh.removeAll(); saveNotified()
            notifyConfirmed = false   // re-confirm the next time it's turned on
        }
    }

    /// Requests permission (no re-prompt once decided) and, if granted, posts a
    /// single confirmation so you can see notifications work — once per enable.
    func requestAuthThenConfirm() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                guard let self, !self.notifyConfirmed else { return }
                self.notifyConfirmed = true
                let c = UNMutableNotificationContent()
                c.title = "Usage Monitor"
                c.body = "Notifications are on — I'll alert you when a limit passes 80%."
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "usage-confirm", content: c, trigger: nil))
            }
        }
    }

    /// Returns the gauges that just crossed from below 80% to 80%+ (so each
    /// crossing alerts once), updating `notified` in place. Pure + testable.
    static func newlyHigh(_ gauges: [Gauge], notified: inout Set<String>) -> [Gauge] {
        var crossed: [Gauge] = []
        for g in gauges {
            if g.percent >= 80 {
                if notified.insert(g.label).inserted { crossed.append(g) }
            } else {
                notified.remove(g.label)   // dropped back; allow a fresh alert later
            }
        }
        return crossed
    }

    private func saveNotified() {
        UserDefaults.standard.set(Array(notifiedHigh), forKey: "notifiedHigh")
    }

    func checkNotifications(_ gauges: [Gauge]) {
        guard notifyEnabled else {
            if !notifiedHigh.isEmpty { notifiedHigh.removeAll(); saveNotified() }
            return
        }
        let crossed = Self.newlyHigh(gauges, notified: &notifiedHigh)
        saveNotified()   // persist so a relaunch doesn't re-alert a still-maxed limit
        for g in crossed {
            let c = UNMutableNotificationContent()
            c.title = "Usage — \(g.label)"
            c.body = "You're at \(Int(g.percent))% of your \(g.label.lowercased()) limit."
            let id = "usage-\(g.label)"
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
    }

    var consolidated: Bool {
        get { UserDefaults.standard.bool(forKey: "consolidatedView") }
        set { UserDefaults.standard.set(newValue, forKey: "consolidatedView") }
    }

    @objc func toggleConsolidated() {
        consolidated.toggle()
        render()
    }

    var iconShape: IconShape {
        get { IconShape(rawValue: UserDefaults.standard.string(forKey: "iconShape") ?? "") ?? .bars }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "iconShape") }
    }

    var batteryFill: BatteryFillMode {
        get { BatteryFillMode(rawValue: UserDefaults.standard.string(forKey: "batteryFill") ?? "") ?? .used }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "batteryFill") }
    }

    /// Horizontal bars only work cleanly with a single menu-bar cluster
    /// (one provider / one glyph group). Multi-provider letter rows break the layout.
    var horizontalBarsAvailable: Bool {
        iconClusters.count <= 1
    }

    /// Convert stored “% used” into the value that drives battery fill + number.
    /// Colour severity always stays based on *used* (high usage → red).
    func batteryDisplayPercent(_ used: Double) -> Double {
        guard iconShape == .battery else { return used }
        switch batteryFill {
        case .used: return used
        case .remaining: return max(0, min(100, 100 - used))
        }
    }

    /// Which limit's percent the single-glyph shapes (bars/rings/consolidated)
    /// show beside the icon. Empty = the highest of all limits.
    /// Legacy single global number pick — only used when exactly one provider
    /// is on the bar and layout is allGauges/highestOnly. Multi-provider uses
    /// per-slot `numberShows.<id>` instead.
    var numberLabel: String {
        get { UserDefaults.standard.string(forKey: "numberLabel") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "numberLabel") }
    }

    /// representedObject: ["id": providerId, "label": gaugeLabel or ""]
    @objc func pickNumber(_ sender: NSMenuItem) {
        if let obj = sender.representedObject as? [String: String], let id = obj["id"] {
            Self.setNumberShows(obj["label"] ?? "", for: id)
            render()
            return
        }
        // Back-compat: bare string was the global numberLabel.
        if let label = sender.representedObject as? String {
            numberLabel = label
            if let only = providerGauges.first, providerGauges.count == 1 {
                Self.setNumberShows(label, for: only.config.id)
            }
            render()
        }
    }

    func displayPercent(_ gauges: [Gauge]) -> Double {
        // Single-glyph helpers (allGauges classic shapes): prefer the sole
        // provider’s per-slot pick, then legacy global, then max.
        if let only = providerGauges.first, providerGauges.count == 1 {
            let pref = Self.numberShows(for: only.config.id)
            if !pref.isEmpty, let g = gauges.first(where: { $0.label == pref })
                ?? only.gauges.first(where: { $0.label == pref }) {
                return g.percent
            }
        }
        if !numberLabel.isEmpty {
            if let g = gauges.first(where: { $0.label == numberLabel }) { return g.percent }
            if let g = allGauges.first(where: { $0.label == numberLabel }) { return g.percent }
        }
        return gauges.map(\.percent).max() ?? 0
    }

    @objc func pickShape(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let shape = IconShape(rawValue: raw) else { return }
        if shape == .hbars && !horizontalBarsAvailable {
            return   // disabled item; ignore
        }
        iconShape = shape
        render()
    }

    @objc func pickBatteryFill(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let mode = BatteryFillMode(rawValue: raw) {
            batteryFill = mode
            render()
        }
    }

    var density: Density {
        get { Density(rawValue: UserDefaults.standard.string(forKey: "density") ?? "") ?? .compact }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "density") }
    }

    @objc func pickDensity(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let d = Density(rawValue: raw) {
            density = d
        }
        render()
    }

    var iconStyle: IconStyle {
        get { IconStyle(rawValue: UserDefaults.standard.string(forKey: "iconStyle") ?? "") ?? .greyscale }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "iconStyle") }
    }

    @objc func pickStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = IconStyle(rawValue: raw) {
            iconStyle = style
        }
        render()
    }

    /// Charge-bar colour for the current icon style. Greyscale encodes the
    /// level as lightness; System Battery is monochrome until the red zone,
    /// like the macOS battery icon.
    func fillColor(_ pct: Double) -> NSColor {
        switch iconStyle {
        case .colour: return levelColor(pct)
        case .greyscale:
            switch Level(pct) {
            case .high: return .labelColor
            case .mid:  return NSColor.labelColor.withAlphaComponent(0.62)
            case .low:  return NSColor.labelColor.withAlphaComponent(0.38)
            }
        case .battery:
            return Level(pct) == .high ? levelColor(pct) : .labelColor
        }
    }

    // MARK: menu

    /// Rebuilt each time the menu opens — uses **cached** activity only.
    /// Heavy scans run in the background (pollSessions / menuWillOpen).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // —— Terminal / CLI sessions first (what you click to jump) ——
        addActivitySection(to: menu)

        // —— Usage gauges ——
        if providerGauges.isEmpty, let err = lastError {
            menu.addItem(.separator())
            menu.addItem(disabled("⚠︎  \(err)"))
            if err.lowercased().contains("signed") {
                menu.addItem(disabled("Sign in to a provider, then Refresh."))
            }
        } else if !providerGauges.isEmpty {
            menu.addItem(.separator())
            for (idx, group) in providerGauges.enumerated() {
                if idx > 0 { menu.addItem(.separator()) }
                let header = "\(group.config.letter):  \(group.config.displayName)"
                menu.addItem(disabled(header))
                for g in group.gauges {
                    let sub = g.sub.isEmpty ? "" : "   ·  \(g.sub)"
                    let row = disabled("\(g.label):  \(Int(g.percent))%\(sub)")
                    row.image = dotImage(levelColor(g.percent))
                    menu.addItem(row)
                }
            }
            if let err = lastError {
                menu.addItem(disabled("⚠︎  \(err) (showing last good data)"))
            }
        }
        if hasAdminKey {
            menu.addItem(.separator())
            menu.addItem(disabled("Claude API spend (this month)"))
            if let usd = monthSpend { menu.addItem(disabled(String(format: "$%.2f used", usd))) }
            if let err = costError {
                menu.addItem(disabled(monthSpend == nil ? "⚠︎  \(err)"
                                                        : "⚠︎  \(err) (showing last good data)"))
            } else if monthSpend == nil {
                menu.addItem(disabled("Loading…"))
            }
        }

        if let updated = lastUpdated {
            menu.addItem(.separator())
            menu.addItem(disabled("Updated \(relative(updated))"))
        }
        menu.addItem(.separator())
        menu.addItem(whatsNewMenuItem())
        menu.addItem(updatesMenuItem())
        menu.addItem(item("Refresh now", #selector(poll), "r"))

        // Caffeinate Mode — keep awake + optional lid-shut + hotspot.
        menu.addItem(laptopModeMenuItem())

        // Providers — names, letters, what goes in the bar.
        menu.addItem(providersMenuItem())

        let layoutItem = NSMenuItem(title: "Menu Bar Layout", action: nil, keyEquivalent: "")
        WhatsNew.applyFeatureChip(layoutItem, .menuBarLayout)
        let layoutMenu = NSMenu()
        for layout in MenuBarLayout.allCases {
            let i = NSMenuItem(title: layout.title, action: #selector(pickLayout(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = layout.rawValue
            i.state = layout == ProviderStore.layout ? .on : .off
            layoutMenu.addItem(i)
        }
        layoutItem.submenu = layoutMenu
        menu.addItem(layoutItem)

        let shapeItem = NSMenuItem(title: "Icon Shape", action: nil, keyEquivalent: "")
        let shapeMenu = NSMenu()
        shapeMenu.autoenablesItems = false   // honour isEnabled greying
        let multiCluster = !horizontalBarsAvailable
        for shape in IconShape.allCases {
            let i = NSMenuItem(title: shape.title, action: #selector(pickShape(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = shape.rawValue
            i.state = shape == iconShape ? .on : .off
            if shape == .hbars && multiCluster {
                i.isEnabled = false
                i.state = .off
                // Grey title (isEnabled alone is subtle in some themes).
                let grey = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
                i.attributedTitle = NSAttributedString(
                    string: "\(shape.title)  (limited to 1 provider)",
                    attributes: [
                        .font: NSFont.menuFont(ofSize: 0),
                        .foregroundColor: grey,
                    ])
                i.toolTip = "Horizontal bars work with a single provider on the menu bar.\nTurn off extra providers under Providers → Show in Menu Bar, or use Menu Bar Layout → Highest Only."
            }
            shapeMenu.addItem(i)
        }
        if iconShape == .hbars && multiCluster {
            iconShape = .bars
            render()
        }
        shapeItem.submenu = shapeMenu
        menu.addItem(shapeItem)
        if iconShape == .battery {
            let fillItem = NSMenuItem(title: "Battery Fill", action: nil, keyEquivalent: "")
            let fillMenu = NSMenu()
            for mode in BatteryFillMode.allCases {
                let i = NSMenuItem(title: mode.title, action: #selector(pickBatteryFill(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = mode.rawValue
                i.state = mode == batteryFill ? .on : .off
                i.toolTip = mode.subtitle
                fillMenu.addItem(i)
            }
            fillItem.submenu = fillMenu
            menu.addItem(fillItem)

            let combined = item("Consolidated Icon", #selector(toggleConsolidated), "")
            combined.state = consolidated ? .on : .off
            menu.addItem(combined)
        }
        let styleItem = NSMenuItem(title: "Icon Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for style in IconStyle.allCases {
            let i = NSMenuItem(title: style.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = style.rawValue
            i.state = style == iconStyle ? .on : .off
            styleMenu.addItem(i)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)
        let densityItem = NSMenuItem(title: "Density", action: nil, keyEquivalent: "")
        let densityMenu = NSMenu()
        for d in Density.allCases {
            let i = NSMenuItem(title: d.title, action: #selector(pickDensity(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = d.rawValue
            i.state = d == density ? .on : .off
            densityMenu.addItem(i)
        }
        densityItem.submenu = densityMenu
        menu.addItem(densityItem)
        // Per-provider “which % under C:/G:” — a flat Claude+Grok list is nonsense
        // when both are on the bar.
        menu.addItem(barPercentMenuItem())
        let notify = item("Notify near a limit (80%)", #selector(toggleNotify), "")
        notify.state = notifyEnabled ? .on : .off
        menu.addItem(notify)
        let login = item("Open at Login", #selector(toggleLogin), "")
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Set Up…", #selector(openSetup), ""))
        menu.addItem(.separator())
        menu.addItem(item("Subscribe to Updates…", #selector(openNewsletter), ""))
        menu.addItem(item("Join the Community…", #selector(openCommunity), ""))
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    // MARK: Caffeinate Mode menu

    /// Warm amber for Active status (not a traffic-light red/green).
    private var caffeinateActiveColor: NSColor {
        NSColor(srgbRed: 0.95, green: 0.62, blue: 0.18, alpha: 1)
    }

    func laptopModeMenuItem() -> NSMenuItem {
        let active = laptopMode.isActive
        let root = NSMenuItem(title: "Caffeinate Mode", action: nil, keyEquivalent: "")
        WhatsNew.applyFeatureChip(root, .laptopMode)
        let status = active ? "Active" : "Off"
        let statusColor = active ? caffeinateActiveColor : NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        let attr = NSMutableAttributedString(
            string: "Caffeinate Mode  ·  ",
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
        attr.append(NSAttributedString(
            string: status,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: statusColor]))
        root.attributedTitle = attr
        root.toolTip = """
        Keeps this Mac awake so it doesn’t sleep from idle — desktops and laptops.
        On a laptop you can also keep it running with the lid closed.
        A glowing cup appears in the menu bar while Active; click it for a reminder.
        """

        let sub = NSMenu()
        sub.autoenablesItems = false

        let wifi = laptopMode.currentSSID() ?? "not associated"
        let fav = laptopMode.favoriteHotspot.trimmingCharacters(in: .whitespacesAndNewlines)
        let favLabel = fav.isEmpty ? "(not set)" : fav
        let statusText: String
        if active {
            statusText = laptopMode.lidShutEngaged
                ? "Status: Active — system on + lid-shut keep-awake"
                : "Status: Active — system stays awake"
        } else {
            statusText = "Status: Off — Mac may sleep as usual"
        }
        let statusRow = disabled(statusText)
        if active {
            statusRow.attributedTitle = NSAttributedString(
                string: statusText,
                attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: caffeinateActiveColor])
        }
        sub.addItem(statusRow)
        sub.addItem(disabled("Wi‑Fi: \(wifi)"))
        sub.addItem(disabled("Favorite hotspot: \(favLabel)"))
        sub.addItem(.separator())

        if active {
            let off = NSMenuItem(title: "Turn Off Caffeinate Mode",
                                 action: #selector(deactivateLaptopMode), keyEquivalent: "")
            off.target = self
            sub.addItem(off)
            let remind = NSMenuItem(title: "Show Active Notice…",
                                    action: #selector(showCaffeinateReminderFromMenu), keyEquivalent: "")
            remind.target = self
            sub.addItem(remind)
        } else {
            var title = "Turn On Caffeinate Mode"
            if !fav.isEmpty && laptopMode.joinHotspotOnActivate {
                title = "Turn On Caffeinate Mode → \(fav)"
            }
            let on = NSMenuItem(title: title, action: #selector(activateLaptopMode), keyEquivalent: "l")
            on.target = self
            on.toolTip = "Prevent idle sleep so this Mac (desktop or laptop) stays on."
            sub.addItem(on)
        }

        sub.addItem(.separator())

        // Lid-shut only on portables — greyed/hidden on desktops.
        if LaptopModeController.isPortableMac {
            let lid = NSMenuItem(title: "Keep laptop on with lid shut",
                                 action: #selector(toggleLaptopClamshell), keyEquivalent: "")
            lid.target = self
            lid.state = laptopMode.lidShutOnActivate ? .on : .off
            lid.toolTip = """
            Extra keep-awake for MacBooks: stronger sleep block so the machine can \
            stay running with the lid closed (when macOS allows). AC power recommended. \
            Don’t seal a running laptop in a bag — it can overheat.
            """
            sub.addItem(lid)
        }

        let join = NSMenuItem(title: "Join favorite hotspot when turning on",
                              action: #selector(toggleLaptopJoinHotspot), keyEquivalent: "")
        join.target = self
        join.state = laptopMode.joinHotspotOnActivate ? .on : .off
        join.toolTip = "When you turn Caffeinate Mode on, also connect to your favorite hotspot."
        sub.addItem(join)

        sub.addItem(.separator())

        let setHot = NSMenuItem(title: "Choose Favorite Hotspot…",
                                action: #selector(setFavoriteHotspot), keyEquivalent: "")
        setHot.target = self
        setHot.toolTip = "Pick from networks this Mac already knows — no admin rights."
        sub.addItem(setHot)

        let setPass = NSMenuItem(title: "Set Hotspot Password…",
                                 action: #selector(setHotspotPassword), keyEquivalent: "")
        setPass.target = self
        if !fav.isEmpty && laptopMode.hasStoredPassword(for: fav) {
            setPass.title = "Set Hotspot Password… (saved)"
        }
        setPass.toolTip = "Optional. Stored in Keychain only. Prefer networks already saved in System Settings."
        sub.addItem(setPass)

        let proof = NSMenuItem(title: "Show Status…",
                               action: #selector(showLaptopModeProof), keyEquivalent: "")
        proof.target = self
        sub.addItem(proof)

        root.submenu = sub
        return root
    }

    @objc func activateLaptopMode() {
        NSApp.activate(ignoringOtherApps: true)
        if laptopMode.joinHotspotOnActivate,
           !laptopMode.favoriteHotspot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let warn = NSAlert()
            warn.messageText = "About to use Wi‑Fi"
            warn.informativeText = """
            Caffeinate Mode will try to join your favorite hotspot using only \
            normal Wi‑Fi APIs (no admin password).

            macOS may show a Location / Wi‑Fi permission prompt so the app can \
            see or join the network. That is system-controlled — Usage Monitor \
            does not request elevated admin rights.

            Continue only if you are ready for that system prompt (if it appears).
            """
            warn.alertStyle = .informational
            warn.addButton(withTitle: "Continue")
            warn.addButton(withTitle: "Cancel")
            guard warn.runModal() == .alertFirstButtonReturn else { return }
        }
        let result = laptopMode.activate()
        render()
        if result.ok {
            showCaffeinateNotice(kind: .activated)
        } else {
            let alert = NSAlert()
            alert.messageText = "Caffeinate Mode — check details"
            alert.informativeText = result.proof
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc func deactivateLaptopMode() {
        deactivateLaptopModeQuiet()
        let alert = NSAlert()
        alert.messageText = "Caffeinate Mode is off"
        alert.informativeText = "Sleep will work normally again. The glowing cup has left the menu bar."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Turn off without an extra alert (used by the modern notice panel).
    func deactivateLaptopModeQuiet() {
        laptopMode.deactivate()
        render()
    }

    @objc func showCaffeinateReminderFromMenu() {
        showCaffeinateNotice(kind: .reminder)
    }

    @objc func toggleLaptopJoinHotspot() {
        laptopMode.joinHotspotOnActivate.toggle()
    }

    @objc func toggleLaptopClamshell() {
        laptopMode.lidShutOnActivate.toggle()
        if laptopMode.isActive { _ = laptopMode.activate(); render() }
    }

    @objc func setFavoriteHotspot() {
        NSApp.activate(ignoringOtherApps: true)

        // Prefer known networks (no admin, no Location). Optional scan after consent.
        var names = laptopMode.preferredNetworkNames()
        if let cur = laptopMode.currentSSID(), !names.contains(where: { $0.caseInsensitiveCompare(cur) == .orderedSame }) {
            names.insert(cur, at: 0)
        }

        let askScan = NSAlert()
        askScan.messageText = "Choose favorite hotspot"
        askScan.informativeText = """
        Pick a network this Mac already knows (recommended — no admin rights).

        Or scan for nearby networks: macOS may then ask for Location access so \
        Wi‑Fi names can be listed. We will not request an admin password.
        """
        askScan.addButton(withTitle: "Pick from known networks")
        askScan.addButton(withTitle: "Scan nearby…")
        askScan.addButton(withTitle: "Type name…")
        askScan.addButton(withTitle: "Cancel")
        let pick = askScan.runModal()
        if pick == .alertThirdButtonReturn {
            // Type name
            let alert = NSAlert()
            alert.messageText = "Hotspot name (SSID)"
            alert.informativeText = "Exact Wi‑Fi name. Prefer a network already saved in System Settings."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = laptopMode.favoriteHotspot
            field.placeholderString = "e.g. iPhone hotspot name"
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            laptopMode.favoriteHotspot = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        if pick == .alertSecondButtonReturn {
            // Explicit consent before CoreWLAN scan (Location).
            let consent = NSAlert()
            consent.messageText = "Allow Wi‑Fi scan?"
            consent.informativeText = """
            Next, the app will scan for nearby Wi‑Fi networks using CoreWLAN.

            macOS may show a system Location permission dialog. That is required \
            by Apple to read SSIDs — not an admin password. You can Deny and \
            still pick from known networks.
            """
            consent.addButton(withTitle: "Scan")
            consent.addButton(withTitle: "Cancel")
            guard consent.runModal() == .alertFirstButtonReturn else { return }
            let scanned = laptopMode.scanNearbyNetworkNames()
            for s in scanned where !names.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) {
                names.append(s)
            }
        } else if pick != .alertFirstButtonReturn {
            return
        }

        guard !names.isEmpty else {
            let empty = NSAlert()
            empty.messageText = "No known networks found"
            empty.informativeText = "Join a hotspot once in System Settings, or use “Type name…”."
            empty.addButton(withTitle: "OK")
            empty.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Favorite hotspot"
        alert.informativeText = "Networks known to this Mac (and any just scanned). No admin rights."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        for n in names { popup.addItem(withTitle: n) }
        let favNow = laptopMode.favoriteHotspot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !favNow.isEmpty,
           let idx = names.firstIndex(where: { $0.caseInsensitiveCompare(favNow) == .orderedSame }) {
            popup.selectItem(at: idx)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        laptopMode.favoriteHotspot = popup.titleOfSelectedItem ?? ""
    }

    @objc func setHotspotPassword() {
        var ssid = laptopMode.favoriteHotspot.trimmingCharacters(in: .whitespacesAndNewlines)
        if ssid.isEmpty {
            setFavoriteHotspot()
            ssid = laptopMode.favoriteHotspot.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ssid.isEmpty else { return }
        }
        let alert = NSAlert()
        alert.messageText = "Hotspot password"
        alert.informativeText = "Optional. Stored only in your Keychain for “\(ssid)”. Networks already saved in System Settings often work without this. No admin rights."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Wi‑Fi password"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        laptopMode.saveHotspotPassword(field.stringValue, for: ssid)
    }

    @objc func showLaptopModeProof() {
        let proof = laptopMode.refreshProof()
        let alert = NSAlert()
        alert.messageText = "Caffeinate Mode status"
        alert.informativeText = proof
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy")
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(proof, forType: .string)
        }
    }

    // MARK: Active AI (terminals + desktops)

    /// Real user-facing desktop AI apps (bundle ids).
    /// Note: current `/Applications/ChatGPT.app` is `com.openai.codex` (not a separate Codex GUI).
    private static let desktopAIApps: [(name: String, bundleIds: [String], letter: String)] = [
        ("Claude", ["com.anthropic.claudefordesktop"], "C"),
        ("ChatGPT", [
            "com.openai.codex",       // ChatGPT.app (current branding)
            "com.openai.chat",        // ChatGPT Classic.app
            "com.openai.chat-macos",
            "com.openai.atlas",
        ], "GPT"),
        ("Cursor", ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor", "com.anysphere.cursor"], "U"),
    ]

    struct DesktopAIApp {
        let name: String
        let letter: String
        let bundleId: String
        let pid: Int
    }

    /// NSMenuItem.representedObject must be a class for reliable click delivery.
    final class DesktopAIAppBox: NSObject {
        let app: DesktopAIApp
        init(_ app: DesktopAIApp) { self.app = app }
    }

    /// Only count **regular** foreground apps — not Dock extras, helpers, XPCs.
    private static func isUserFacingDesktopAI(_ r: NSRunningApplication) -> Bool {
        guard r.processIdentifier > 0, !r.isTerminated else { return false }
        // Dock Extra / menu extras / agents are .accessory or .prohibited
        guard r.activationPolicy == .regular else { return false }
        let n = (r.localizedName ?? "").lowercased()
        let bid = (r.bundleIdentifier ?? "").lowercased()
        if n.contains("dock extra") || n.contains("helper") || n.contains("agent") { return false }
        if bid.hasPrefix("com.apple.dock") { return false }
        if bid.contains("chrome-extension") || bid.contains("extension-host") { return false }
        return true
    }

    func runningDesktopAI() -> [DesktopAIApp] {
        var out: [DesktopAIApp] = []
        var seenPids = Set<Int>()
        for app in Self.desktopAIApps {
            for bid in app.bundleIds {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                    .filter(Self.isUserFacingDesktopAI)
                if let r = running.first {
                    let pid = Int(r.processIdentifier)
                    guard !seenPids.contains(pid) else { continue }
                    seenPids.insert(pid)
                    out.append(DesktopAIApp(name: app.name, letter: app.letter,
                                            bundleId: bid, pid: pid))
                    break
                }
            }
        }
        // Exact display-name fallback only (never substring — “Dock Extra (ChatGPT.app)” was a false Live).
        if !out.contains(where: { $0.name == "ChatGPT" }) {
            for r in NSWorkspace.shared.runningApplications where Self.isUserFacingDesktopAI(r) {
                let n = (r.localizedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard n.caseInsensitiveCompare("ChatGPT") == .orderedSame else { continue }
                let pid = Int(r.processIdentifier)
                guard !seenPids.contains(pid) else { continue }
                out.append(DesktopAIApp(name: "ChatGPT", letter: "GPT",
                                        bundleId: r.bundleIdentifier ?? "com.openai.codex",
                                        pid: pid))
                break
            }
        }
        return out
    }

    func addActivitySection(to menu: NSMenu) {
        // Only *live* AI processes — terminals + desktops.
        let liveTerms = activity.filter(\.live)
        let desktops = runningDesktopAI()
        let liveCount = liveTerms.count + desktops.count

        if liveCount == 0 {
            if activityScanCompleted {
                let none = disabled("Active AI  ·  none right now")
                WhatsNew.applyFeatureChip(none, .terminalSessions)
                menu.addItem(none)
            } else {
                let scan = disabled("Active AI  ·  scanning…")
                WhatsNew.applyFeatureChip(scan, .terminalSessions)
                menu.addItem(scan)
            }
            return
        }

        var summary = "Active AI"
        var bits: [String] = []
        if !liveTerms.isEmpty { bits.append("\(liveTerms.count) terminal") }
        if !desktops.isEmpty { bits.append("\(desktops.count) desktop") }
        if !bits.isEmpty { summary += "  ·  " + bits.joined(separator: "  ·  ") }

        let root = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        WhatsNew.applyFeatureChip(root, .terminalSessions)
        root.toolTip = "Live AI terminals and desktop apps — click a row to open."
        root.image = dotImage(levelColor(0))

        let sub = NSMenu()
        sub.autoenablesItems = false

        // —— Terminals ——
        if !liveTerms.isEmpty {
            sub.addItem(disabled("Active AI terminals  ·  click to open"))
            var seenProviders: [String] = []
            for s in liveTerms {
                if !seenProviders.contains(s.providerId) { seenProviders.append(s.providerId) }
            }
            let byProvider = Dictionary(grouping: liveTerms, by: \.providerId)
            for pid in seenProviders {
                guard let rows = byProvider[pid], let first = rows.first else { continue }
                sub.addItem(disabled("  \(first.providerLetter):  \(first.providerName)"))
                let ordered = rows.sorted { $0.lastActivity > $1.lastActivity }
                for s in ordered.prefix(10) {
                    sub.addItem(activityMenuItem(s))
                }
                if ordered.count > 10 {
                    sub.addItem(disabled("  +\(ordered.count - 10) more"))
                }
            }
        }

        // —— Desktops ——
        if !desktops.isEmpty {
            if !liveTerms.isEmpty { sub.addItem(.separator()) }
            sub.addItem(disabled("Active AI desktops  ·  click to open"))
            for d in desktops {
                let i = NSMenuItem(
                    title: "\(d.letter)  \(d.name)  —  Live",
                    action: #selector(openDesktopAI(_:)),
                    keyEquivalent: "")
                i.target = self
                i.representedObject = DesktopAIAppBox(d)
                i.isEnabled = true
                i.image = dotImage(levelColor(0))
                i.toolTip = "Bring \(d.name) to the front (pid \(d.pid))"
                sub.addItem(i)
            }
        }

        root.submenu = sub
        menu.addItem(root)
    }

    func activityMenuItem(_ s: ActivitySession) -> NSMenuItem {
        let working = (s.title?.isEmpty == false) ? s.title! : s.project
        let shortWork = working.count > 48 ? String(working.prefix(46)) + "…" : working
        var path = s.branch.map { "\(s.project) · \($0)" } ?? s.project
        if let model = s.model, !model.isEmpty { path += "  ·  \(model)" }
        let title = "\(s.providerLetter)  \(shortWork)  —  \(path)  ·  Live"

        let i = NSMenuItem(title: title, action: #selector(openActivity(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = ActivitySessionBox(s)
        i.isEnabled = true
        i.image = dotImage(levelColor(0))
        var tip = "Open terminal for this AI session"
        if let pid = s.pid { tip += "\npid \(pid)" }
        if let tty = s.tty, tty != "??" { tip += "  ·  \(tty)" }
        if let cwd = s.cwd { tip += "\n\(cwd)" }
        if let t = s.title { tip += "\n\(t)" }
        i.toolTip = tip
        return i
    }

    @objc func openActivity(_ sender: NSMenuItem) {
        let s: ActivitySession
        if let box = sender.representedObject as? ActivitySessionBox {
            s = box.session
        } else if let direct = sender.representedObject as? ActivitySession {
            s = direct
        } else {
            NSLog("UsageMonitor: openActivity — no session on menu item")
            NSSound.beep()
            return
        }
        let kind = providerConfigs.first(where: { $0.id == s.providerId })?.kind
            ?? ProviderKind(rawValue: s.providerId) ?? .claude
        NSLog("UsageMonitor: openActivity kind=\(kind.rawValue) pid=\(s.pid.map(String.init) ?? "-") tty=\(s.tty ?? "-")")
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessFocus.open(pid: s.pid, tty: s.tty, cwd: s.cwd, providerKind: kind)
        }
    }

    @objc func openDesktopAI(_ sender: NSMenuItem) {
        let box = sender.representedObject as? DesktopAIAppBox
        let name = box?.app.name
        let bid = box?.app.bundleId
        let pid = box?.app.pid
        // Wait for menu tracking to end — mid-menu activate is a no-op on recent macOS.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // 1) Prefer the exact process we listed (if still alive and user-facing).
            if let pid, pid > 0,
               let app = NSRunningApplication(processIdentifier: pid_t(pid)),
               Self.isUserFacingDesktopAI(app) {
                ProcessFocus.activateRunningApp(app)
                return
            }
            // 2) Known bundle id(s) for this product.
            var bids: [String] = []
            if let bid, !bid.isEmpty { bids.append(bid) }
            if let name {
                for entry in Self.desktopAIApps where entry.name == name {
                    bids.append(contentsOf: entry.bundleIds)
                }
            }
            for id in bids {
                if ProcessFocus.activateBundlePublic(id) { return }
            }
            // 3) Launch from /Applications by product name.
            if let name {
                let paths = [
                    "/Applications/\(name).app",
                    "/Applications/\(name) Classic.app",
                    "/System/Applications/\(name).app",
                ]
                for path in paths where FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    return
                }
            }
            NSLog("UsageMonitor: openDesktopAI failed name=\(name ?? "-") bid=\(bid ?? "-") pid=\(pid.map(String.init) ?? "-")")
            NSSound.beep()
        }
    }

    /// Keep activity actions enabled even when the app is inactive.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openActivity(_:)) { return true }
        if menuItem.action == #selector(openDesktopAI(_:)) { return true }
        return true
    }

    // MARK: providers menu

    func providersMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Providers", action: nil, keyEquivalent: "")
        WhatsNew.applyFeatureChip(root, .multiProvider)
        if WhatsNew.isNew(.codexCursor) && !WhatsNew.isNew(.multiProvider) {
            // Only Codex/Cursor is new for this user — still flag Providers.
            root.image = WhatsNew.newChipImage(height: 14, light: true)
            root.toolTip = (root.toolTip ?? "Providers") + "\nIncludes Codex / Cursor"
        }
        let sub = NSMenu()
        for cfg in providerConfigs {
            let row = NSMenuItem(title: "\(cfg.letter):  \(cfg.displayName)", action: nil, keyEquivalent: "")
            let rowMenu = NSMenu()

            let en = NSMenuItem(title: "Enabled", action: #selector(toggleProviderEnabled(_:)), keyEquivalent: "")
            en.target = self; en.representedObject = cfg.id
            en.state = cfg.enabled ? .on : .off
            rowMenu.addItem(en)

            let bar = NSMenuItem(title: "Show in Menu Bar", action: #selector(toggleProviderBar(_:)), keyEquivalent: "")
            bar.target = self; bar.representedObject = cfg.id
            bar.state = cfg.showInMenuBar ? .on : .off
            rowMenu.addItem(bar)

            let act = NSMenuItem(title: "Show Activity", action: #selector(toggleProviderActivity(_:)), keyEquivalent: "")
            act.target = self; act.representedObject = cfg.id
            act.state = cfg.showActivity ? .on : .off
            rowMenu.addItem(act)

            rowMenu.addItem(.separator())
            let rename = NSMenuItem(title: "Rename…", action: #selector(renameProvider(_:)), keyEquivalent: "")
            rename.target = self; rename.representedObject = cfg.id
            rowMenu.addItem(rename)
            let letter = NSMenuItem(title: "Set Letter…", action: #selector(setProviderLetter(_:)), keyEquivalent: "")
            letter.target = self; letter.representedObject = cfg.id
            rowMenu.addItem(letter)
            if providerConfigs.count > 1 {
                let remove = NSMenuItem(title: "Remove", action: #selector(removeProvider(_:)), keyEquivalent: "")
                remove.target = self; remove.representedObject = cfg.id
                rowMenu.addItem(remove)
            }

            row.submenu = rowMenu
            sub.addItem(row)
        }
        sub.addItem(.separator())
        let add = NSMenuItem(title: "Add Provider…", action: #selector(addProvider), keyEquivalent: "")
        add.target = self
        sub.addItem(add)
        root.submenu = sub
        return root
    }

    @objc func toggleProviderEnabled(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ProviderStore.update(id) { $0.enabled.toggle() }
        providerConfigs = ProviderStore.load()
        poll(); pollSessions(); render()
    }
    @objc func toggleProviderBar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ProviderStore.update(id) { $0.showInMenuBar.toggle() }
        providerConfigs = ProviderStore.load()
        // Re-bind configs onto existing gauge groups.
        providerGauges = providerGauges.map { g in
            let cfg = providerConfigs.first(where: { $0.id == g.config.id }) ?? g.config
            return ProviderGauges(config: cfg, gauges: g.gauges)
        }
        render()
    }
    @objc func toggleProviderActivity(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ProviderStore.update(id) { $0.showActivity.toggle() }
        providerConfigs = ProviderStore.load()
        pollSessions()
    }

    @objc func renameProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let cfg = providerConfigs.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename provider"
        alert.informativeText = "Personal name shown in the menu (e.g. “Claude Work”, “Grok Personal”)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = cfg.displayName
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        ProviderStore.update(id) { $0.displayName = name }
        providerConfigs = ProviderStore.load()
        providerGauges = providerGauges.map { g in
            let cfg = providerConfigs.first(where: { $0.id == g.config.id }) ?? g.config
            return ProviderGauges(config: cfg, gauges: g.gauges)
        }
        pollSessions(); render()
    }

    @objc func setProviderLetter(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let cfg = providerConfigs.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Menu-bar letter"
        alert.informativeText = "One character badge next to this provider’s bar (e.g. C, G, W)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        field.stringValue = cfg.letter
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let letter = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let ch = letter.first else { return }
        ProviderStore.update(id) { $0.letter = String(ch) }
        providerConfigs = ProviderStore.load()
        providerGauges = providerGauges.map { g in
            let cfg = providerConfigs.first(where: { $0.id == g.config.id }) ?? g.config
            return ProviderGauges(config: cfg, gauges: g.gauges)
        }
        pollSessions(); render()
    }

    @objc func removeProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let all = providerConfigs.filter { $0.id != id }
        guard !all.isEmpty else { return }
        ProviderStore.save(all)
        providerConfigs = all
        providerGauges = providerGauges.filter { $0.config.id != id }
        poll(); pollSessions(); render()
    }

    @objc func addProvider() {
        let present = Set(providerConfigs.map(\.kind))
        // Prefer kinds not yet added; still allow a second slot of an existing kind
        // (e.g. “Claude Work” + “Claude Personal”) with a unique id.
        let fresh = ProviderKind.allCases.filter { !present.contains($0) }
        let choices: [(title: String, kind: ProviderKind)] = {
            if !fresh.isEmpty {
                return fresh.map { kind in
                    var note = kind.defaultName
                    if kind == .codex { note += "  —  ChatGPT Codex limits" }
                    if kind == .cursor { note += "  —  open app (no % yet)" }
                    return (note, kind)
                }
            }
            return ProviderKind.allCases.map { kind in
                ("Another \(kind.defaultName) slot  (rename it)", kind)
            }
        }()

        let alert = NSAlert()
        alert.messageText = "Add provider"
        alert.informativeText = fresh.isEmpty
            ? "All built-in adapters are already listed. Add another slot and rename it (e.g. “Claude Work”)."
            : "Pick an adapter. You can rename it and set a letter badge after adding."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        for c in choices {
            popup.addItem(withTitle: c.title)
            popup.lastItem?.representedObject = c.kind.rawValue
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let raw = popup.selectedItem?.representedObject as? String,
              let kind = ProviderKind(rawValue: raw) else { return }
        var all = providerConfigs
        var cfg = ProviderConfig.make(kind)
        if all.contains(where: { $0.id == cfg.id }) {
            cfg.id = "\(kind.rawValue)-\(UUID().uuidString.prefix(6))"
            // Nudge the name so two slots aren't identical in the menu.
            let n = all.filter { $0.kind == kind }.count + 1
            cfg.displayName = "\(kind.defaultName) \(n)"
        }
        // Cursor is activity/open only — don't waste menu-bar space by default.
        if kind == .cursor { cfg.showInMenuBar = false }
        all.append(cfg)
        ProviderStore.save(all)
        providerConfigs = all
        poll(); pollSessions(); render()
    }

    @objc func pickLayout(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let layout = MenuBarLayout(rawValue: raw) {
            ProviderStore.layout = layout
            render()
        }
    }

    /// Menu: “Bar % Shows” → one submenu per provider on the bar
    /// (`C: Claude` → Highest / Session / …). Each letter’s percent follows its own pick.
    func barPercentMenuItem() -> NSMenuItem {
        let multi = providerGauges.filter { $0.config.showInMenuBar && $0.config.enabled }.count > 1
            || ProviderStore.layout == .perProvider
        let title = multi ? "Bar % Shows" : "Number Shows"
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        WhatsNew.applyFeatureChip(root, .barPercent)
        let sub = NSMenu()

        let groups = providerGauges.filter { $0.config.enabled && !$0.gauges.isEmpty }
        if groups.isEmpty {
            sub.addItem(disabled("No gauges yet"))
            root.submenu = sub
            return root
        }

        if multi {
            // One nested menu per provider — never mix Session with Grok Build.
            for group in groups {
                let head = "\(group.config.letter):  \(group.config.displayName)"
                let item = NSMenuItem(title: head, action: nil, keyEquivalent: "")
                let nest = NSMenu()
                nest.addItem(numberPickItem(
                    title: "Highest",
                    providerId: group.config.id,
                    label: "",
                    selected: Self.numberShows(for: group.config.id).isEmpty))
                nest.addItem(.separator())
                let pref = Self.numberShows(for: group.config.id)
                for g in group.gauges {
                    nest.addItem(numberPickItem(
                        title: "\(g.label)  (\(Int(g.percent))%)",
                        providerId: group.config.id,
                        label: g.label,
                        selected: pref == g.label))
                }
                item.submenu = nest
                sub.addItem(item)
            }
            if ProviderStore.layout == .highestOnly {
                sub.addItem(.separator())
                sub.addItem(disabled("Layout “Highest Only” ignores these picks"))
            }
        } else if let group = groups.first {
            // Single provider — flat list, same as classic Number Shows.
            let pref = Self.numberShows(for: group.config.id)
            sub.addItem(numberPickItem(
                title: "Highest",
                providerId: group.config.id,
                label: "",
                selected: pref.isEmpty && numberLabel.isEmpty))
            sub.addItem(.separator())
            for g in group.gauges {
                sub.addItem(numberPickItem(
                    title: g.label,
                    providerId: group.config.id,
                    label: g.label,
                    selected: pref == g.label || (pref.isEmpty && numberLabel == g.label)))
            }
        }

        root.submenu = sub
        return root
    }

    private func numberPickItem(title: String, providerId: String, label: String, selected: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(pickNumber(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = ["id": providerId, "label": label]
        i.state = selected ? .on : .off
        return i
    }

    func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func relative(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    // MARK: launch at login

    var loginEnabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc func toggleLogin() {
        guard #available(macOS 13, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Open at Login toggle failed: \(error)")
        }
        render()
    }

    // MARK: drawing

    func warningImage() -> NSImage {
        let img = NSImage(systemSymbolName: "exclamationmark.triangle",
                          accessibilityDescription: "Usage unavailable")
        img?.isTemplate = true
        return img ?? NSImage()
    }

    func dotImage(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 8, height: 8)).fill()
        img.unlockFocus()
        return img
    }

    /// Battery shell like the system battery icon: 1pt hairline outline,
    /// pixel-aligned, with a small cap nub past the right edge.
    private func drawShell(_ body: NSRect) {
        let tint = NSColor.labelColor.withAlphaComponent(0.5)
        let r = body.height * 0.28
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: r, yRadius: r)
        outline.lineWidth = 1
        tint.setStroke()
        outline.stroke()
        let capH = body.height * 0.36
        let cap = NSRect(x: body.maxX + 1, y: body.midY - capH / 2, width: 1.5, height: capH)
        tint.setFill()
        NSBezierPath(roundedRect: cap, xRadius: 0.75, yRadius: 0.75).fill()
    }

    /// Colour charge bar inside a shell; `usedPercent` drives colour; fill length
    /// follows battery fill mode (used vs remaining).
    private func drawFill(_ track: NSRect, usedPercent: Double) {
        let fillPct = batteryDisplayPercent(usedPercent)
        let w = track.width * max(0, min(100, fillPct)) / 100
        guard w > 0.5 else { return }
        let r = min(2, track.height / 2, w / 2)
        fillColor(usedPercent).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: w, height: track.height),
                     xRadius: r, yRadius: r).fill()
    }

    /// One battery per gauge, with its percentage alongside.
    func gaugeImage(_ gauges: [Gauge]) -> NSImage {
        let h: CGFloat = 18, bodyH: CGFloat = 11
        let bodyW: CGFloat = density == .comfortable ? 28 : 22
        let capExt: CGFloat = 2.0   // gap + cap nub beyond the shell
        let gap: CGFloat = 3, gaugeGap: CGFloat = 6, pad: CGFloat = 0
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let numAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

        let items: [(g: Gauge, s: NSAttributedString, w: CGFloat)] = gauges.map { g in
            let shown = batteryDisplayPercent(g.percent)
            let s = NSAttributedString(string: "\(Int(shown))%", attributes: numAttrs)
            return (g, s, bodyW + capExt + gap + ceil(s.size().width))
        }
        let total = items.isEmpty ? 8
            : pad * 2 + items.reduce(0) { $0 + $1.w } + gaugeGap * CGFloat(items.count - 1)

        return NSImage(size: NSSize(width: total, height: h), flipped: false) { [weak self] _ in
            guard let self else { return false }
            var x = pad
            let by = ((h - bodyH) / 2).rounded()
            for it in items {
                let body = NSRect(x: x, y: by, width: bodyW, height: bodyH)
                self.drawShell(body)
                self.drawFill(body.insetBy(dx: 2, dy: 2), usedPercent: it.g.percent)
                let sy = ((h - it.s.size().height) / 2).rounded()
                it.s.draw(at: NSPoint(x: x + bodyW + capExt + gap, y: sy))
                x += it.w + gaugeGap
            }
            return true
        }
    }

    private func peakLabel(_ gauges: [Gauge]) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let used = displayPercent(gauges)
        let shown = batteryDisplayPercent(used)
        return NSAttributedString(string: "\(Int(shown))%",
                                  attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }

    /// One rounded column per gauge over a faint full-height track,
    /// with the highest percentage alongside.
    func barsImage(_ gauges: [Gauge]) -> NSImage {
        let h: CGFloat = 18, chartH: CGFloat = 13
        let barW: CGFloat = density == .comfortable ? 5.5 : 4
        let barGap: CGFloat = density == .comfortable ? 2 : 1.5
        let gap: CGFloat = 3, pad: CGFloat = 0
        let s = peakLabel(gauges)
        let chartW = barW * CGFloat(gauges.count) + barGap * CGFloat(max(0, gauges.count - 1))
        let total = pad * 2 + chartW + gap + ceil(s.size().width)

        return NSImage(size: NSSize(width: total, height: h), flipped: false) { [weak self] _ in
            guard let self else { return false }
            let baseY = ((h - chartH) / 2).rounded()
            for (i, g) in gauges.enumerated() {
                let x = pad + CGFloat(i) * (barW + barGap)
                NSColor.labelColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: chartH),
                             xRadius: barW / 2, yRadius: barW / 2).fill()
                let p = max(0, min(100, g.percent)) / 100
                if p > 0 {   // 0% shows only the track, matching the battery styles
                    let bh = max(barW, chartH * p)   // min height keeps small values visible
                    self.fillColor(g.percent).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: bh),
                                 xRadius: barW / 2, yRadius: barW / 2).fill()
                }
            }
            let sy = ((h - s.size().height) / 2).rounded()
            s.draw(at: NSPoint(x: pad + chartW + gap, y: sy))
            return true
        }
    }

    /// One horizontal bar per gauge over a faint full-width track, rows
    /// stacked top-to-bottom in gauge order, with the highest percentage
    /// alongside. The sideways twin of barsImage.
    func hbarsImage(_ gauges: [Gauge]) -> NSImage {
        let h: CGFloat = 18, chartH: CGFloat = 14, rowGap: CGFloat = 1.5
        let trackW: CGFloat = density == .comfortable ? 22 : 16
        let gap: CGFloat = 3, pad: CGFloat = 0
        let s = peakLabel(gauges)
        let total = pad * 2 + trackW + gap + ceil(s.size().width)

        return NSImage(size: NSSize(width: total, height: h), flipped: false) { [weak self] _ in
            guard let self else { return false }
            let rows = CGFloat(max(1, gauges.count))
            let rowH = (chartH - rowGap * (rows - 1)) / rows
            let baseY = ((h - chartH) / 2).rounded()
            for (i, g) in gauges.enumerated() {
                let y = baseY + chartH - rowH - CGFloat(i) * (rowH + rowGap)
                NSColor.labelColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: NSRect(x: pad, y: y, width: trackW, height: rowH),
                             xRadius: rowH / 2, yRadius: rowH / 2).fill()
                let p = max(0, min(100, g.percent)) / 100
                if p > 0 {   // 0% shows only the track, matching the other shapes
                    let bw = max(rowH, trackW * p)   // min width keeps small values visible
                    self.fillColor(g.percent).setFill()
                    NSBezierPath(roundedRect: NSRect(x: pad, y: y, width: bw, height: rowH),
                                 xRadius: rowH / 2, yRadius: rowH / 2).fill()
                }
            }
            let sy = ((h - s.size().height) / 2).rounded()
            s.draw(at: NSPoint(x: pad + trackW + gap, y: sy))
            return true
        }
    }

    /// Concentric activity-style rings, outermost = first gauge, sweeping
    /// clockwise from 12 o'clock, with the highest percentage alongside.
    func ringsImage(_ gauges: [Gauge]) -> NSImage {
        let h: CGFloat = 18, d: CGFloat = 15, stroke: CGFloat = 2.0, ringGap: CGFloat = 0.5
        let gap: CGFloat = 3, pad: CGFloat = 0
        let s = peakLabel(gauges)
        let total = pad * 2 + d + gap + ceil(s.size().width)

        return NSImage(size: NSSize(width: total, height: h), flipped: false) { [weak self] _ in
            guard let self else { return false }
            let c = NSPoint(x: pad + d / 2, y: h / 2)
            for (i, g) in gauges.enumerated() {
                let r = d / 2 - stroke / 2 - CGFloat(i) * (stroke + ringGap)
                guard r > stroke / 2 else { break }
                let track = NSBezierPath()
                track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
                track.lineWidth = stroke
                NSColor.labelColor.withAlphaComponent(0.18).setStroke()
                track.stroke()
                let p = max(0, min(100, g.percent)) / 100
                guard p > 0.01 else { continue }
                let arc = NSBezierPath()
                arc.lineWidth = stroke
                arc.lineCapStyle = .round
                arc.appendArc(withCenter: c, radius: r,
                              startAngle: 90, endAngle: 90 - p * 360, clockwise: true)
                self.fillColor(g.percent).setStroke()
                arc.stroke()
            }
            let sy = ((h - s.size().height) / 2).rounded()
            s.draw(at: NSPoint(x: pad + d + gap, y: sy))
            return true
        }
    }

    /// All gauges as stacked colour bars inside a single battery shell,
    /// with the highest percentage alongside.
    func consolidatedImage(_ gauges: [Gauge]) -> NSImage {
        let h: CGFloat = 18, bodyH: CGFloat = 14
        let bodyW: CGFloat = density == .comfortable ? 28 : 24
        let capExt: CGFloat = 2.0, gap: CGFloat = 3, pad: CGFloat = 0
        let s = peakLabel(gauges)
        let total = pad * 2 + bodyW + capExt + gap + ceil(s.size().width)

        return NSImage(size: NSSize(width: total, height: h), flipped: false) { [weak self] _ in
            guard let self else { return false }
            let body = NSRect(x: pad, y: ((h - bodyH) / 2).rounded(), width: bodyW, height: bodyH)
            self.drawShell(body)
            let inner = body.insetBy(dx: 2, dy: 2)
            let barGap: CGFloat = 1
            let rows = CGFloat(gauges.count)
            let barH = (inner.height - barGap * (rows - 1)) / rows
            for (i, g) in gauges.enumerated() {
                let y = inner.maxY - barH - CGFloat(i) * (barH + barGap)
                self.drawFill(NSRect(x: inner.minX, y: y, width: inner.width, height: barH),
                              usedPercent: g.percent)
            }
            let sy = ((h - s.size().height) / 2).rounded()
            s.draw(at: NSPoint(x: body.maxX + capExt + gap, y: sy))
            return true
        }
    }
}

// CLI self-test: prove Caffeinate Mode keep-awake (+ optional lid-shut / Wi‑Fi).
//   UsageMonitor.app/Contents/MacOS/UsageMonitor --laptop-mode-self-test
//   … --laptop-mode-self-test --hotspot "MyPhone"   # also try join
//   … --laptop-mode-self-test --keep                 # leave mode active
if CommandLine.arguments.contains("--laptop-mode-self-test") {
    let lm = LaptopModeController.shared
    let keep = CommandLine.arguments.contains("--keep")
    if let idx = CommandLine.arguments.firstIndex(of: "--hotspot"),
       idx + 1 < CommandLine.arguments.count {
        lm.favoriteHotspot = CommandLine.arguments[idx + 1]
        lm.joinHotspotOnActivate = true
    } else {
        lm.joinHotspotOnActivate = !lm.favoriteHotspot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && CommandLine.arguments.contains("--join")
    }
    if LaptopModeController.isPortableMac {
        lm.lidShutOnActivate = true
    }
    setbuf(stdout, nil)
    print("=== Caffeinate Mode self-test ===")
    print("portable:", LaptopModeController.isPortableMac)
    let result = lm.activate()
    print(result.proof)
    print("---")
    Thread.sleep(forTimeInterval: 0.4)
    let pm: String = {
        let p = Process()
        p.launchPath = "/usr/bin/pmset"
        p.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.launch()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }()
    let idleOK = pm.contains(LaptopModeController.idleAssertionName) || lm.caffeinateEngaged
    let lidOK = !LaptopModeController.isPortableMac
        || !lm.lidShutOnActivate
        || pm.contains(LaptopModeController.lidAssertionName)
        || lm.lidShutEngaged
    print(idleOK
        ? "PASS: caffeinate keep-awake engaged"
        : "FAIL: caffeinate keep-awake missing")
    if let line = pm.split(separator: "\n").first(where: {
        $0.contains(LaptopModeController.idleAssertionName)
            || $0.contains(LaptopModeController.lidAssertionName)
    }) {
        print("  ", line)
    }
    print(lidOK ? "PASS: lid-shut path OK" : "FAIL: lid-shut assertion missing")
    if keep {
        print("Keeping Caffeinate Mode active (--keep).")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    } else {
        lm.deactivate()
        print("Cleaned up. Use --keep to leave active.")
        exit(idleOK && lidOK && result.ok ? 0 : 1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
