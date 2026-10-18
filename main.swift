import AppKit

// CLI self-test: prove Caffeinate Mode keep-awake (+ optional lid-shut / Wi‑Fi).
//   UsageMonitor.app/Contents/MacOS/UsageMonitor --laptop-mode-self-test
//   … --laptop-mode-self-test --hotspot "MyPhone"   # also try join
//   … --laptop-mode-self-test --keep                 # leave mode active
//   … --laptop-mode-self-test --off-only             # only test force-off path
if CommandLine.arguments.contains("--footprint") {
    let line = AppFootprint.menuLine()
    print(line)
    if line.contains("MB") { exit(0) }
    fputs("FAIL: footprint line\n", stderr)
    exit(1)
}

if CommandLine.arguments.contains("--laptop-mode-self-test") {
    let lm = LaptopModeController.shared
    let keep = CommandLine.arguments.contains("--keep")
    let offOnly = CommandLine.arguments.contains("--off-only")
    // The test mutates switches. Put them back so a smoke run does not
    // change the user's Caffeinate settings.
    let savedJoin = lm.joinHotspotOnActivate
    let savedLid = lm.lidShutOnActivate
    let savedActive = lm.isActive
    // exit() skips defer, so call this before every exit in this test.
    func restorePrefs() {
        if keep { return }
        lm.joinHotspotOnActivate = savedJoin
        lm.lidShutOnActivate = savedLid
        lm.isActive = savedActive
    }
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
    let parseOn = LaptopModeController.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t1\n")
    let parseOff = LaptopModeController.parseSleepDisabled(" SleepDisabled 0\n")
    let parseMiss = LaptopModeController.parseSleepDisabled("no flag here\n")
    let parseOK = parseOn == true && parseOff == false && parseMiss == nil
    print(parseOK ? "PASS: SleepDisabled parser" : "FAIL: SleepDisabled parser")
    let policyOK = !CaffeinatePolicy.changesSystemSleepPolicy(active: false)
        && !CaffeinatePolicy.changesSystemSleepPolicy(active: true)
        && CaffeinatePolicy.helperArguments(lidShut: false) == ["-i"]
        && !CaffeinatePolicy.helperBlocksDisplaySleep(lidShut: true)
    print(policyOK
        ? "PASS: Off only releases this app's keep-awake"
        : "FAIL: Off still changes system sleep")

    func pmsetText() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    if offOnly {
        lm.deactivate()
        Thread.sleep(forTimeInterval: 0.4)
        let clean = !lm.isEngaged && !lm.isActive
        print(lm.lastProof)
        print(clean
            ? "PASS: Off left this process with no keep-awake"
            : "FAIL: Off still engaged in this process")
        restorePrefs()
        exit(clean && parseOK && policyOK ? 0 : 1)
    }

    let engageStart = Date()
    let engaged = lm.engageKeepAwake()
    let engageMs = Date().timeIntervalSince(engageStart) * 1000
    let engageFast = engaged.ok && engageMs < 800
    print(String(format: engageFast
        ? "PASS: keep-awake on in %.0f ms"
        : "FAIL: keep-awake on took %.0f ms", engageMs))
    lm.releaseKeepAwake()

    let result = lm.activate()
    print(result.proof)
    print("---")
    Thread.sleep(forTimeInterval: 0.4)
    let pm = pmsetText()
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
        Thread.sleep(forTimeInterval: 0.4)
        let pmAfter = pmsetText()
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let oursStill = pmAfter.split(separator: "\n").contains { line in
            let s = String(line)
            return s.contains("pid \(selfPid)(")
                && (s.contains(LaptopModeController.idleAssertionName)
                    || s.contains(LaptopModeController.lidAssertionName))
        }
        let offOK = !oursStill && !lm.isEngaged && !lm.isActive
        print("--- after Off ---")
        print(lm.lastProof)
        print(offOK
            ? "PASS: Off cleared keep-awake (sleep/screensaver allowed by this app)"
            : "FAIL: Off did not fully clear keep-awake")
        if pmAfter.contains(LaptopModeController.idleAssertionName) && offOK {
            print("NOTE: another process still holds similarly named assertions (ignored)")
        }
        print("Cleaned up. Use --keep to leave active.")
        restorePrefs()
        exit(idleOK && lidOK && result.ok && offOK && parseOK && policyOK && engageFast ? 0 : 1)
    }
}

