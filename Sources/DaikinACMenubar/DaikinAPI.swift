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

// Only read-only managething request types exist here. ADD_THING, UPDATE_THING,
// DELETE_THING, INITIATE_FIRMWARE_UPGRADE and DELETE_USER_ACCOUNT are deliberately absent.
enum ManageThingRequest: String, CaseIterable {
    case getThingInfo = "GET_THING_INFO"
    case getThingErrorTranslation = "GET_THING_ERROR_TRANSLATION"
}

struct ThingError: Equatable, Identifiable {
    var transactionID: String?
    var thingID: String?
    var code: String
    var description: String?
    var manufacturerCode: String?
    var id: String { [transactionID, thingID, code].compactMap { $0 }.joined(separator: "/") }
}

struct CloudSubscription: Equatable {
    var status: String?
    var expiryDate: String?
    var expiry: Date? { expiryDate.flatMap(Lenient.date) }
}

struct Thing: Identifiable, Equatable {
    var id: String
    var name: String
    var model: String?
    var isAuthorized: Bool?
    var apn: String?
    // Kept in memory only; it is the local AES key seed (phase 6).
    var secretKey: String?
    var subscription: CloudSubscription?
}

struct ThingInfo: Equatable {
    var things: [Thing]
    var errors: [ThingError]
    func errors(for thing: Thing) -> [ThingError] { errors.filter { $0.thingID == nil || $0.thingID == thing.id } }
}

enum DaikinAPI {
    static func manageThingBody(_ type: ManageThingRequest, sub: String, accessToken: String, jsonRequest: [String: Any] = [:]) -> [String: Any] {
        ["request_type": type.rawValue, "user_name": sub, "access_token": accessToken, "json_request": jsonRequest]
    }

    static func thingInfo(_ tokens: CognitoTokens) async throws -> ThingInfo {
        guard let sub = tokens.sub else { throw DaikinError.message("The ID token has no sub claim.") }
        let json = try await post(DaikinEndpoint.manageThing, body: manageThingBody(.getThingInfo, sub: sub, accessToken: tokens.accessToken),
                                  idToken: tokens.idToken, shape: "managething-get-thing-info")
        return parseThingInfo(try APIStatus.manageThing(json))
    }

    static func post(_ url: URL, body: [String: Any], idToken: String, shape: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(idToken, forHTTPHeaderField: "Authorization")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        ResponseShapes.record(shape, data: data, status: status)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status), let json else {
            let detail = json.flatMap { $0["message"] as? String ?? $0["Message"] as? String } ?? "unexpected response"
            throw DaikinError.api(endpoint: url.path, reason: "HTTP \(status): \(detail)")
        }
        return json
    }

    static func parseThingInfo(_ response: [String: Any]) -> ThingInfo {
        let things = (response["things"] as? [[String: Any]] ?? []).enumerated().compactMap { index, raw -> Thing? in
            guard let id = Lenient.string(raw["thing_id"]), !id.isEmpty else { return nil }
            let metadata = raw["thing_metadata"] as? [String: Any] ?? [:]
            let names = [metadata["thing_name"], raw["thing_name"], raw["model_name"], raw["model_desc"], metadata["thing_apn"]]
            let subscription = (raw["cloud_subscription"] as? [String: Any]).map {
                CloudSubscription(status: Lenient.string($0["status"]), expiryDate: Lenient.string($0["expiry_date"]))
            }
            return Thing(id: id, name: names.lazy.compactMap(Lenient.string).first { !$0.isEmpty } ?? "AC \(index + 1)",
                         model: Lenient.string(raw["model_name"]) ?? Lenient.string(metadata["thing_model_no"]),
                         isAuthorized: Lenient.int(raw["is_device_authorized"]).map { $0 == 1 },
                         apn: Lenient.string(metadata["thing_apn"]), secretKey: Lenient.string(metadata["thing_secret_key"]),
                         subscription: subscription)
        }
        let errors = (response["error_data"] as? [[String: Any]] ?? []).compactMap { raw -> ThingError? in
            guard let code = Lenient.string(raw["error_code"]), !code.isEmpty else { return nil }
            return ThingError(transactionID: Lenient.string(raw["error_trx_id"]), thingID: Lenient.string(raw["thing_id"]), code: code,
                              description: Lenient.string(raw["error_desc"]), manufacturerCode: Lenient.string(raw["manufacturer_error_code"]))
        }
        return ThingInfo(things: things, errors: errors)
    }
}

// Response shapes are unverified, so values are read leniently.
enum Lenient {
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }
    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return (value as? String).flatMap { Int($0) }
    }
    static func date(_ text: String) -> Date? {
        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds) }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "dd/MM/yyyy", "dd-MM-yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "America/Sao_Paulo")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

// Records what each endpoint really returns, with every value masked, so response
// shapes can be confirmed against the live API without exposing user data.
// Letters become a/A, digits become 9; only non-sensitive enum-like keys keep their value.
enum ResponseShapes {
    static var enabled = true
    static let verbatimKeys: Set<String> = [
        "status", "statusCode", "result", "__type", "ChallengeName", "TokenType", "ExpiresIn", "is_device_authorized",
        "error_code", "manufacturer_error_code", "manufacturer", "model_name", "model_desc", "model_version",
        "appliance_type", "thing_model_no",
    ]
    // Free text that explains failures; kept, but e-mail addresses and tokens inside are masked.
    static let messageKeys: Set<String> = ["message", "Message", "error_desc", "error", "error_message"]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DaikinAC-menubar/shapes", isDirectory: true)
    }

    static func record(_ name: String, data: Data, status: Int?) {
        guard enabled else { return }
        let body: Any = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? "<\(data.count) bytes, not JSON>"
        let document: [String: Any] = ["http_status": status ?? 0, "recorded_at": ISO8601DateFormatter().string(from: Date()), "body": mask(body)]
        guard let output = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? output.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }

    static func mask(_ value: Any, key: String? = nil) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key, mask($0.value, key: $0.key)) })
        case let array as [Any]:
            var items = array.prefix(3).map { mask($0, key: key) }
            if array.count > 3 { items.append("… \(array.count) items in total") }
            return items
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            if let key, verbatimKeys.contains(key) { return number }
            return CFNumberIsFloatType(number) ? "<float>" : "<int>"
        case let text as String:
            if let key, verbatimKeys.contains(key) { return text }
            if let key, messageKeys.contains(key) { return scrub(text) }
            return pattern(text)
        case is NSNull:
            return NSNull()
        default:
            return "<\(type(of: value))>"
        }
    }

    static func pattern(_ text: String) -> String {
        let masked = String(text.prefix(48).map { $0.isLetter ? ($0.isUppercase ? "A" : "a") : $0.isNumber ? "9" : $0 })
        return text.count > 48 ? masked + "…(\(text.count))" : masked
    }

    static func scrub(_ text: String) -> String {
        var result = text
        for expression in [#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#] {
            result = result.replacingOccurrences(of: expression, with: "<redacted>", options: .regularExpression)
        }
        return result
    }
}
