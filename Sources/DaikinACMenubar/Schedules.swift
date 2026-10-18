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

struct ComfortRule: Identifiable, Equatable {
    var id: String
    var name: String
    var type: String?
    var enabled: Bool
    var settings: Port1          // power, mode, temperature and fan, as port1 integers
    var days: [Weekday]
    var executeAt: String?       // "HH:mm"
    var startDate: String?
    var endDate: String?
    var updatedAt: Date?
}

struct ComfortProfile: Equatable {
    var thingID: String
    var rules: [ComfortRule]
}

struct ExecutionLog: Identifiable, Equatable {
    var id: String
    var ruleID: String?
    var ruleName: String?
    var ruleType: String?
    var executedAt: Date?
    var status: String?
    var statusMessage: String?
}

// Reads only. ADD, UPDATE and DELETE change the user's real schedules and are added
// separately, behind an explicit confirmation in the app.
enum Schedules {
    enum ReadRequest: String, CaseIterable {
        case profiles = "GET_COMFORT_PROFILES"
        case executionLogs = "GET_COMFORT_PROFILE_EXEC_LOGS"
    }

    // Covers every device of the account; there is no thing_id in the request.
    static func readBody(_ request: ReadRequest, sub: String, nextToken: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["request_type": request.rawValue, "user_name": sub, "language": DeviceHealth.errorLanguage]
        if let nextToken, !nextToken.isEmpty { body["next_token"] = nextToken }
        return body
    }

    static func profiles(tokens: CognitoTokens) async throws -> [ComfortProfile] {
        guard let sub = tokens.sub else { throw DaikinError.message("The ID token has no sub claim.") }
        let json = try await DaikinAPI.post(DaikinEndpoint.comfortProfiles, body: readBody(.profiles, sub: sub), idToken: tokens.idToken, shape: "comfort-profiles")
        return parseProfiles(try APIStatus.statusCode(json, endpoint: "comfortprofile"))
    }

    static func executionLogs(tokens: CognitoTokens, nextToken: String?) async throws -> (logs: [ExecutionLog], nextToken: String?) {
        guard let sub = tokens.sub else { throw DaikinError.message("The ID token has no sub claim.") }
        let json = try await DaikinAPI.post(DaikinEndpoint.comfortProfiles, body: readBody(.executionLogs, sub: sub, nextToken: nextToken),
                                            idToken: tokens.idToken, shape: "comfort-profile-exec-logs")
        return parseLogs(try APIStatus.statusCode(json, endpoint: "comfortprofile"))
    }

    static func parseProfiles(_ json: [String: Any]) -> [ComfortProfile] {
        let profiles = (json["data"] as? [String: Any])?["comfort_profiles"] as? [[String: Any]] ?? []
        return profiles.compactMap { raw in
            guard let thingID = Lenient.string(raw["thing_id"]) else { return nil }
            let rules = (raw["rules"] as? [[String: Any]] ?? []).compactMap(parseRule)
            return ComfortProfile(thingID: thingID, rules: rules)
        }
    }

    static func parseRule(_ raw: [String: Any]) -> ComfortRule? {
        guard let id = Lenient.string(raw["rule_id"]) else { return nil }
        let settings = raw["settings"] as? [String: Any] ?? [:]
        var port1 = Port1()
        port1.power = Lenient.int(settings["power"]); port1.mode = Lenient.int(settings["mode"])
        port1.temperature = Lenient.int(settings["temperature"]); port1.fan = Lenient.int(settings["fan"])
        let schedule = raw["schedule"] as? [String: Any] ?? [:]
        let days = (schedule["days_of_week"] as? [Any] ?? []).compactMap { Lenient.string($0).flatMap { Weekday(rawValue: $0.uppercased()) } }
        return ComfortRule(id: id, name: Lenient.string(raw["rule_name"]) ?? "Schedule", type: Lenient.string(raw["type"]),
                           enabled: (raw["enabled"] as? Bool) ?? (Lenient.int(raw["enabled"]) == 1), settings: port1,
                           days: Weekday.allCases.filter(days.contains), executeAt: Lenient.string(schedule["execute_at"]),
                           startDate: Lenient.string(schedule["start_date"]), endDate: Lenient.string(schedule["end_date"]),
                           updatedAt: Lenient.string(raw["updated_at"]).flatMap(Lenient.date))
    }

    static func parseLogs(_ json: [String: Any]) -> (logs: [ExecutionLog], nextToken: String?) {
        let data = json["data"] as? [String: Any] ?? [:]
        let logs = (data["exec_logs"] as? [[String: Any]] ?? []).enumerated().map { index, raw in
            ExecutionLog(id: Lenient.string(raw["sk"]) ?? Lenient.string(raw["pk"]).map { "\($0)#\(index)" } ?? "log-\(index)",
                         ruleID: Lenient.string(raw["rule_id"]), ruleName: Lenient.string(raw["rule_name"]), ruleType: Lenient.string(raw["rule_type"]),
                         executedAt: Lenient.string(raw["executed_at"]).flatMap(Lenient.date), status: Lenient.string(raw["status"]),
                         statusMessage: Lenient.string(raw["status_msg"]))
        }
        let next = Lenient.string(data["next_token"]).flatMap { $0.isEmpty ? nil : $0 }
        return (logs, next)
    }

    // "Mon–Fri", "Every day", "Sat, Sun" …
    static func describe(_ days: [Weekday]) -> String {
        if days.count == 7 { return "Every day" }
        if days == [.mon, .tue, .wed, .thu, .fri] { return "Weekdays" }
        if days == [.sun, .sat] { return "Weekends" }
        return days.isEmpty ? "No days" : days.map(\.shortTitle).joined(separator: ", ")
    }
}