// Prompt self-test: a click that asks a question closes the Usage panel and any
// menu first, shows exactly one prompt, and that prompt sits above every other
// window of this app. Every prompt is cancelled, so nothing turns on.
//   UsageMonitor.app/Contents/MacOS/UsageMonitor --prompt-self-test
if CommandLine.arguments.contains("--prompt-self-test") {
    setbuf(stdout, nil)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()   // not app.delegate: no polling, no update check
    let lm = delegate.laptopMode
    let saved = (lm.joinHotspotOnActivate, lm.favoriteHotspot, lm.isActive, lm.lidShutOnActivate)
    func restore() {
        lm.joinHotspotOnActivate = saved.0
        lm.favoriteHotspot = saved.1
        lm.isActive = saved.2
        lm.lidShutOnActivate = saved.3
    }
    var failures = 0
    func check(_ ok: Bool, _ label: String) {
        print(ok ? "PASS: \(label)" : "FAIL: \(label)")
        if !ok { failures += 1 }
    }
    struct Seen { var level: Int; var panelOpen: Bool; var topmost: Bool; var otherPrompts: Int; var key: Bool }
    var seen: [Seen] = []
    delegate.promptProbe = { win in
        let others = NSApp.windows.filter { $0 !== win && $0.isVisible && $0.level.rawValue < NSWindow.Level.statusBar.rawValue + 2 && !($0.className.contains("StatusBar")) }
        let higher = NSApp.windows.filter { $0 !== win && $0.isVisible && $0.level.rawValue >= win.level.rawValue && !$0.className.contains("StatusBar") }
        let otherPrompts = NSApp.windows.filter { $0 !== win && $0.isVisible && $0.className.contains("Alert") }.count
        _ = others
        seen.append(Seen(level: win.level.rawValue, panelOpen: delegate.usagePanel.isOpen,
                         topmost: higher.isEmpty, otherPrompts: otherPrompts, key: win.isKeyWindow))
        // Cancel, so nothing is engaged and no Wi-Fi join starts.
        let t = Timer(timeInterval: 0.3, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(t, forMode: .modalPanel)
    }
    func findView(_ v: NSView, label: String) -> NSView? {
        if v.accessibilityLabel() == label { return v }
        for sub in v.subviews { if let hit = findView(sub, label: label) { return hit } }
        return nil
    }
    func click(_ view: NSView, in window: NSWindow) {
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(e)
            }
        }
    }
    func after(_ s: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body)
    }

    lm.isActive = false
    lm.joinHotspotOnActivate = true
    lm.favoriteHotspot = "UsageMonitor-SelfTest"
    delegate.statusItem.button?.title = "UM"
    print("=== Prompt self-test ===")
    after(0.5) {
        // 1) Usage panel: Caffeinate On, clicked twice fast.
        guard let button = delegate.statusItem.button else { check(false, "status button"); restore(); exit(1) }
        delegate.usagePanel.toggle(app: delegate, anchor: button)
        check(delegate.usagePanel.isOpen, "Usage panel opens")
        let card = delegate.usagePanel.cardWindow
        guard let root = card.contentView, let on = findView(root, label: "Caffeinate on") else {
            check(false, "Caffeinate On switch found"); restore(); exit(1)
        }
        click(on, in: card)
        click(on, in: card)
        after(1.2) {
            check(seen.count == 1, "panel On (double click) shows exactly one prompt (saw \(seen.count))")
            if let s = seen.first {
                check(!s.panelOpen, "panel and click catcher closed before the prompt")
                check(s.level > NSWindow.Level.statusBar.rawValue, "prompt above status-bar level (level \(s.level))")
                check(s.topmost, "no window of this app above the prompt")
                check(s.otherPrompts == 0, "no second prompt window")
                print("INFO: prompt key=\(s.key) (a CLI run cannot activate an app; a real click does)")
            }
            check(!lm.isActive, "cancel left Caffeinate off")

            // 2) Menu / Settings Turn On, handler fired twice.
            seen.removeAll()
            delegate.usagePanel.toggle(app: delegate, anchor: button)
            delegate.openSettings()
            delegate.activateLaptopMode()
            delegate.activateLaptopMode()
            after(1.2) {
                check(seen.count == 1, "menu Turn On fired twice shows exactly one prompt (saw \(seen.count))")
                if let s = seen.first {
                    check(!s.panelOpen, "menu path closed the panel first")
                    check(s.topmost, "prompt above the Settings window")
                }
                let notices = NSApp.windows.filter { $0.isVisible && $0 is NSPanel && $0.styleMask.contains(.titled) }
                check(notices.isEmpty, "cancel shows no second window (no Caffeinate notice)")
                check(!lm.isActive, "cancel left Caffeinate off")

                // 3) Every other prompt entry point: one prompt each, panel closed.
                let entries: [(String, () -> Void)] = [
                    ("Choose Favorite Hotspot", { delegate.setFavoriteHotspot() }),
                    ("Show Status", { delegate.showLaptopModeProof() }),
                    ("Add provider", { delegate.addProvider() }),
                    ("Copy download link", { delegate.copyOfficialLink() }),
                    ("Install official app", { delegate.installOfficialApp() }),
                ]
                func runEntry(_ i: Int) {
                    guard i < entries.count else {
                        restore()
                        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
                        exit(failures == 0 ? 0 : 1)
                    }
                    seen.removeAll()
                    delegate.usagePanel.toggle(app: delegate, anchor: button)
                    if !delegate.usagePanel.isOpen { delegate.usagePanel.toggle(app: delegate, anchor: button) }
                    entries[i].1()
                    entries[i].1()
                    after(1.0) {
                        let ok = seen.count == 1 && seen.allSatisfy { !$0.panelOpen && $0.topmost }
                        check(ok, "\(entries[i].0): one prompt, panel closed, in front (saw \(seen.count))")
                        runEntry(i + 1)
                    }
                }
                runEntry(0)
            }
        }
    }
    app.run()
}

