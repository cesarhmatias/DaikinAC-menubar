import Foundation

// Offline checks run by `--self-check`. Nothing here touches the network, the
// Keychain or an AC.
enum FeatureChecks {
    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }
    static func equal<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) throws {
        guard a == b else { throw Failure(detail: "\(what): \(a) != \(b) (FeatureChecks.swift:\(line))") }
    }
    static func truth(_ value: Bool, _ what: String, line: Int = #line) throws {
        guard value else { throw Failure(detail: "\(what) (FeatureChecks.swift:\(line))") }
    }
    static func rejects(_ what: String, line: Int = #line, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure(detail: "Expected rejection: \(what) (FeatureChecks.swift:\(line))")
    }

    static func run() async throws {
        try testCRC16Genibus()
        try testTemperatureClamp()
        try testPort1DecodeAndEncode()
        try testDailyEnergyDeltasAndMeterReset()
        try testThreeStatusConventions()
        try testErrorTranslationRequest()
        try testWeekdaysSundayToSaturday()
        try testAmplifySignInHasNoSecretHash()
        print("PASS: CRC-16/GENIBUS check value and table; temperature clamp 10–32; port1 decode (mode 0 as AUTO, lenient numbers, sensors, fw_ver) and change-only encode; daily kWh deltas with meter reset, weekly and monthly totals; status 0 / \"success\" / statusCode 500|1; DAIKIN:<code> + pt-BR; SUN…SAT; Amplify USER_PASSWORD_AUTH without SECRET_HASH.")
    }

    static func testCRC16Genibus() throws {
        try equal(CRC16.genibus(Array("123456789".utf8)), 0xD64E, "CRC-16/GENIBUS check value")
        // Spot values of the CCITT table published in the official pyiotdevice library.
        try equal(CRC16.table[1], 4129, "CRC table[1]")
        try equal(CRC16.table[16], 4657, "CRC table[16]")
        try equal(CRC16.table[255], 7920, "CRC table[255]")
        try equal(CRC16.genibus([UInt8]()), 0x0000, "CRC of empty input")
    }

    static func testTemperatureClamp() throws {
        try equal(Port1.clampTemperature(5), 10, "clamp below range")
        try equal(Port1.clampTemperature(10), 10, "clamp lower bound")
        try equal(Port1.clampTemperature(24), 24, "clamp inside range")
        try equal(Port1.clampTemperature(32), 32, "clamp upper bound")
        try equal(Port1.clampTemperature(40), 32, "clamp above range")
        try equal(Port1.setting(temperature: 99).temperature, 32, "temperature command is clamped")
        try equal(ACMode.cool.temperatureRange, 18...32, "COOL range")
        try equal(ACMode.heat.temperatureRange, 10...30, "HEAT range")
        try truth(ACMode.fan.temperatureRange == nil && ACMode.dry.temperatureRange == nil, "FAN and DRY have no target")
    }

    static func testPort1DecodeAndEncode() throws {
        let reported = """
        {"port1":{"power":1,"mode":3,"temperature":24.0,"fan":17,"h_swing":0,"v_swing":1,"coanda":0,"econo":0,
        "powerchill":0,"good_sleep":0,"streamer":1,"out_quite":0,"on_timer_set":0,"on_timer_value":0,
        "off_timer_set":1,"off_timer_value":90,"sensors":{"room_temp":25.5,"out_temp":31.0},"fw_ver":"1.2.3","unknown_key":7}}
        """
        let state = try JSONDecoder().decode(PortEnvelope.self, from: Data(reported.utf8)).port1
        try equal(state.isOn, true, "power")
        try equal(state.acMode, .cool, "mode")
        try equal(state.temperature, 24, "temperature given as 24.0")
        try equal(state.fanSpeed, .auto, "fan")
        try equal(state.vSwing, 1, "v_swing")
        try equal(state.offTimerValue, 90, "off_timer_value")
        try equal(state.sensors, Sensors(roomTemp: 25.5, outTemp: 31.0), "sensors")
        try equal(state.fwVer, "1.2.3", "fw_ver")

        let auto = try JSONDecoder().decode(PortEnvelope.self, from: Data(#"{"port1":{"power":1,"mode":0}}"#.utf8)).port1
        try equal(auto.acMode, .auto, "mode 0 is AUTO")
        try truth(ACMode(wire: 5) == nil, "mode 5 is unknown")
        try truth(FanSpeed(rawValue: 8) == nil, "fan 8 is unknown")

        // A command carries only the changed keys.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func encoded(_ change: Port1) throws -> String { String(decoding: try encoder.encode(PortEnvelope(port1: change)), as: UTF8.self) }
        try equal(try encoded(.setting(power: true)), #"{"port1":{"power":1}}"#, "power command")
        try equal(try encoded(.setting(mode: .cool)), #"{"port1":{"mode":3,"power":1}}"#, "mode command")
        try equal(try encoded(.setting(mode: .dry)), #"{"port1":{"fan":17,"mode":2,"power":1}}"#, "DRY forces automatic fan")
        try equal(try encoded(.setting(fan: .quiet)), #"{"port1":{"fan":18}}"#, "fan command")
        var full = state; full.temperature = 22
        let roundTrip = try JSONDecoder().decode(PortEnvelope.self, from: encoder.encode(PortEnvelope(port1: full))).port1
        try equal(roundTrip, full, "full port1 round trip")
    }

    static func testDailyEnergyDeltasAndMeterReset() throws {
        let readings = [
            KWhReading(date: "2026-10-01 00:00:00", kwhValue: 100),
            KWhReading(date: "2026-10-01 18:00:00", kwhValue: 104),
            KWhReading(date: "2026-10-02 06:00:00", kwhValue: 110),
            KWhReading(date: "2026-10-02 12:00:00", kwhValue: 109.5), // a lower sample the same day is ignored
            KWhReading(date: "2026-10-03 06:00:00", kwhValue: 2),     // meter reset
            KWhReading(date: "2026-10-08 06:00:00", kwhValue: 7),
            KWhReading(date: "2026-11-01 06:00:00", kwhValue: 10),
        ]
        let usage = Energy.dailyUsage(readings.shuffled())
        try equal(usage.map(\.day), ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-08", "2026-11-01"], "one entry per day, sorted")
        try equal(usage.map(\.kwh), [0, 6, 0, 5, 3], "first day 0, deltas, reset gives 0")
        try equal(Energy.weeklyTotals(usage, month: "2026-10"), [1: 6, 2: 5], "weeks W1 and W2")
        try equal(Energy.monthlyTotals(usage, year: "2026"), ["2026-10": 11, "2026-11": 3], "monthly totals")
        try equal(Energy.total(usage, prefix: "2026-10-02"), 6, "single-day total")

        let rows = try JSONDecoder().decode([KWhReading].self, from: Data(#"[{"date":"2026-10-01 00:00:00","kwh_value":"12.5"}]"#.utf8))
        try equal(rows.first?.kwhValue, 12.5, "kwh_value given as a string")
        try equal(Energy.syncInterval, 21_600, "6 h sync cadence")
    }

    static func testThreeStatusConventions() throws {
        // managething: integer 0
        try equal(try APIStatus.manageThing(["status": 0, "json_response": ["things": []]])["things"] as? [String], [], "status 0")
        try rejects("status 1") { _ = try APIStatus.manageThing(["status": 1, "message": "bad"]) }
        try rejects("status \"0\" as a string") { _ = try APIStatus.manageThing(["status": "0"]) }
        try rejects("status false") { _ = try APIStatus.manageThing(["status": false]) }
        try rejects("status missing") { _ = try APIStatus.manageThing([:]) }
        do { _ = try APIStatus.manageThing(["status": 2, "message": "Token expired"]); throw Failure(detail: "status 2 accepted") }
        catch let error as DaikinError { try equal(error, .api(endpoint: "managething", reason: "Token expired"), "managething reason from message") }

        // energy: the string "success"
        try equal(try APIStatus.energy(["status": "success", "kwh_data": [["date": "x"]]]).count, 1, "status success")
        try rejects("energy status 0") { _ = try APIStatus.energy(["status": 0]) }
        try rejects("energy status failure") { _ = try APIStatus.energy(["status": "failure"]) }

        // comfort profiles and firmware: statusCode 500 or 1 is a failure
        try truth((try APIStatus.statusCode(["statusCode": 200, "data": []], endpoint: "comfortprofile"))["data"] != nil, "statusCode 200")
        try truth((try? APIStatus.statusCode(["status": "ok"], endpoint: "firmware")) != nil, "no statusCode is not a failure")
        try rejects("statusCode 500") { _ = try APIStatus.statusCode(["statusCode": 500], endpoint: "firmware") }
        try rejects("statusCode 1") { _ = try APIStatus.statusCode(["statusCode": 1], endpoint: "comfortprofile") }
        try rejects("statusCode \"500\"") { _ = try APIStatus.statusCode(["statusCode": "500"], endpoint: "comfortprofile") }
        do { _ = try APIStatus.statusCode(["statusCode": 1, "message": "Rule not found"], endpoint: "comfortprofile"); throw Failure(detail: "statusCode 1 accepted") }
        catch let error as DaikinError { try equal(error, .api(endpoint: "comfortprofile", reason: "Rule not found"), "statusCode reason from message") }
    }

    static func testErrorTranslationRequest() throws {
        try equal(DeviceHealth.manufacturerErrorCode("A5"), "DAIKIN:A5", "prefix added")
        try equal(DeviceHealth.manufacturerErrorCode(" U4 "), "DAIKIN:U4", "code trimmed")
        try equal(DeviceHealth.manufacturerErrorCode("DAIKIN:A5"), "DAIKIN:A5", "prefix not doubled")
        let body = DeviceHealth.errorTranslationBody(code: "A5", userName: "sub", accessToken: "token")
        try equal(body["request_type"] as? String, "GET_THING_ERROR_TRANSLATION", "request type")
        let request = body["json_request"] as? [String: String]
        try equal(request?["manufacturer_error_code"], "DAIKIN:A5", "manufacturer_error_code")
        try equal(request?["country_lang_code"], "pt-BR", "country_lang_code")
    }

    static func testWeekdaysSundayToSaturday() throws {
        try equal(Weekday.allCases.map(\.rawValue), ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"], "SUN…SAT order")
        try equal(Weekday(calendarWeekday: 1), .sun, "Calendar 1 is Sunday")
        try equal(Weekday(calendarWeekday: 7), .sat, "Calendar 7 is Saturday")
        try truth(Weekday(calendarWeekday: 0) == nil && Weekday(calendarWeekday: 8) == nil, "out-of-range weekday")
        try equal(try JSONDecoder().decode([Weekday].self, from: Data(#"["MON","FRI"]"#.utf8)), [.mon, .fri], "decode days_of_week")
        try rejects("MONDAY is not a weekday") { _ = try JSONDecoder().decode([Weekday].self, from: Data(#"["MONDAY"]"#.utf8)) }
        try equal(Weekday.wed.shortTitle, "Wed", "short title")
    }

    static func testAmplifySignInHasNoSecretHash() throws {
        let request = try CognitoRequest.initiateAuth(username: "someone", password: "not-a-real-password")
        try equal(request.url?.host, "cognito-idp.us-east-1.amazonaws.com", "Cognito host")
        try equal(request.value(forHTTPHeaderField: "X-Amz-Target"), "AWSCognitoIdentityProviderService.InitiateAuth", "target")
        guard let data = request.httpBody, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parameters = body["AuthParameters"] as? [String: String] else { throw Failure(detail: "InitiateAuth body is not JSON") }
        try equal(body["ClientId"] as? String, "2tl54vtfepvo3nu23um3c6rjs9", "Amplify client")
        try equal(body["AuthFlow"] as? String, "USER_PASSWORD_AUTH", "auth flow")
        try equal(Set(parameters.keys), ["USERNAME", "PASSWORD"], "only USERNAME and PASSWORD")
        try truth(!String(decoding: data, as: UTF8.self).contains("SECRET_HASH"), "no SECRET_HASH anywhere in the body")

        let refresh = try CognitoRequest.refresh(refreshToken: "refresh")
        let refreshBody = String(decoding: refresh.httpBody ?? Data(), as: UTF8.self)
        try truth(refreshBody.contains("REFRESH_TOKEN_AUTH") && !refreshBody.contains("SECRET_HASH"), "refresh has no SECRET_HASH")
    }
}
