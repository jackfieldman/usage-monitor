// UsageCore — pure usage parsing, pace, memory, and Caffeinate policy.
// No AppKit. The app and the fixture tests both compile this file.
import Foundation
import Darwin

struct BankedReset: Equatable {
    var available: Int
    var expiresAt: Date?

    func menuLine(now: Date = Date()) -> String {
        let noun = available == 1 ? "1 banked reset" : "\(available) banked resets"
        guard let expiresAt, expiresAt > now else { return noun }
        let df = DateFormatter()
        df.dateFormat = expiresAt.timeIntervalSince(now) < 36 * 3600 ? "h:mm a" : "EEE h:mm a"
        return noun + " · expires " + df.string(from: expiresAt)
    }
}

struct CodexSnapshot {
    var gauges: [Gauge]
    var banked: BankedReset?
}

/// A limit that still has room and dies soon. Off until the user turns it on.
enum UseItUp {
    struct Hit: Equatable {
        var token: String
        var title: String
        var body: String
    }

    /// Fires once per reset. Skips an untouched window and a window already in the red.
    static func hit(provider: String,
                    label: String,
                    percent: Double,
                    resetsAt: Date?,
                    now: Date,
                    leadMinutes: Int = 90,
                    minUsed: Double = 8,
                    maxUsed: Double = 70) -> Hit? {
        guard let resetsAt else { return nil }
        let lead = TimeInterval(max(15, leadMinutes) * 60)
        let left = resetsAt.timeIntervalSince(now)
        guard left > 60, left <= lead else { return nil }
        guard percent >= minUsed, percent < maxUsed else { return nil }
        let mins = max(1, Int(left / 60))
        let when = mins < 60 ? "\(mins) min" : "\(mins / 60)h \(mins % 60)m"
        let unused = Int((100 - percent).rounded())
        let epoch = Int(resetsAt.timeIntervalSince1970)
        return Hit(
            token: "\(provider)|\(label)|\(epoch)",
            title: "\(provider) still has room",
            body: "\(label) is \(Int(percent.rounded()))% used, so about \(unused)% is left. It resets in \(when).")
    }
}

struct Gauge {
    let label: String
    let percent: Double
    let sub: String
    let resetsAt: Date?

    init(label: String, percent: Double, sub: String, resetsAt: Date? = nil) {
        self.label = label
        self.percent = percent
        self.sub = sub
        self.resetsAt = resetsAt
    }
}

// MARK: - Parsers (Claude, Grok, Codex JSON → gauges)

enum UsageParsers {
    // Stored keys so an optimised build cannot drop the literals.
    private static let kConfig = "config"
    private static let kCreditUsagePercent = "creditUsagePercent"
    private static let kProductUsage = "productUsage"
    private static let kProduct = "product"
    private static let kUsagePercent = "usagePercent"
    private static let kMonthlyLimit = "monthlyLimit"
    private static let kUsed = "used"
    private static let kVal = "val"
    private static let kValue = "value"
    private static let kBillingPeriodEnd = "billingPeriodEnd"
    private static let kCurrentPeriod = "currentPeriod"
    private static let kEnd = "end"
    private static let kPeriodEnd = "period_end"
    private static let kUsagePercentage = "usage_percentage"

    static func claudeGauges(from obj: [String: Any], now: Date = Date()) -> [Gauge] {
        let limits = obj["limits"] as? [[String: Any]] ?? []
        return limits.map { lim in
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
            let pct = number(lim["percent"]) ?? 0
            let resets = parseISO(lim["resets_at"] as? String)
            return Gauge(label: label, percent: pct.rounded(),
                         sub: resetSub(until: resets, now: now), resetsAt: resets)
        }
    }

    struct BillingWindow {
        var overallPercent: Double?
        var resetSub: String
        var resetsAt: Date?
        var products: [Gauge]
    }

    static func grokCredits(from data: Data, now: Date = Date()) -> BillingWindow {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return grokCredits(from: obj, now: now)
    }

    static func grokCredits(from obj: [String: Any], now: Date = Date()) -> BillingWindow {
        let config = obj[kConfig] as? [String: Any] ?? obj
        let resets = parseISO(
            (config[kBillingPeriodEnd] as? String)
                ?? ((config[kCurrentPeriod] as? [String: Any])?[kEnd] as? String)
                ?? (obj[kPeriodEnd] as? String))
        let sub = resetSub(until: resets, now: now)
        var overall: Double?
        if let pct = number(config[kCreditUsagePercent])
            ?? number(config[kUsagePercentage])
            ?? number(obj[kUsagePercentage])
            ?? number(config[kUsagePercent]) {
            overall = pct.rounded()
        }
        var products: [Gauge] = []
        for product in config[kProductUsage] as? [[String: Any]] ?? [] {
            guard let name = product[kProduct] as? String,
                  let pct = number(product[kUsagePercent]) else { continue }
            products.append(Gauge(label: productLabel(name), percent: pct.rounded(),
                                  sub: sub, resetsAt: resets))
        }
        return BillingWindow(overallPercent: overall, resetSub: sub, resetsAt: resets, products: products)
    }