// Headless Session Report (smoke / automation):
//   UsageMonitor.app/Contents/MacOS/UsageMonitor --session-report [--days 7|35] [--titles]
if CommandLine.arguments.contains("--session-report") {
    var days = 35
    if let idx = CommandLine.arguments.firstIndex(of: "--days"),
       idx + 1 < CommandLine.arguments.count,
       let n = Int(CommandLine.arguments[idx + 1]), n > 0, n <= 365 {
        days = n
    }
    let titles = CommandLine.arguments.contains("--titles")
    do {
        let report = SessionRadar.scan(days: days, includeTitles: titles)
        let url = try SessionRadar.write(report: report)
        print("OK: Session Report written")
        print("  windowDays=\(report.windowDays)")
        print("  projects=\(report.totals["projects"] ?? 0)")
        print("  claude=\(report.totals["claudeSessions"] ?? 0)")
        print("  grok=\(report.totals["grokSessions"] ?? 0)")
        print("  codex=\(report.totals["codexSessions"] ?? 0)")
        print("  html=\(url.path)")
        // Privacy guard: report must not contain this Mac's home directory path.
        let home = NSHomeDirectory()
        if let html = try? String(contentsOf: url, encoding: .utf8), html.contains(home) {
            print("FAIL: report HTML contains home path (privacy scrub broken)")
            exit(1)
        }
        if let data = try? Data(contentsOf: SessionRadar.reportJSON),
           let text = String(data: data, encoding: .utf8), text.contains(home) {
            print("FAIL: report JSON contains home path (privacy scrub broken)")
            exit(1)
        }
        print("PASS: no home path in report")
        exit(0)
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
