// Fixture tests for UsageCore. Compile with:
//   swiftc -framework Foundation UsageCore.swift tests/check-usage-core.swift -o /tmp/usage-core-tests
import Foundation

var failed = 0
func check(_ name: String, _ ok: Bool) {
    if ok {
        print("PASS: \(name)")
    } else {
        print("FAIL: \(name)")
        failed += 1
    }
}

@main
enum CheckUsageCore {
static func main() {
let now = ISO8601DateFormatter().date(from: "2026-10-11T02:00:00Z")!

let claude = UsageParsers.claudeGauges(from: [
    "limits": [
        ["kind": "session", "percent": 40, "resets_at": "2026-10-11T06:00:00Z"],
        ["kind": "weekly_all", "percent": 71.2, "resets_at": "2026-10-17T00:00:00Z"],
        ["kind": "weekly_model", "percent": 12,
         "scope": ["model": ["display_name": "Opus"]],
         "resets_at": "2026-10-17T00:00:00Z"],
    ],
], now: now)
check("claude session 40", claude.first?.label == "Session" && claude.first?.percent == 40)
check("claude weekly rounds", claude.dropFirst().first?.label == "All models" && claude.dropFirst().first?.percent == 71)
check("claude model name", claude.last?.label == "Opus")
check("claude reset date", claude.first?.resetsAt != nil)
check("claude reset text", claude.first?.sub.contains("resets") == true)
check("claude empty", UsageParsers.claudeGauges(from: [:], now: now).isEmpty)

let credits = UsageParsers.grokCredits(from: [
    "config": [
        "creditUsagePercent": 22,
        "billingPeriodEnd": "2026-10-18T00:00:00Z",
        "productUsage": [
            ["product": "GrokBuild", "usagePercent": 10],
            ["product": "Api", "usagePercent": 3],
        ],
    ],
], now: now)
check("grok weekly", credits.overallPercent == 22)
check("grok build label", credits.products.first?.label == "Grok Build")
check("grok api label", credits.products.last?.label == "Grok API")
check("grok reset", credits.resetsAt != nil)

let monthly = UsageParsers.grokMonthly(from: [
    "config": [
        "monthlyLimit": ["val": 100],
        "used": ["val": 40],
        "billingPeriodEnd": "2026-11-01T00:00:00+00:00",
    ],
], now: now)
check("grok month 40", monthly.overallPercent == 40)
check("grok month iso offset", monthly.resetsAt != nil)

let bare = UsageParsers.grokMonthly(from: ["usage_percentage": 15], now: now)
check("grok bare percent", bare.overallPercent == 15)

let codex = UsageParsers.codexGauges(from: [
    "rate_limit": [
        "primary_window": ["used_percent": 15, "reset_at": 1_791_705_600],
        "secondary_window": ["used_percent": 55.4, "reset_after_seconds": 7200],
    ],
], now: now)
check("codex primary", codex.first?.label == "Codex" && codex.first?.percent == 15)
check("codex secondary rounds", codex.last?.percent == 55)
check("codex reset_at", codex.first?.resetsAt == Date(timeIntervalSince1970: 1_791_705_600))
check("codex reset_after", codex.last?.resetsAt == now.addingTimeInterval(7200))
check("codex empty", UsageParsers.codexGauges(from: [:], now: now).isEmpty)

let named = UsageParsers.codexGauges(from: [
    "rate_limit": [
        "primary_window": ["used_percent": 10, "limit_window_seconds": 18_000, "reset_at": 1_791_705_600],
        "secondary_window": ["used_percent": 20, "window_minutes": 10_080, "reset_after_seconds": 7200],
    ],
], now: now)
check("codex 5-hour label", named.first?.label == "5-hour")
check("codex week label", named.last?.label == "Week")

let banked = UsageParsers.codexBanked(from: [
    "rate_limit_reset_credits": [
        "available_count": 2,
        "credits": [
            ["status": "available", "expires_at": now.addingTimeInterval(3 * 3600).timeIntervalSince1970],
            ["status": "redeemed", "expires_at": now.addingTimeInterval(3600).timeIntervalSince1970],
        ],
    ],
], now: now)
check("banked count", banked?.available == 2)
check("banked ignores redeemed expiry", banked?.expiresAt == now.addingTimeInterval(3 * 3600))
check("banked line", banked?.menuLine(now: now).contains("2 banked resets") == true)

let camel = UsageParsers.codexBanked(from: [
    "rateLimitResetCredits": ["availableCount": 1, "credits": []],
], now: now)
check("banked camel count", camel?.available == 1)
check("banked none", UsageParsers.codexBanked(from: ["rate_limit": [:]], now: now) == nil)

let soon = now.addingTimeInterval(50 * 60)
let room = UseItUp.hit(provider: "Claude", label: "Session", percent: 22, resetsAt: soon, now: now, leadMinutes: 90)
check("use-it-up fires", room?.body.contains("78%") == true && room?.body.contains("50 min") == true)
check("use-it-up token", room?.token.contains("Session") == true)
check("use-it-up skips unused",
      UseItUp.hit(provider: "Claude", label: "Session", percent: 0, resetsAt: soon, now: now) == nil)
check("use-it-up skips red",
      UseItUp.hit(provider: "Claude", label: "Session", percent: 81, resetsAt: soon, now: now) == nil)
check("use-it-up skips far reset",
      UseItUp.hit(provider: "Claude", label: "Session", percent: 22,
                  resetsAt: now.addingTimeInterval(8 * 3600), now: now) == nil)

let t0 = now
let t1 = now.addingTimeInterval(3600)
let rising = PaceMath.forecast(
    percent: 20,
    resetsAt: now.addingTimeInterval(24 * 3600),
    samples: [(t0, 10), (t1, 20)],
    now: t1)
check("pace burn 10", rising.burnPerHour.map { abs($0 - 10) < 0.01 } == true)
check("pace hits line", rising.line.contains("hits 80%"))
check("pace warns inside 6h", rising.warn)

let flat = PaceMath.forecast(
    percent: 20,
    resetsAt: now.addingTimeInterval(24 * 3600),
    samples: [(t0, 20), (t1, 20)],
    now: t1)
check("pace flat", flat.line.contains("flat") && flat.warn == false)

let safe = PaceMath.forecast(
    percent: 70,
    resetsAt: t1.addingTimeInterval(30 * 60),
    samples: [(t0, 60), (t1, 70)],
    now: t1)
check("pace under until reset", safe.line.contains("until reset") && safe.warn == false)

let early = PaceMath.forecast(percent: 10, resetsAt: nil, samples: [(t1, 10)], now: t1)
check("pace needs two samples", early.line.contains("collecting"))

let dropped = PaceMath.collapsed(
    [(t0, 90), (t0.addingTimeInterval(60), 10), (t1, 12)],
    now: t1)
check("pace drops pre-reset samples", dropped.count == 2 && dropped[0].percent == 10)

let suite = UserDefaults(suiteName: "usage-core-tests")!
suite.removePersistentDomain(forName: "usage-core-tests")
let g = Gauge(label: "Session", percent: 12, sub: "")
PaceStore.record(providerId: "claude", gauges: [g], now: t0, defaults: suite)
PaceStore.record(providerId: "claude", gauges: [Gauge(label: "Session", percent: 18, sub: "")],
                 now: t1, defaults: suite)
let stored = PaceStore.samples(for: "claude|Session", defaults: suite)
check("pace store two samples", stored.count == 2 && stored[1].percent == 18)
PaceStore.markNotified("claude|Session", token: "h1", defaults: suite)
check("pace notify token", PaceStore.notifiedToken("claude|Session", defaults: suite) == "h1")

check("memory line formats", AppFootprint.menuLine(bytes: 18 * 1_048_576) == "This app · 18 MB memory")
check("memory line small", AppFootprint.menuLine(bytes: 4 * 1_048_576) == "This app · 4.0 MB memory")
check("memory line zero", AppFootprint.menuLine(bytes: 0) == "This app · memory unavailable")
check("memory reads a number", AppFootprint.residentBytes() > 0)

check("off does not change system sleep", !CaffeinatePolicy.changesSystemSleepPolicy(active: false))
check("on does not change system sleep", !CaffeinatePolicy.changesSystemSleepPolicy(active: true))
check("helper idle is idle only", CaffeinatePolicy.helperArguments(lidShut: false) == ["-i"])
check("helper lid adds system sleep", CaffeinatePolicy.helperArguments(lidShut: true) == ["-s", "-i"])
check("helper does not block display",
      !CaffeinatePolicy.helperBlocksDisplaySleep(lidShut: false)
        && !CaffeinatePolicy.helperBlocksDisplaySleep(lidShut: true))
check("clear owned sleep only when we set it",
      CaffeinatePolicy.shouldClearOwnedSleepDisabled(owns: true, currentlyOn: true))
check("do not clear sleep we do not own",
      !CaffeinatePolicy.shouldClearOwnedSleepDisabled(owns: false, currentlyOn: true))
check("do not write when sleep already allowed",
      !CaffeinatePolicy.shouldClearOwnedSleepDisabled(owns: true, currentlyOn: false))
check("parse sleep on", CaffeinatePolicy.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t1\n") == true)
check("parse sleep off", CaffeinatePolicy.parseSleepDisabled(" SleepDisabled 0\n") == false)
check("parse sleep missing", CaffeinatePolicy.parseSleepDisabled("no flag here\n") == nil)

if failed > 0 {
    fputs("\(failed) failed\n", stderr)
    exit(1)
}
print("ALL PASS")
}
}
