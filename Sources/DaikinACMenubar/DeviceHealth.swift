import Foundation

// Errors, diagnostics, the read-only firmware check and the cloud subscription.
enum DeviceHealth {
    static let errorLanguage = "pt-BR"

    // The translation service expects the code prefixed with the manufacturer.
    static func manufacturerErrorCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.uppercased().hasPrefix("DAIKIN:") ? "DAIKIN:" + trimmed.dropFirst(7) : "DAIKIN:" + trimmed
    }

    static func errorTranslationBody(code: String, userName: String, accessToken: String) -> [String: Any] {
        [
            "request_type": "GET_THING_ERROR_TRANSLATION",
            "user_name": userName,
            "access_token": accessToken,
            "json_request": [
                "manufacturer_error_code": manufacturerErrorCode(code),
                "country_lang_code": errorLanguage,
            ],
        ]
    }
}

struct FirmwareInfo: Equatable {
    var status: String          // LATEST, UPGRADE_AVAILABLE, REQUESTED, IN_PROGRESS or FAILED
    var latestVersion: String?
    var releaseNotes: String?
    var summary: String {
        switch status.uppercased() {
        case "LATEST": return "Up to date"
        case "UPGRADE_AVAILABLE": return "Update available" + (latestVersion.map { ": \($0)" } ?? "")
        case "REQUESTED", "IN_PROGRESS": return "Update in progress"
        case "FAILED": return "Last update failed"
        default: return status
        }
    }
}

struct DiagnosticReport: Equatable {
    struct Result: Equatable { var label: String; var status: String }
    var accessMode: String?
    var firmwareVersion: String?
    var statusTexts: [String]
    var results: [Result]
    var deviceErrorCode: String?
}

extension DeviceHealth {
    static let subscriptionWarningDays = 30

    // nil while the subscription is fine; a short warning when it ends within 30 days or has ended.
    static func subscriptionWarning(_ subscription: CloudSubscription?, now: Date = Date()) -> String? {
        guard let subscription else { return nil }
        if let status = subscription.status, status.uppercased() != "ACTIVE" { return "Cloud subscription is \(status.lowercased())." }
        guard let expiry = subscription.expiry else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: Calendar.current.startOfDay(for: expiry)).day ?? 0
        if days < 0 { return "Cloud subscription expired. Remote control may stop; local control is not affected." }
        if days <= subscriptionWarningDays { return "Cloud subscription ends in \(days) day\(days == 1 ? "" : "s")." }
        return nil
    }

    // The translation answers `{"error_desc": "…"}` at the top level.
    static func translateError(code: String, tokens: CognitoTokens) async throws -> String? {
        guard let sub = tokens.sub else { throw DaikinError.message("The ID token has no sub claim.") }
        let json = try await DaikinAPI.post(DaikinEndpoint.manageThing, body: errorTranslationBody(code: code, userName: sub, accessToken: tokens.accessToken),
                                            idToken: tokens.idToken, shape: "managething-error-translation")
        return Lenient.string(json["error_desc"]).flatMap { $0.isEmpty ? nil : $0 }
    }

    // Read-only check. INITIATE_FIRMWARE_UPGRADE is never built: it flashes the unit.
    static func firmwareBody(sub: String, thingID: String, firmwareVersion: String) -> [String: Any] {
        ["request_type": "GET_LATEST_FIRMWARE_DATA", "user_name": sub, "language": errorLanguage,
         "data": [["thing_id": thingID, "fw_version": firmwareVersion]]]
    }

    static func latestFirmware(tokens: CognitoTokens, thingID: String, firmwareVersion: String) async throws -> FirmwareInfo? {
        guard let sub = tokens.sub else { throw DaikinError.message("The ID token has no sub claim.") }
        let json = try await DaikinAPI.post(DaikinEndpoint.firmware, body: firmwareBody(sub: sub, thingID: thingID, firmwareVersion: firmwareVersion),
                                            idToken: tokens.idToken, shape: "firmware-get-latest")
        return parseFirmware(try APIStatus.statusCode(json, endpoint: "firmware"), thingID: thingID)
    }

    static func parseFirmware(_ json: [String: Any], thingID: String) -> FirmwareInfo? {
        let rows = json["data"] as? [[String: Any]] ?? []
        guard let row = rows.first(where: { Lenient.string($0["thing_id"]) == thingID }) ?? rows.first,
              let status = Lenient.string(row["fw_status"]) else { return nil }
        return FirmwareInfo(status: status, latestVersion: Lenient.string(row["latest_fw_version"]), releaseNotes: Lenient.string(row["release_notes"]))
    }

    // The server-side connectivity check. Diagnostic data is never shared ("No"); the reply's
    // e-mail, phone number and coordinates are not read.
    static func diagnosticsBody(thingID: String, cognitoID: String, sub: String, accessToken: String, localReachable: Bool) -> [String: Any] {
        ["thing_id": thingID, "cognito_id": cognitoID, "share_diagnostic_data": "No", "user_name": sub, "access_token": accessToken,
         "language_code": errorLanguage, "mobile_os": "macOS", "local_reachability": localReachable]
    }

    static func runDiagnostics(tokens: CognitoTokens, cognitoID: String, thingID: String) async throws -> DiagnosticReport {
        guard let sub = tokens.sub else { throw DaikinError.message("The ID token has no sub claim.") }
        let json = try await DaikinAPI.post(DaikinEndpoint.diagnostics, body: diagnosticsBody(thingID: thingID, cognitoID: cognitoID, sub: sub,
                                                                                           accessToken: tokens.accessToken, localReachable: false),
                                            idToken: tokens.idToken, shape: "diagnostics")
        return parseDiagnostics(try APIStatus.statusCode(json, endpoint: "diagnostics"))
    }

    static func parseDiagnostics(_ json: [String: Any]) -> DiagnosticReport {
        let data = json["data"] as? [String: Any] ?? [:]
        let results = (data["diagnosis_results"] as? [[String: Any]] ?? []).compactMap { row -> DiagnosticReport.Result? in
            guard let label = Lenient.string(row["label"]) else { return nil }
            return DiagnosticReport.Result(label: label, status: Lenient.string(row["status"]) ?? "")
        }
        let deviceError = data["device_error_data"] as? [String: Any]
        return DiagnosticReport(accessMode: Lenient.string(data["device_access_mode"]), firmwareVersion: Lenient.string(data["firmware_version"]),
                                statusTexts: (data["status_texts"] as? [Any] ?? []).compactMap(Lenient.string),
                                results: results, deviceErrorCode: deviceError.flatMap { Lenient.string($0["error_code"]) }.flatMap { $0.isEmpty ? nil : $0 })
    }
}
