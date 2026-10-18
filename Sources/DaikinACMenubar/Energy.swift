import Foundation

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
