import Foundation

// Comfort profiles (schedules). `days_of_week` uses three-letter English names.
enum Weekday: String, CaseIterable, Identifiable, Codable {
    case sun = "SUN", mon = "MON", tue = "TUE", wed = "WED", thu = "THU", fri = "FRI", sat = "SAT"
    var id: String { rawValue }

    // Foundation's Calendar numbers weekdays 1 (Sunday) through 7 (Saturday).
    init?(calendarWeekday: Int) {
        guard (1...7).contains(calendarWeekday) else { return nil }
        self = Weekday.allCases[calendarWeekday - 1]
    }
    var calendarWeekday: Int { Weekday.allCases.firstIndex(of: self)! + 1 }
    var shortTitle: String { rawValue.prefix(1) + rawValue.dropFirst().lowercased() }
}
