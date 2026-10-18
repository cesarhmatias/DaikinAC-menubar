import Foundation

enum DaikinError: LocalizedError, Equatable {
    case message(String)
    case api(endpoint: String, reason: String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .api(let endpoint, let reason): return "\(endpoint): \(reason)"
        }
    }
}

// Public REST hosts used by the official app. Every call is an HTTPS POST whose
// Authorization header is the raw Cognito ID token.
enum DaikinEndpoint {
    static let host = "dmb.iotalabs.co.in"
    static let manageThing = URL(string: "https://dmb.iotalabs.co.in/devices/thinginfo/managething")!
    static let attachPolicy = URL(string: "https://dmb.iotalabs.co.in/policy/policy/attachprincipalpolicy")!
    static let diagnostics = URL(string: "https://dmb.iotalabs.co.in/diagnostics/smartac")!
    static let comfortProfiles = URL(string: "https://dmb.iotalabs.co.in/comfortprofile/comfort-profile-manager")!
    static let energy = URL(string: "https://dmb.iotalabs.co.in/energydata/device-kwh-data")!
    static let firmware = URL(string: "https://dmb.iotalabs.co.in/devicefirmwareupgrade/device-firmware-upgrade-manager")!
}

// The backend uses three different success conventions. Each endpoint is parsed
// with its own; mixing them would treat some failures as successes.
enum APIStatus {
    // managething: `{"status": 0, "json_response": {…}}`, where 0 must be an integer.
    static func manageThing(_ json: [String: Any]) throws -> [String: Any] {
        guard let number = json["status"] as? NSNumber, !isBoolean(number), number.intValue == 0,
              number.doubleValue == 0 else {
            throw DaikinError.api(endpoint: "managething", reason: reason(json, fallback: "status \(describe(json["status"]))"))
        }
        return json["json_response"] as? [String: Any] ?? [:]
    }

    // energy: `{"status": "success", "kwh_data": […]}`, a string.
    static func energy(_ json: [String: Any]) throws -> [[String: Any]] {
        guard (json["status"] as? String)?.lowercased() == "success" else {
            throw DaikinError.api(endpoint: "energy", reason: reason(json, fallback: "status \(describe(json["status"]))"))
        }
        return json["kwh_data"] as? [[String: Any]] ?? []
    }

    // comfort profiles and firmware: failure is `statusCode` 500 or 1, reason in `message`.
    static func statusCode(_ json: [String: Any], endpoint: String) throws -> [String: Any] {
        let code = (json["statusCode"] as? NSNumber).flatMap { isBoolean($0) ? nil : $0.intValue }
            ?? (json["statusCode"] as? String).flatMap(Int.init)
        if code == 500 || code == 1 {
            throw DaikinError.api(endpoint: endpoint, reason: reason(json, fallback: "statusCode \(code!)"))
        }
        return json
    }

    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
    private static func reason(_ json: [String: Any], fallback: String) -> String {
        for key in ["message", "error", "error_message"] {
            if let text = json[key] as? String, !text.isEmpty { return text }
        }
        return fallback
    }
    private static func describe(_ value: Any?) -> String { value.map { "\($0)" } ?? "missing" }
}
