import Foundation
import CryptoKit

// `kwh_value` is a cumulative meter reading, not per-interval use. All totals are
// derived here: keep the highest reading per calendar day, then take differences.
struct KWhReading: Decodable, Equatable {
    var date: String
    var kwhValue: Double

    enum CodingKeys: String, CodingKey { case date, kwhValue = "kwh_value" }

    init(date: String, kwhValue: Double) { self.date = date; self.kwhValue = kwhValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        if let value = try? c.decode(Double.self, forKey: .kwhValue) { kwhValue = value }
        else if let text = try? c.decode(String.self, forKey: .kwhValue), let value = Double(text) { kwhValue = value }
        else { throw DecodingError.dataCorruptedError(forKey: .kwhValue, in: c, debugDescription: "kwh_value is not a number") }
    }

    // "yyyy-MM-dd HH:mm:ss" → "yyyy-MM-dd"
    var day: String { String(date.prefix(10)) }
}

struct DailyUsage: Equatable {
    var day: String
    var kwh: Double
}

enum Energy {
    static let syncInterval: TimeInterval = 6 * 60 * 60

    static func dailyReadings(_ readings: [KWhReading]) -> [(day: String, reading: Double)] {
        var maxima: [String: Double] = [:]
        for row in readings where row.day.count == 10 {
            maxima[row.day] = max(maxima[row.day] ?? -.infinity, row.kwhValue)
        }
        return maxima.keys.sorted().map { ($0, maxima[$0]!) }
    }

    // The first day has no previous reading, so it counts as 0. A lower reading
    // than the day before means the meter was reset, which also counts as 0.
    static func dailyUsage(_ readings: [KWhReading]) -> [DailyUsage] {
        var previous: Double?
        return dailyReadings(readings).map { entry in
            defer { previous = entry.reading }
            return DailyUsage(day: entry.day, kwh: previous.map { max(0, entry.reading - $0) } ?? 0)
        }
    }

    static func total(_ usage: [DailyUsage], prefix: String) -> Double {
        usage.filter { $0.day.hasPrefix(prefix) }.reduce(0) { $0 + $1.kwh }
    }

    // Weeks of a month as the official app counts them: days 1–7 are W1, 8–14 W2, …
    static func weeklyTotals(_ usage: [DailyUsage], month: String) -> [Int: Double] {
        var weeks: [Int: Double] = [:]
        for entry in usage where entry.day.hasPrefix(month + "-") {
            guard let dayOfMonth = Int(entry.day.suffix(2)) else { continue }
            weeks[(dayOfMonth - 1) / 7 + 1, default: 0] += entry.kwh
        }
        return weeks
    }

    // "yyyy" → totals keyed by "yyyy-MM".
    static func monthlyTotals(_ usage: [DailyUsage], year: String) -> [String: Double] {
        var months: [String: Double] = [:]
        for entry in usage where entry.day.hasPrefix(year + "-") {
            months[String(entry.day.prefix(7)), default: 0] += entry.kwh
        }
        return months
    }
}

// Totals shown on the Energy tab. Weeks follow the official app: W1 is days 1–7 of the month.
struct EnergySummary: Equatable {
    var today: Double
    var week: Double
    var weekNumber: Int
    var month: Double
    var monthDays: [DailyUsage]
    var weeks: [Int: Double]
    var months: [String: Double]
    var latestReading: String?

    init(usage: [DailyUsage], now: Date, calendar: Calendar = .current) {
        let day = Energy.dayString(now, calendar: calendar)
        let month = String(day.prefix(7)), year = String(day.prefix(4))
        let dayOfMonth = calendar.component(.day, from: now)
        today = Energy.total(usage, prefix: day)
        weekNumber = (dayOfMonth - 1) / 7 + 1
        weeks = Energy.weeklyTotals(usage, month: month)
        week = weeks[weekNumber] ?? 0
        self.month = Energy.total(usage, prefix: month + "-")
        monthDays = usage.filter { $0.day.hasPrefix(month + "-") }
        months = Energy.monthlyTotals(usage, year: year)
        latestReading = usage.last?.day
    }
}

// The cumulative readings kept on this Mac, so each sync only asks for newer rows.
struct EnergyCache: Codable, Equatable {
    var readings: [String: Double] = [:]   // "yyyy-MM-dd HH:mm:ss" → cumulative kWh
    var lastSync: Date?

    var latestRecordDate: String? { readings.keys.max() }
    var rows: [KWhReading] { readings.map { KWhReading(date: $0.key, kwhValue: $0.value) } }

    mutating func merge(_ rows: [KWhReading], at date: Date) {
        for row in rows { readings[row.date] = row.kwhValue }
        lastSync = date
    }
    func nextSync() -> Date? { lastSync?.addingTimeInterval(Energy.syncInterval) }
    func needsSync(now: Date = Date()) -> Bool { nextSync().map { now >= $0 } ?? true }
}

extension Energy {
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // `Request_type` is capitalized on this endpoint only; `last_record_date` is null on the first sync.
    static func requestBody(sub: String, thingID: String, lastRecordDate: String?) -> [String: Any] {
        ["Request_type": "GET_KWH_DATA", "user_name": sub, "thing_id": thingID, "last_record_date": lastRecordDate ?? NSNull()]
    }

    static func fetch(_ tokens: CognitoTokens, thingID: String, lastRecordDate: String?) async throws -> [KWhReading] {
        guard let sub = tokens.sub else { throw DaikinError.message("The ID token has no sub claim.") }
        let json = try await DaikinAPI.post(DaikinEndpoint.energy, body: requestBody(sub: sub, thingID: thingID, lastRecordDate: lastRecordDate),
                                            idToken: tokens.idToken, shape: "energy-get-kwh-data")
        return try parseRows(try APIStatus.energy(json))
    }

    static func parseRows(_ rows: [[String: Any]]) throws -> [KWhReading] {
        try JSONDecoder().decode([KWhReading].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    // Stored per device under Application Support, named by a hash so the thing_id is not in the file name.
    static func cacheURL(thingID: String) -> URL {
        let digest = SHA256.hash(data: Data(thingID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DaikinAC-menubar/energy-\(digest).json")
    }
    static func loadCache(thingID: String) -> EnergyCache {
        (try? Data(contentsOf: cacheURL(thingID: thingID))).flatMap { try? JSONDecoder().decode(EnergyCache.self, from: $0) } ?? EnergyCache()
    }
    static func saveCache(_ cache: EnergyCache, thingID: String) throws {
        let url = cacheURL(thingID: thingID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }
}