    static func grokMonthly(from data: Data, now: Date = Date()) -> BillingWindow {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return grokMonthly(from: obj, now: now)
    }

    static func grokMonthly(from obj: [String: Any], now: Date = Date()) -> BillingWindow {
        let config = obj[kConfig] as? [String: Any] ?? obj
        let resets = parseISO(
            (config[kBillingPeriodEnd] as? String)
                ?? ((config[kCurrentPeriod] as? [String: Any])?[kEnd] as? String)
                ?? (obj[kPeriodEnd] as? String))
        let sub = resetSub(until: resets, now: now)
        var overall: Double?
        if let limit = numberVal(config[kMonthlyLimit]),
           let used = numberVal(config[kUsed]),
           limit > 0 {
            overall = min(100, max(0, (used / limit) * 100)).rounded()
        } else if let pct = number(config[kUsagePercentage])
            ?? number(obj[kUsagePercentage])
            ?? number(config[kUsagePercent]) {
            overall = pct.rounded()
        }
        return BillingWindow(overallPercent: overall, resetSub: sub, resetsAt: resets, products: [])
    }

    static func codexGauges(from obj: [String: Any], now: Date = Date()) -> [Gauge] {
        codexSnapshot(from: obj, now: now).gauges
    }

    static func codexSnapshot(from obj: [String: Any], now: Date = Date()) -> CodexSnapshot {
        var gauges: [Gauge] = []
        if let rl = obj["rate_limit"] as? [String: Any] {
            if let primary = rl["primary_window"] as? [String: Any],
               let pct = number(primary["used_percent"]) {
                let resets = codexReset(primary, now: now)
                gauges.append(Gauge(label: codexWindowLabel(fallback: "Codex", window: primary),
                                    percent: pct.rounded(),
                                    sub: resetSub(until: resets, now: now), resetsAt: resets))
            }
            if let secondary = rl["secondary_window"] as? [String: Any],
               let pct = number(secondary["used_percent"]) {
                let resets = codexReset(secondary, now: now)
                gauges.append(Gauge(label: codexWindowLabel(fallback: "Codex 2", window: secondary),
                                    percent: pct.rounded(),
                                    sub: resetSub(until: resets, now: now), resetsAt: resets))
            }
        }
        return CodexSnapshot(gauges: gauges, banked: codexBanked(from: obj, now: now))
    }

    /// Codex banked resets. Accepts the app-server camelCase summary and the
    /// snake_case shape the usage HTTP payload has used.
    static func codexBanked(from obj: [String: Any], now: Date = Date()) -> BankedReset? {
        let rate = obj["rate_limit"] as? [String: Any] ?? [:]
        let bags: [[String: Any]] = [obj, rate]
        for bag in bags {
            if let summary = dictionary(bag, "rateLimitResetCredits", "rate_limit_reset_credits", "reset_credits") {
                let listed = creditRows(summary["credits"])
                let availableRows = listed.filter(isAvailableCredit)
                let counted = intValue(summary, "availableCount", "available_count")
                let available = max(counted ?? 0, availableRows.isEmpty ? 0 : availableRows.count)
                if available > 0 {
                    return BankedReset(available: available,
                                       expiresAt: soonestExpiry(availableRows, now: now))
                }
            }
            let rows = creditRows(bag["rate_limit_reset_credits"] ?? bag["reset_credits"] ?? bag["rateLimitResetCredits"])
            let availableRows = rows.filter(isAvailableCredit)
            if !availableRows.isEmpty {
                return BankedReset(available: availableRows.count,
                                   expiresAt: soonestExpiry(availableRows, now: now))
            }
        }
        return nil
    }

    private static func codexWindowLabel(fallback: String, window: [String: Any]) -> String {
        let secs = number(window["limit_window_seconds"])
            ?? number(window["window_seconds"])
            ?? number(window["window_minutes"]).map { $0 * 60 }
        guard let secs else { return fallback }
        if secs > 0, secs <= 6 * 3600 { return "5-hour" }
        if secs >= 24 * 3600 { return "Week" }
        return fallback
    }

    private static func dictionary(_ bag: [String: Any], _ keys: String...) -> [String: Any]? {
        for key in keys {
            if let d = bag[key] as? [String: Any] { return d }
        }
        return nil
    }

