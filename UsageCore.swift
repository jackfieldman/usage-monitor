// UsageCore — pure usage parsing, pace, memory, and Caffeinate policy.
// No AppKit. The app and the fixture tests both compile this file.
import Foundation
import Darwin

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
        var gauges: [Gauge] = []
        if let rl = obj["rate_limit"] as? [String: Any] {
            if let primary = rl["primary_window"] as? [String: Any],
               let pct = number(primary["used_percent"]) {
                let resets = codexReset(primary, now: now)
                gauges.append(Gauge(label: "Codex", percent: pct.rounded(),
                                    sub: resetSub(until: resets, now: now), resetsAt: resets))
            }
            if let secondary = rl["secondary_window"] as? [String: Any],
               let pct = number(secondary["used_percent"]) {
                let resets = codexReset(secondary, now: now)
                gauges.append(Gauge(label: "Codex 2", percent: pct.rounded(),
                                    sub: resetSub(until: resets, now: now), resetsAt: resets))
            }
        }
        return gauges
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

// MARK: - Caffeinate Off restores system sleep

enum CaffeinatePolicy {
    /// `pmset -a disablesleep` value. Off is always 0 so system sleep is allowed again.
    static func sleepDisabledValue(active: Bool) -> String {
        active ? "1" : "0"
    }

    static func offRestoresSystemSleep() -> Bool {
        sleepDisabledValue(active: false) == "0"
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
