// UsageMonitor — a self-contained macOS menu-bar app that shows Claude usage
// limits as tiny battery gauges. No external dependencies: it reads the OAuth
// token Claude Code stores in the Keychain, calls the same usage endpoint the
// /usage panel uses, refreshes the token when needed, and draws the result.
//
// Build:  ./build.sh      Run:  open UsageMonitor.app
import AppKit
import ServiceManagement

// MARK: - Model

struct Gauge { let label: String; let percent: Double; let sub: String }

enum IconShape: String, CaseIterable {
    case battery, bars, rings
    var title: String {
        switch self {
        case .battery: return "Battery"
        case .bars: return "Bar Chart"
        case .rings: return "Rings"
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
    case noCredential, refreshFailed, http(Int)
    var errorDescription: String? {
        switch self {
        case .noCredential: return "Not signed in to Claude Code"
        case .refreshFailed: return "Couldn't refresh the login token"
        case .http(let c): return "Usage API returned HTTP \(c)"
        }
    }
}

func levelColor(_ pct: Double) -> NSColor {
    if pct >= 80 { return NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1) }
    if pct >= 50 { return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1) }
    return NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
}

// MARK: - Keychain (via /usr/bin/security — same item Claude Code uses)

enum Keychain {
    static let service = "Claude Code-credentials"