    private static func creditRows(_ any: Any?) -> [[String: Any]] {
        if let rows = any as? [[String: Any]] { return rows }
        if let summary = any as? [String: Any], let rows = summary["credits"] as? [[String: Any]] {
            return rows
        }
        return []
    }

    private static func isAvailableCredit(_ row: [String: Any]) -> Bool {
        let status = (row["status"] as? String)?.lowercased() ?? "available"
        return status == "available" || status == "redeeming"
    }

    private static func soonestExpiry(_ rows: [[String: Any]], now: Date) -> Date? {
        let dates = rows.compactMap { row -> Date? in
            unixOrISO(row["expiresAt"] ?? row["expires_at"])
        }.filter { $0 > now }
        return dates.min()
    }

    private static func intValue(_ bag: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let n = number(bag[key]) { return Int(n.rounded()) }
        }
        return nil
    }

    private static func unixOrISO(_ any: Any?) -> Date? {
        if let n = number(any), n > 1_000_000_000 {
            return Date(timeIntervalSince1970: n)
        }
        if let s = any as? String { return parseISO(s) }
        return nil
    }

    static func parseISO(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let cleaned = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "+00:00", with: "Z")
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let dt = f.date(from: cleaned) { return dt }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f2.date(from: iso)
    }

    static func resetSub(until dt: Date?, now: Date) -> String {
        guard let dt else { return "" }
        let delta = dt.timeIntervalSince(now)
        if delta <= 0 { return "resetting…" }
        if delta < 3600 { return "resets in \(Int(delta / 60)) min" }
        let df = DateFormatter()
        df.dateFormat = delta < 12 * 3600 ? "h:mm a" : "EEE h:mm a"
        return "resets " + df.string(from: dt)
    }

    private static func codexReset(_ window: [String: Any], now: Date) -> Date? {
        if let resetAt = number(window["reset_at"]) {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let secs = number(window["reset_after_seconds"]) {
            return now.addingTimeInterval(secs)
        }
        return nil
    }

    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    private static func numberVal(_ any: Any?) -> Double? {
        if let n = number(any) { return n }
        if let d = any as? [String: Any] {
            return number(d[kVal]) ?? number(d[kValue])
        }
        return nil
    }

    static func productLabel(_ product: String) -> String {
        switch product {
        case "GrokBuild": return "Grok Build"
        case "Api", "API": return "Grok API"
        case "GrokChat": return "Grok Chat"
        case "GrokImagine": return "Grok Imagine"
        default:
            return product.hasPrefix("Grok") ? product : "Grok \(product)"
        }
    }
}

// MARK: - Pace (burn rate from local samples)

struct PaceForecast: Equatable {
    var line: String
    var burnPerHour: Double?
    var eta: Date?
    /// True when the current pace reaches 80% inside the next 6 hours, before reset.
    var warn: Bool
}

enum PaceMath {
    static let minSpan: TimeInterval = 8 * 60

    static func forecast(percent: Double,
                         resetsAt: Date?,
                         samples: [(date: Date, percent: Double)],
                         now: Date = Date()) -> PaceForecast {
        let rows = collapsed(samples, now: now)
        guard rows.count >= 2 else {
            return PaceForecast(line: "Pace · collecting · one more refresh",
                                burnPerHour: nil, eta: nil, warn: false)
        }
        let span = rows[rows.count - 1].date.timeIntervalSince(rows[0].date)
        guard span >= minSpan else {
            return PaceForecast(line: "Pace · collecting · one more refresh",
                                burnPerHour: nil, eta: nil, warn: false)
        }
        let burn = (rows[rows.count - 1].percent - rows[0].percent) / (span / 3600)
        if percent >= 80 {
            let when = resetsAt.map { " · resets \(clock($0, from: now))" } ?? ""
            return PaceForecast(line: "Pace · \(Int(percent.rounded()))% used\(when)",
                                burnPerHour: burn, eta: nil, warn: false)
        }
        if burn <= 0.2 {
            let tail = resetsAt == nil ? " · usage is flat" : " · stays under 80% until reset"
            return PaceForecast(line: "Pace · flat\(tail)", burnPerHour: burn, eta: nil, warn: false)
        }
        let hoursTo = (80 - percent) / burn
        let eta = now.addingTimeInterval(hoursTo * 3600)
        let rate = String(format: "%.0f pts/h", burn.rounded())
        if let resetsAt, eta >= resetsAt {
            return PaceForecast(line: "Pace · \(rate) · stays under 80% until reset",
                                burnPerHour: burn, eta: eta, warn: false)
        }
        let soon = eta.timeIntervalSince(now) <= 6 * 3600 + 1
        return PaceForecast(line: "Pace · \(rate) · hits 80% at \(clock(eta, from: now))",
                            burnPerHour: burn, eta: eta, warn: soon)
    }

