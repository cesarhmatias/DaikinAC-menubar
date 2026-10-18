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