    static func read() throws -> [String: Any] {
        let out = try run(["find-generic-password", "-s", service, "-a", NSUserName(), "-w"])
        guard let data = out.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageError.noCredential }
        return obj
    }

    static func write(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        let json = String(data: data, encoding: .utf8)!
        _ = try run(["add-generic-password", "-U", "-s", service, "-a", NSUserName(), "-w", json])
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

// MARK: - Usage client

final class UsageClient {
    let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    let refreshSkewMS = 300_000.0   // refresh when within 5 min of expiry

    /// Blocking; call off the main thread.
    func fetchUsage() throws -> [Gauge] {
        var token = try validToken()
        var (data, code) = try get(token)
        if code == 401 || code == 403 {
            var cred = try Keychain.read()
            token = try refresh(&cred)
            (data, code) = try get(token)
        }
        guard code == 200 else { throw UsageError.http(code) }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let limits = obj["limits"] as? [[String: Any]] ?? []
        return limits.map(gauge(from:))
    }

    private func validToken() throws -> String {
        var cred = try Keychain.read()
        let oauth = cred["claudeAiOauth"] as? [String: Any] ?? [:]
        let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        if expiresAt - Date().timeIntervalSince1970 * 1000 < refreshSkewMS {
            return try refresh(&cred)
        }
        return oauth["accessToken"] as? String ?? ""
    }

    private func refresh(_ cred: inout [String: Any]) throws -> String {
        guard var oauth = cred["claudeAiOauth"] as? [String: Any],
              let rt = oauth["refreshToken"] as? String else { throw UsageError.noCredential }
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": rt, "client_id": clientID])
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, code) = try syncData(req)
        guard code == 200,
              let tok = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = tok["access_token"] as? String else { throw UsageError.refreshFailed }
        oauth["accessToken"] = at
        if let newRT = tok["refresh_token"] as? String { oauth["refreshToken"] = newRT }
        let expIn = (tok["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        oauth["expiresAt"] = Date().timeIntervalSince1970 * 1000 + expIn * 1000
        cred["claudeAiOauth"] = oauth
        try Keychain.write(cred)
        return at
    }

    private func get(_ token: String) throws -> (Data, Int) {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return try syncData(req)
    }

    private func syncData(_ req: URLRequest) throws -> (Data, Int) {
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

func signedInToClaude() -> Bool {
    guard let cred = try? Keychain.read(),
          let oauth = cred["claudeAiOauth"] as? [String: Any],
          let t = oauth["accessToken"] as? String else { return false }
    return !t.isEmpty
}

/// First-run window that walks a new user through the two prerequisites.
final class OnboardingController: NSObject, NSWindowDelegate {
    var onReady: (() -> Void)?
    private var window: NSWindow?
    private var body: NSTextField?
    private var status: NSTextField?
    private var primary: NSButton?

    func present() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Usage Monitor Setup"
        win.delegate = self
        win.isReleasedWhenClosed = false

        let heading = NSTextField(labelWithString: "Welcome to Usage Monitor 🔋")
        heading.font = .systemFont(ofSize: 18, weight: .bold)

        let body = NSTextField(wrappingLabelWithString: "")
        body.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.body = body

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        self.status = status

        let copyBtn = NSButton(title: "Copy install command", target: self, action: #selector(copyInstall))
        copyBtn.bezelStyle = .rounded
        let recheck = NSButton(title: "Re-check", target: self, action: #selector(refresh))
        recheck.bezelStyle = .rounded
        let primary = NSButton(title: "Get Started", target: self, action: #selector(finish))
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        self.primary = primary

        let btnRow = NSStackView(views: [copyBtn, NSView(), recheck, primary])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8

        let stack = NSStackView(views: [heading, body, NSView(), status, btnRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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
            btnRow.widthAnchor.constraint(equalToConstant: 432),
        ])
        win.contentView = content
        self.window = win
    }

    @objc func refresh() {
        let hasCLI = claudeInstalled()
        let signedIn = signedInToClaude()
        func mark(_ ok: Bool) -> String { ok ? "✅" : "⬜️" }
        body?.stringValue = """
        The app reads your Claude usage from Claude Code — no separate login.

        \(mark(hasCLI))  1. Install Claude Code
              curl -fsSL https://claude.ai/install.sh | bash

        \(mark(signedIn))  2. Sign in to Claude Code
              Run  claude  in a terminal and complete sign-in.
              (Requires a Claude Pro or Max subscription.)
        """
        let ready = hasCLI && signedIn
        primary?.isEnabled = ready
        status?.stringValue = ready ? "All set — you're good to go."
                                    : "Do the unchecked steps, then Re-check."
    }

    @objc func copyInstall() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("curl -fsSL https://claude.ai/install.sh | bash", forType: .string)
        status?.stringValue = "Install command copied — paste it into a terminal."
    }

    @objc func finish() {
        window?.close()
        onReady?()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let client = UsageClient()
    let onboarding = OnboardingController()
    var timer: Timer?
    var gauges: [Gauge] = []
    var lastError: String?
    var lastUpdated: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onboarding.onReady = { [weak self] in self?.poll() }
        render()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if !signedInToClaude() { onboarding.present() }   // first-run guidance
    }

    @objc func openSetup() { onboarding.present() }

    @objc func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let g = try self.client.fetchUsage()
                DispatchQueue.main.async {
                    self.gauges = g; self.lastError = nil; self.lastUpdated = Date(); self.render()
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async { self.lastError = msg; self.render() }
            }
        }
    }

    func render() {
        guard let button = statusItem.button else { return }
        if gauges.isEmpty {
            button.image = warningImage()
            button.toolTip = lastError
        } else {
            switch iconShape {
            case .battery: button.image = consolidated ? consolidatedImage(gauges) : gaugeImage(gauges)
            case .bars: button.image = barsImage(gauges)
            case .rings: button.image = ringsImage(gauges)
            }
            button.toolTip = gauges.map { "\($0.label): \(Int($0.percent))%" }
                .joined(separator: "\n")
        }
        button.imagePosition = .imageOnly
        statusItem.menu = makeMenu()
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
        get { IconShape(rawValue: UserDefaults.standard.string(forKey: "iconShape") ?? "") ?? .battery }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "iconShape") }
    }

    @objc func pickShape(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let shape = IconShape(rawValue: raw) {
            iconShape = shape
        }
        render()
    }

    var iconStyle: IconStyle {
        get { IconStyle(rawValue: UserDefaults.standard.string(forKey: "iconStyle") ?? "") ?? .colour }
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
            if pct >= 80 { return .labelColor }
            if pct >= 50 { return NSColor.labelColor.withAlphaComponent(0.62) }
            return NSColor.labelColor.withAlphaComponent(0.38)
        case .battery:
            return pct >= 80 ? levelColor(pct) : .labelColor
        }
    }

    // MARK: menu

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if gauges.isEmpty, let err = lastError {
            menu.addItem(disabled("⚠︎  \(err)"))
            if err.contains("signed in") {
                menu.addItem(disabled("Open Claude Code and sign in, then Refresh."))
            }
        } else {
            menu.addItem(disabled("Claude usage limits"))
            menu.addItem(.separator())
            for g in gauges {
                let sub = g.sub.isEmpty ? "" : "   ·  \(g.sub)"
                let item = disabled("\(g.label):  \(Int(g.percent))%\(sub)")
                item.image = dotImage(levelColor(g.percent))
                menu.addItem(item)
            }
            if let err = lastError { menu.addItem(disabled("⚠︎  \(err) (showing last good data)")) }
        }
        if let updated = lastUpdated {
            menu.addItem(.separator())
            menu.addItem(disabled("Updated \(relative(updated))"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Refresh now", #selector(poll), "r"))
        let shapeItem = NSMenuItem(title: "Icon Shape", action: nil, keyEquivalent: "")
        let shapeMenu = NSMenu()
        for shape in IconShape.allCases {
            let i = NSMenuItem(title: shape.title, action: #selector(pickShape(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = shape.rawValue
            i.state = shape == iconShape ? .on : .off
            shapeMenu.addItem(i)
        }
        shapeItem.submenu = shapeMenu
        menu.addItem(shapeItem)
        if iconShape == .battery {   // bars/rings are single-glyph already
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
        let login = item("Open at Login", #selector(toggleLogin), "")
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Set Up…", #selector(openSetup), ""))
        // Target must be NSApp: with the delegate as target the action fails
        // validation (delegate has no terminate(_:)) and Quit renders disabled.
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
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

    /// Colour charge bar inside a shell; `track` is the full-width area at 100%.
    private func drawFill(_ track: NSRect, percent: Double) {
        let w = track.width * max(0, min(100, percent)) / 100
        guard w > 0.5 else { return }
        let r = min(2, track.height / 2, w / 2)
        fillColor(percent).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: w, height: track.height),
                     xRadius: r, yRadius: r).fill()
    }

    /// One battery per gauge, with its percentage alongside.
    func gaugeImage(_ gauges: [Gauge]) -> NSImage {
        let h: CGFloat = 22, bodyW: CGFloat = 26, bodyH: CGFloat = 12
        let capExt: CGFloat = 2.5   // gap + cap nub beyond the shell
        let gap: CGFloat = 4, gaugeGap: CGFloat = 10, pad: CGFloat = 2
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let numAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

        let items: [(g: Gauge, s: NSAttributedString, w: CGFloat)] = gauges.map { g in
            let s = NSAttributedString(string: "\(Int(g.percent))", attributes: numAttrs)
            return (g, s, bodyW + capExt + gap + ceil(s.size().width))
        }
        let total = items.isEmpty ? 8
            : pad * 2 + items.reduce(0) { $0 + $1.w } + gaugeGap * CGFloat(items.count - 1)

        return NSImage(size: NSSize(width: total, height: h), flipped: false) { _ in
            var x = pad
            let by = ((h - bodyH) / 2).rounded()
            for it in items {
                let body = NSRect(x: x, y: by, width: bodyW, height: bodyH)
                self.drawShell(body)
                self.drawFill(body.insetBy(dx: 2, dy: 2), percent: it.g.percent)
                let sy = ((h - it.s.size().height) / 2).rounded()
                it.s.draw(at: NSPoint(x: x + bodyW + capExt + gap, y: sy))
                x += it.w + gaugeGap
            }
            return true
        }
    }

    private func peakLabel(_ gauges: [Gauge]) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let peak = gauges.map(\.percent).max() ?? 0
        return NSAttributedString(string: "\(Int(peak))",
                                  attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }

    /// One rounded column per gauge over a faint full-height track,
    /// with the highest percentage alongside.
    func barsImage(_ gauges: [Gauge]) -> NSImage {
        let h: CGFloat = 22, chartH: CGFloat = 15, barW: CGFloat = 4.5, barGap: CGFloat = 2
        let gap: CGFloat = 4, pad: CGFloat = 2
        let s = peakLabel(gauges)
        let chartW = barW * CGFloat(gauges.count) + barGap * CGFloat(max(0, gauges.count - 1))
        let total = pad * 2 + chartW + gap + ceil(s.size().width)

        return NSImage(size: NSSize(width: total, height: h), flipped: false) { _ in
            let baseY = ((h - chartH) / 2).rounded()
            for (i, g) in gauges.enumerated() {
                let x = pad + CGFloat(i) * (barW + barGap)
                NSColor.labelColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: chartH),
                             xRadius: barW / 2, yRadius: barW / 2).fill()
                let bh = max(barW, chartH * max(0, min(100, g.percent)) / 100)
                self.fillColor(g.percent).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: bh),
                             xRadius: barW / 2, yRadius: barW / 2).fill()
            }
            let sy = ((h - s.size().height) / 2).rounded()
            s.draw(at: NSPoint(x: pad + chartW + gap, y: sy))
            return true
        }
    }

    /// Concentric activity-style rings, outermost = first gauge, sweeping
    /// clockwise from 12 o'clock, with the highest percentage alongside.
    func ringsImage(_ gauges: [Gauge]) -> NSImage {
        let h: CGFloat = 22, d: CGFloat = 18, stroke: CGFloat = 2.2, ringGap: CGFloat = 0.6
        let gap: CGFloat = 4, pad: CGFloat = 2
        let s = peakLabel(gauges)
        let total = pad * 2 + d + gap + ceil(s.size().width)

        return NSImage(size: NSSize(width: total, height: h), flipped: false) { _ in
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
        let h: CGFloat = 22, bodyW: CGFloat = 28, bodyH: CGFloat = 16
        let capExt: CGFloat = 2.5, gap: CGFloat = 4, pad: CGFloat = 2
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let peak = gauges.map(\.percent).max() ?? 0
        let s = NSAttributedString(string: "\(Int(peak))",
                                   attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let total = pad * 2 + bodyW + capExt + gap + ceil(s.size().width)

        return NSImage(size: NSSize(width: total, height: h), flipped: false) { _ in
            let body = NSRect(x: pad, y: ((h - bodyH) / 2).rounded(), width: bodyW, height: bodyH)
            self.drawShell(body)
            let inner = body.insetBy(dx: 2, dy: 2)
            let barGap: CGFloat = 1
            let rows = CGFloat(gauges.count)
            let barH = (inner.height - barGap * (rows - 1)) / rows
            for (i, g) in gauges.enumerated() {
                let y = inner.maxY - barH - CGFloat(i) * (barH + barGap)
                self.drawFill(NSRect(x: inner.minX, y: y, width: inner.width, height: barH),
                              percent: g.percent)
            }
            let sy = ((h - s.size().height) / 2).rounded()
            s.draw(at: NSPoint(x: body.maxX + capExt + gap, y: sy))
            return true
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
