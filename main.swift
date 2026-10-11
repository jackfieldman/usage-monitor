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
        exit(idleOK && lidOK && result.ok && offOK && parseOK && policyOK ? 0 : 1)
    }
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