    /// Drop samples older than 48 hours, and drop history from before a sharp fall
    /// (the limit window reset).
    static func collapsed(_ samples: [(date: Date, percent: Double)],
                          now: Date) -> [(date: Date, percent: Double)] {
        let cutoff = now.addingTimeInterval(-48 * 3600)
        var rows = samples.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        if let drop = rows.indices.dropFirst().last(where: { idx in
            rows[idx].percent + 25 <= rows[idx - 1].percent
        }) {
            rows = Array(rows[drop...])
        }
        return rows
    }

    private static func clock(_ date: Date, from now: Date) -> String {
        let df = DateFormatter()
        let delta = date.timeIntervalSince(now)
        df.dateFormat = delta < 18 * 3600 ? "h:mm a" : "EEE h:mm a"
        return df.string(from: date)
    }
}

struct PaceSample: Codable, Equatable {
    var key: String
    var percent: Double
    var at: TimeInterval
}

enum PaceStore {
    static let defaultsKey = "pace.samples.v1"
    static let noticeName = "pace.notice.v1"

    static func load(defaults: UserDefaults = .standard) -> [PaceSample] {
        guard let data = defaults.data(forKey: defaultsKey),
              let rows = try? JSONDecoder().decode([PaceSample].self, from: data) else { return [] }
        return rows
    }

    static func save(_ rows: [PaceSample], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(rows) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    static func record(providerId: String, gauges: [Gauge], now: Date = Date(),
                       defaults: UserDefaults = .standard) {
        var rows = load(defaults: defaults)
        for g in gauges {
            rows.append(PaceSample(key: "\(providerId)|\(g.label)",
                                   percent: g.percent, at: now.timeIntervalSince1970))
        }
        let cutoff = now.addingTimeInterval(-48 * 3600).timeIntervalSince1970
        rows = rows.filter { $0.at >= cutoff }
        if rows.count > 400 { rows = Array(rows.suffix(400)) }
        save(rows, defaults: defaults)
    }

    static func samples(for key: String, defaults: UserDefaults = .standard) -> [(date: Date, percent: Double)] {
        load(defaults: defaults)
            .filter { $0.key == key }
            .map { (Date(timeIntervalSince1970: $0.at), $0.percent) }
    }

    static func markNotified(_ key: String, token: String, defaults: UserDefaults = .standard) {
        var map = defaults.dictionary(forKey: noticeName) as? [String: String] ?? [:]
        map[key] = token
        defaults.set(map, forKey: noticeName)
    }

    static func notifiedToken(_ key: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: noticeName) as? [String: String])?[key]
    }
}

// MARK: - This app's memory (Activity Monitor "memory" = phys footprint)

enum AppFootprint {
    static func residentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr != KERN_SUCCESS { return 0 }
        return UInt64(info.phys_footprint)
    }

    static func menuLine(bytes: UInt64? = nil) -> String {
        let b = bytes ?? residentBytes()
        if b == 0 { return "This app · memory unavailable" }
        let mb = Double(b) / 1_048_576
        let text = mb < 10 ? String(format: "%.1f MB", mb) : String(format: "%.0f MB", mb.rounded())
        return "This app · \(text) memory"
    }
}

// MARK: - Caffeinate holds and releases only this app's keep-awake

enum CaffeinatePolicy {
    /// On and Off never write `pmset disablesleep`. Keep-awake is an assertion
    /// that dies when it is released. System sleep settings stay as they are.
    static func changesSystemSleepPolicy(active: Bool) -> Bool {
        _ = active
        return false
    }

    /// Idle keep-awake is `-i` only. Lid-shut adds `-s` (system sleep on AC).
    /// Never `-d` (display) or `-m` (disk). The screen may sleep.
    static func helperArguments(lidShut: Bool) -> [String] {
        lidShut ? ["-s", "-i"] : ["-i"]
    }

    static func helperBlocksDisplaySleep(lidShut: Bool) -> Bool {
        let args = helperArguments(lidShut: lidShut)
        return args.contains("-d") || args.contains("-u")
    }

    /// One-time undo of a SleepDisabled flag an older version of this app set.
    /// Write only when we still own that flag and it is on. Never write when
    /// we do not own it, and never set it on.
    static func shouldClearOwnedSleepDisabled(owns: Bool, currentlyOn: Bool) -> Bool {
        owns && currentlyOn
    }

    /// `pmset -g` system-wide SleepDisabled. nil when the line is absent.
    static func parseSleepDisabled(_ text: String) -> Bool? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("SleepDisabled") else { continue }
            guard let last = line.split(whereSeparator: \.isWhitespace).last else { continue }
            if last == "1" { return true }
            if last == "0" { return false }
        }
        return nil
    }
}
