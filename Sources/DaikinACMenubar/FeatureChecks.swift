import Foundation
import CryptoKit
import BigInt

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
        ResponseShapes.enabled = false
        try testCRC16Genibus()
        try testTemperatureClamp()
        try testPort1DecodeAndEncode()
        try testDailyEnergyDeltasAndMeterReset()
        try testThreeStatusConventions()
        try testErrorTranslationRequest()
        try testWeekdaysSundayToSaturday()
        try testAmplifySignInHasNoSecretHash()
        try testSRPMatchesPycognito()
        try testCognitoResponses()
        try testThingInfoKeepsErrorsAndSubscription()
        try testOnlyReadOnlyManageThingRequests()
        try testResponseShapesHideValues()
        try testSigV4MatchesBotocore()
        try testMQTTPackets()
        try testShadowDocumentAndCommandBody()
        try testCommandRules()
        try testEnergySummaryAndCache()
        try testDeviceHealth()
        print("PASS: CRC-16/GENIBUS check value and table; temperature clamp 10–32; port1 decode (mode 0 as AUTO, lenient numbers, sensors, fw_ver) and change-only encode; daily kWh deltas with meter reset, weekly and monthly totals; status 0 / \"success\" / statusCode 500|1; DAIKIN:<code> + pt-BR; SUN…SAT; Amplify USER_SRP_AUTH without SECRET_HASH; SRP k, A, HKDF and signature match pycognito; Cognito tokens, refresh, errors and challenges; GET_THING_INFO with error_data and cloud_subscription; read-only managething types; masked response shapes; SigV4 presigned IoT WebSocket URL matches botocore; MQTT 3.1.1 packets; shadow reported/desired parsing, command body with src 5, Identity Pool credentials; sensor sentinel 255, unit type, command rules, extras (Econo, PowerChill, Coanda) and confirmation matching; energy summary (today, W1–W5, month), incremental cache with 6 h cadence and GET_KWH_DATA body; subscription warning, read-only firmware check, diagnostics without sharing.")
    }

    // A syntactically valid, unsigned JWT built at runtime so no token-shaped literal is tracked.
    static func fakeJWT(_ claims: [String: Any]) -> String {
        func part(_ object: Any) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return part(["alg": "none"]) + "." + part(claims) + ".signature"
    }

    static func testCognitoResponses() throws {
        let mail = "someone" + "@" + "example.com"
        let id = fakeJWT(["sub": "1111-2222", "email": mail, "exp": 1])
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ok = #"{"AuthenticationResult":{"IdToken":"\#(id)","AccessToken":"access","RefreshToken":"refresh","ExpiresIn":3600,"TokenType":"Bearer"},"ChallengeParameters":{}}"#
        let tokens = try CognitoAuth.parse(Data(ok.utf8), status: 200, previousRefreshToken: nil, now: now)
        try equal(tokens.sub, "1111-2222", "sub claim")
        try equal(tokens.email, mail, "email claim")
        try equal(tokens.expiresAt, now.addingTimeInterval(3600), "expiry")
        try truth(!tokens.needsRefresh(now: now) && tokens.needsRefresh(now: now.addingTimeInterval(3400)), "refresh 5 min before expiry")

        let refreshed = #"{"AuthenticationResult":{"IdToken":"\#(id)","AccessToken":"access2","ExpiresIn":3600}}"#
        try equal(try CognitoAuth.parse(Data(refreshed.utf8), status: 200, previousRefreshToken: "refresh", now: now).refreshToken, "refresh", "refresh keeps the refresh token")

        let disabled = #"{"__type":"InvalidParameterException","message":"USER_PASSWORD_AUTH flow not enabled for this client"}"#
        do { _ = try CognitoAuth.parse(Data(disabled.utf8), status: 400, previousRefreshToken: nil); throw Failure(detail: "error accepted") }
        catch let failure as CognitoFailure {
            try equal(failure, CognitoFailure(type: "InvalidParameterException", message: "USER_PASSWORD_AUTH flow not enabled for this client", httpStatus: 400), "flow disabled error")
        }
        let wrong = #"{"__type":"com.amazonaws.cognito#NotAuthorizedException","message":"Incorrect username or password."}"#
        do { _ = try CognitoAuth.parse(Data(wrong.utf8), status: 400, previousRefreshToken: nil); throw Failure(detail: "error accepted") }
        catch let failure as CognitoFailure { try equal(failure.type, "NotAuthorizedException", "namespaced error type") }
        try rejects("challenge without tokens") { _ = try CognitoAuth.parse(Data(#"{"ChallengeName":"NEW_PASSWORD_REQUIRED","Session":"s"}"#.utf8), status: 200, previousRefreshToken: nil) }
        try rejects("HTTP 500 without JSON") { _ = try CognitoAuth.parse(Data("oops".utf8), status: 500, previousRefreshToken: nil) }
        try truth(JWT.claims("not.a-jwt") == nil && JWT.claims("abc") == nil, "malformed JWT")
    }

    static func testThingInfoKeepsErrorsAndSubscription() throws {
        let key = "c2Vj" + "cmV0"
        let fixture = """
        {"status":0,"json_response":{
          "things":[
            {"thing_id":"thing-a","is_device_authorized":1,"model_name":"Split Inverter","model_desc":"desc",
             "thing_metadata":{"thing_apn":"DAIKIN:AABBCC","thing_secret_key":"\(key)","thing_name":"Bedroom"},
             "cloud_subscription":{"status":"ACTIVE","expiry_date":"2027-03-01"}},
            {"thing_id":"thing-b","is_device_authorized":"0","model_desc":"Living room unit"},
            {"model_name":"no id, skipped"}],
          "error_data":[{"error_trx_id":123,"thing_id":"thing-a","error_code":"A5","manufacturer_error_code":"A5"},
                        {"error_code":""}]}}
        """
        let json = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
        let info = DaikinAPI.parseThingInfo(try APIStatus.manageThing(json))
        try equal(info.things.map(\.id), ["thing-a", "thing-b"], "things with an id")
        let a = info.things[0], b = info.things[1]
        try equal(a.name, "Bedroom", "thing name from metadata")
        try equal(b.name, "Living room unit", "name falls back to model_desc")
        try equal(a.isAuthorized, true, "authorized as int"); try equal(b.isAuthorized, false, "authorized as string")
        try equal(a.apn, "DAIKIN:AABBCC", "apn"); try equal(a.secretKey, "c2VjcmV0", "secret key kept in memory")
        try equal(a.subscription, CloudSubscription(status: "ACTIVE", expiryDate: "2027-03-01"), "cloud_subscription")
        try truth(a.subscription?.expiry != nil && b.subscription == nil, "expiry date parsed")
        try equal(info.errors.count, 1, "empty error codes dropped")
        try equal(info.errors[0], ThingError(transactionID: "123", thingID: "thing-a", code: "A5", description: nil, manufacturerCode: "A5"), "error_data")
        try equal(info.errors(for: b).count, 0, "errors are per device")
        for text in ["1760000000", "1760000000000", "2027-03-01T00:00:00Z", "2027-03-01 10:00:00", "01/03/2027"] {
            try truth(Lenient.date(text) != nil, "date format \(text)")
        }
    }

    static func testOnlyReadOnlyManageThingRequests() throws {
        let allowed = Set(ManageThingRequest.allCases.map(\.rawValue))
        try equal(allowed, ["GET_THING_INFO", "GET_THING_ERROR_TRANSLATION"], "managething request types")
        for forbidden in ["ADD_THING", "UPDATE_THING", "DELETE_THING", "INITIATE_FIRMWARE_UPGRADE", "DELETE_USER_ACCOUNT"] {
            try truth(ManageThingRequest(rawValue: forbidden) == nil, "\(forbidden) cannot be built")
        }
        let body = DaikinAPI.manageThingBody(.getThingInfo, sub: "sub", accessToken: "access")
        try equal(body["request_type"] as? String, "GET_THING_INFO", "request_type")
        try equal(body["user_name"] as? String, "sub", "user_name is the sub")
        try truth(body["json_request"] is [String: Any], "json_request object")
    }

    static func testResponseShapesHideValues() throws {
        let mail = "owner" + "@" + "gmail.com"
        let key = "c2VjcmV0" + "S2V5"
        let input: [String: Any] = [
            "status": 0, "message": "Unknown user \(mail)",
            "json_response": ["things": [["thing_id": "Ab12-xyz", "thing_metadata": ["thing_secret_key": key], "latitude": -23.5,
                                          "is_device_authorized": 1, "cloud_subscription": ["status": "ACTIVE", "expiry_date": "2027-03-01"]]]],
        ]
        let masked = ResponseShapes.mask(input)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: masked, options: [.sortedKeys]), as: UTF8.self)
        for secret in ["Ab12-xyz", "c2VjcmV0S2V5", "-23.5", "2027-03-01", mail] {
            try truth(!text.contains(secret), "masked shape hides a value")
        }
        for kept in ["\"Aa99-aaa\"", "\"a9AaaaA9A9A9\"", "<float>", "9999-99-99", "\"ACTIVE\"", "Unknown user <redacted>", "\"is_device_authorized\":1"] {
            try truth(text.contains(kept), "masked shape keeps \(kept)")
        }
        try equal(ResponseShapes.pattern(String(repeating: "x", count: 60)), String(repeating: "a", count: 48) + "…(60)", "long strings truncated")
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
        let srp = try CognitoSRP(a: BigUInt(12345))
        let request = try CognitoRequest.initiateSRP(username: "someone", srpA: srp.srpA)
        try equal(request.url?.host, "cognito-idp.us-east-1.amazonaws.com", "Cognito host")
        try equal(request.value(forHTTPHeaderField: "X-Amz-Target"), "AWSCognitoIdentityProviderService.InitiateAuth", "target")
        guard let data = request.httpBody, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parameters = body["AuthParameters"] as? [String: String] else { throw Failure(detail: "InitiateAuth body is not JSON") }
        try equal(body["ClientId"] as? String, "2tl54vtfepvo3nu23um3c6rjs9", "Amplify client")
        try equal(body["AuthFlow"] as? String, "USER_SRP_AUTH", "auth flow")
        try equal(Set(parameters.keys), ["USERNAME", "SRP_A"], "only USERNAME and SRP_A")
        try truth(!String(decoding: data, as: UTF8.self).contains("SECRET_HASH"), "no SECRET_HASH in InitiateAuth")

        let challenge = try CognitoRequest.respondToPasswordVerifier(["USERNAME": "u", "TIMESTAMP": "t", "PASSWORD_CLAIM_SECRET_BLOCK": "b", "PASSWORD_CLAIM_SIGNATURE": "s"], session: nil)
        let challengeBody = String(decoding: challenge.httpBody ?? Data(), as: UTF8.self)
        try equal(challenge.value(forHTTPHeaderField: "X-Amz-Target"), "AWSCognitoIdentityProviderService.RespondToAuthChallenge", "challenge target")
        try truth(challengeBody.contains("PASSWORD_VERIFIER") && !challengeBody.contains("SECRET_HASH") && !challengeBody.contains("Session"), "challenge has no SECRET_HASH")

        let refresh = try CognitoRequest.refresh(refreshToken: "refresh")
        let refreshBody = String(decoding: refresh.httpBody ?? Data(), as: UTF8.self)
        try truth(refreshBody.contains("REFRESH_TOKEN_AUTH") && !refreshBody.contains("SECRET_HASH"), "refresh has no SECRET_HASH")
    }

    // Reference values computed offline with pycognito 2024.5.1 (aws_srp.py) from the same inputs.
    static func testSRPMatchesPycognito() throws {
        func chain(_ seed: String, _ count: Int) -> BigUInt {
            var bytes = Data(), block = Data(seed.utf8)
            while bytes.count < count { block = Data(SHA256.hash(data: block)); bytes += block }
            return BigUInt(bytes.prefix(count))
        }
        func digest(_ text: String) -> String { Hex.string(Data(SHA256.hash(data: Data(text.utf8)))) }
        try equal(Hex.pad("abc"), "0abc", "pad odd length"); try equal(Hex.pad("8f"), "008f", "pad high nibble"); try equal(Hex.pad("7f"), "7f", "no pad")
        try equal(Hex.string(CognitoSRP.k), "538282c4354742d7cbbde2359fcf67f9f5b3a6b08791e5011b43b8a5b66d9ee6", "k")

        let N = CognitoSRP.N, a = chain("daikin-srp-a", 128) % N, b = chain("daikin-srp-b", 128) % N
        let B = (CognitoSRP.k * CognitoSRP.g.power(BigUInt(12345), modulus: N) + CognitoSRP.g.power(b, modulus: N)) % N
        try equal(digest(Hex.string(a)), "7178f3d5055f3cd921ca9df038989112a87ac72370260a748243b32937b650f9", "a")
        try equal(digest(Hex.string(B)), "4cb3f40d90c82e6c8efa7181dbc76715082d14e82663f52edad9af4033ebb991", "B")
        let srp = try CognitoSRP(a: a)
        try equal(srp.srpA.count, 768, "A is 3072 bits")
        try equal(digest(srp.srpA), "69d58d8599c2ad5879ba3904dd611c1a3b62001de052839af0860d92191d75ce", "A = g^a mod N")

        let userID = "11111111-2222-3333-4444-555555555555", password = "Correct horse battery staple!", salt = "f3a1c2b4d5e6071829304a5b6c7d8e9f"
        let key = try srp.passwordAuthenticationKey(userID: userID, password: password, serverB: B, saltHex: salt)
        try equal(Hex.string(key), "3ef5df62544d6345886b47ae4b90c1e0", "HKDF password authentication key")

        let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 10, day: 9, hour: 5, minute: 7, second: 3).date!
        try equal(CognitoSRP.timestamp(date), "Fri Oct 9 05:07:03 UTC 2026", "timestamp without a leading zero")
        let block = Data(0..<64).base64EncodedString()
        let responses = try srp.challengeResponses(["USER_ID_FOR_SRP": userID, "USERNAME": userID, "SALT": salt, "SRP_B": Hex.string(B), "SECRET_BLOCK": block], password: password, date: date)
        try equal(responses, ["TIMESTAMP": "Fri Oct 9 05:07:03 UTC 2026", "USERNAME": userID, "PASSWORD_CLAIM_SECRET_BLOCK": block,
                              "PASSWORD_CLAIM_SIGNATURE": "X0UBScmcXmCPtE714JURS99BA9WLJeVToQVH+Lsr2fg="], "PASSWORD_VERIFIER responses")
        try rejects("B = 0") { _ = try srp.passwordAuthenticationKey(userID: userID, password: password, serverB: 0, saltHex: salt) }
        try rejects("B = N") { _ = try srp.passwordAuthenticationKey(userID: userID, password: password, serverB: N, saltHex: salt) }
        try rejects("incomplete challenge") { _ = try srp.challengeResponses(["SALT": salt], password: password, date: date) }
    }

    // Reference URL computed offline with botocore 1.40.0 SigV4QueryAuth (token appended after signing,
    // as AWS IoT requires); the keys are AWS's documentation examples.
    static func testSigV4MatchesBotocore() throws {
        let credentials = AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                         sessionToken: "session/token+example=", expiration: .distantFuture)
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 10, day: 19, hour: 12).date!
        let url = SigV4.presignedIoTURL(host: ShadowClient.host, credentials: credentials, region: "us-east-1", date: date)
        try equal(url.absoluteString, "wss://a2zl28lcjjddi3-ats.iot.us-east-1.amazonaws.com/mqtt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIDEXAMPLE%2F20261019%2Fus-east-1%2Fiotdevicegateway%2Faws4_request&X-Amz-Date=20261019T120000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=10d71011b7fe90f8cb85cdee2c9e07518618e6c868b2a05fa7689357c76fa627&X-Amz-Security-Token=session%2Ftoken%2Bexample%3D", "presigned IoT WebSocket URL")
    }

    static func testMQTTPackets() throws {
        let connect = MQTT.connect(clientID: "abc", keepAlive: 60)
        try equal([UInt8](connect), [0x10, 15, 0, 4, 0x4D, 0x51, 0x54, 0x54, 4, 0x02, 0, 60, 0, 3, 0x61, 0x62, 0x63], "CONNECT 3.1.1, clean session, keep-alive 60")
        let subscribe = MQTT.subscribe(packetID: 1, topics: ["a/b"])
        try equal([UInt8](subscribe), [0x82, 8, 0, 1, 0, 3, 0x61, 0x2F, 0x62, 0], "SUBSCRIBE QoS 0")
        try equal([UInt8](MQTT.publish(topic: "t", payload: Data("{}".utf8))), [0x30, 5, 0, 1, 0x74, 0x7B, 0x7D], "PUBLISH QoS 0")
        try equal([UInt8](MQTT.pingreq), [0xC0, 0], "PINGREQ"); try equal([UInt8](MQTT.disconnect), [0xE0, 0], "DISCONNECT")
        try equal([UInt8](MQTT.frame(.publish, 0, Data(count: 200)).prefix(3)), [0x30, 0xC8, 0x01], "two-byte remaining length")

        // Packets split across and packed into WebSocket frames.
        var buffer = Data([0x20, 0x02, 0x00])
        try truth(try MQTT.next(&buffer) == nil, "incomplete packet waits")
        buffer += Data([0x00, 0x90, 0x03, 0x00, 0x01, 0x00])
        try equal(try MQTT.next(&buffer), MQTT.Packet(type: .connack, flags: 0, body: Data([0, 0])), "CONNACK")
        try equal(try MQTT.next(&buffer), MQTT.Packet(type: .suback, flags: 0, body: Data([0, 1, 0])), "SUBACK")
        try truth(buffer.isEmpty, "buffer drained")

        let incoming = MQTT.Packet(type: .publish, flags: 0x02, body: Data([0, 3, 0x61, 0x2F, 0x62, 0x12, 0x34, 0x7B, 0x7D]))
        let contents = MQTT.publishContents(incoming)
        try equal(contents?.topic, "a/b", "incoming topic"); try equal(contents?.payload, Data("{}".utf8), "QoS 1 payload skips the packet id")
        try equal(ShadowClient.topic("thing-a", "get/accepted"), "$aws/things/thing-a/shadow/get/accepted", "shadow topic")
    }

    static func testShadowDocumentAndCommandBody() throws {
        let fixture = """
        {"state":{"reported":{"port1":{"power":1,"mode":4,"temperature":21,"fan":5,"sensors":{"room_temp":19.5},"fw_ver":"2.0.1"},"wifi":{"rssi":-60}},
                  "desired":{"port1":{"temperature":22},"src":5}},"metadata":{},"version":42,"timestamp":1760000000}
        """
        let document = ShadowClient.parse(try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any])
        try equal(document.reported?.acMode, .heat, "reported mode"); try equal(document.reported?.temperature, 21, "reported temperature")
        try equal(document.reported?.sensors?.roomTemp, 19.5, "room_temp"); try equal(document.reported?.fwVer, "2.0.1", "fw_ver")
        try equal(document.desired?.temperature, 22, "pending desired"); try equal(document.version, 42, "version")
        try equal(document.timestamp, Date(timeIntervalSince1970: 1_760_000_000), "timestamp")
        let cleared = ShadowClient.parse(["state": ["reported": ["port1": ["power": 0]], "desired": NSNull()]])
        try truth(cleared.desired == nil && cleared.reported?.isOn == false, "desired cleared means the command was applied")
        try truth(ShadowClient.parse([:]).reported == nil, "empty shadow")

        try equal(String(decoding: try ShadowClient.commandBody(.setting(temperature: 23)), as: UTF8.self),
                  #"{"state":{"desired":{"port1":{"temperature":23},"src":5}}}"#, "command carries only changed keys and src 5")
        try equal(String(decoding: try ShadowClient.commandBody(.setting(mode: .dry)), as: UTF8.self),
                  #"{"state":{"desired":{"port1":{"fan":17,"mode":2,"power":1},"src":5}}}"#, "DRY command")

        let identity = try IdentityPool.parseCredentials(["IdentityId": "x", "Credentials": ["AccessKeyId": "AK", "SecretKey": "SK", "SessionToken": "ST", "Expiration": 1_760_003_600]])
        try equal(identity, AWSCredentials(accessKeyID: "AK", secretKey: "SK", sessionToken: "ST", expiration: Date(timeIntervalSince1970: 1_760_003_600), identityID: "x"), "Identity Pool credentials")
        try rejects("missing credentials") { _ = try IdentityPool.parseCredentials(["IdentityId": "x"]) }
        let getID = try IdentityPool.request("GetId", ["IdentityPoolId": CognitoConfig.identityPoolID])
        try equal(getID.value(forHTTPHeaderField: "X-Amz-Target"), "AWSCognitoIdentityService.GetId", "GetId target")
        try equal(getID.url?.host, "cognito-identity.us-east-1.amazonaws.com", "Identity host")
    }

    static func testCommandRules() throws {
        try equal(Sensors(roomTemp: 24, outTemp: 255).outdoor, nil, "out_temp 255 means no reading")
        try equal(Sensors(roomTemp: 24, outTemp: 255).room, 24, "room_temp kept")
        let live = ShadowClient.parse(["state": ["reported": ["ac_unit_type": "COOL_ONLY", "port1": ["power": 0, "mode": 3, "temperature": 26, "fan": 17]]]])
        try equal(live.unitType, "COOL_ONLY", "ac_unit_type beside port1")
        guard let state = live.reported else { throw Failure(detail: "no reported state") }
        try equal(state.steppedTemperature(by: -1), 25, "one step down"); try equal(state.steppedTemperature(by: 1), 27, "one step up")
        var top = state; top.temperature = 32
        try equal(top.steppedTemperature(by: 1), nil, "COOL stops at 32")
        var heat = state; heat.mode = 4; heat.temperature = 30
        try equal(heat.steppedTemperature(by: 1), nil, "HEAT stops at 30")
        var dry = state; dry.mode = 2
        try truth(!dry.canChangeTemperature && !dry.canChangeFan, "DRY fixes target and fan")
        var boost = state; boost.powerchill = 1
        try truth(!boost.canChangeTemperature && !boost.canChangeFan, "powerful mode fixes target and fan")
        try truth(state.canChangeTemperature && state.canChangeFan, "COOL allows both")

        var after = state; after.temperature = 25
        try truth(after.satisfies(.setting(temperature: 25)) && !state.satisfies(.setting(temperature: 25)), "confirmation compares changed keys")
        var on = state; on.power = 1
        try truth(on.satisfies(.setting(mode: .cool)) && !state.satisfies(.setting(mode: .cool)), "mode command also needs power on")
        // Extras follow the official app's More screen.
        var running = on; running.powerchill = 1; running.coanda = 1
        try equal(running.setting(econo: true), { var p = Port1(); p.econo = 1; p.powerchill = 0; return p }(), "Econo turns PowerChill off")
        var econoOn = on; econoOn.econo = 1; econoOn.coanda = 1
        try equal(econoOn.setting(powerchill: true), { var p = Port1(); p.powerchill = 1; p.econo = 0; p.coanda = 0; return p }(), "PowerChill turns Econo and Coanda off")
        try equal(running.setting(coanda: true), { var p = Port1(); p.coanda = 1; p.fan = 17; p.powerchill = 0; return p }(), "Coanda sends automatic fan")
        try equal(on.setting(econo: false), { var p = Port1(); p.econo = 0; return p }(), "turning Econo off sends only econo")
        var fanMode = on; fanMode.mode = 6
        try truth(on.canUseEcono && !fanMode.canUseEcono && !state.canUseExtras, "Econo needs the unit on and not FAN")
        let update = MQTT.publish(topic: ShadowClient.topic("thing-a", "update"), payload: try ShadowClient.commandBody(.setting(temperature: 25)))
        try truth(MQTT.publishContents(MQTT.Packet(type: .publish, flags: 0, body: update.dropFirst(2)))?.topic == "$aws/things/thing-a/shadow/update", "command topic")
    }

    static func testEnergySummaryAndCache() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let now = DateComponents(calendar: calendar, year: 2026, month: 10, day: 16, hour: 15).date!
        let rows = [("2026-09-30 23:00:00", 90.0), ("2026-10-01 06:00:00", 100.0), ("2026-10-09 06:00:00", 104), ("2026-10-15 06:00:00", 110),
                    ("2026-10-16 06:00:00", 112), ("2026-10-16 12:00:00", 113.5)].map { KWhReading(date: $0.0, kwhValue: $0.1) }
        let summary = EnergySummary(usage: Energy.dailyUsage(rows), now: now, calendar: calendar)
        try equal(summary.today, 3.5, "today = max today − previous day")
        try equal(summary.weekNumber, 3, "16 October is W3")
        try equal(summary.week, 9.5, "W3 = 15th + 16th")
        try equal(summary.weeks, [1: 10, 2: 4, 3: 9.5], "weeks of October")
        try equal(summary.month, 23.5, "October total")
        try equal(summary.months, ["2026-09": 0, "2026-10": 23.5], "months of the year")
        try equal(summary.monthDays.map(\.day), ["2026-10-01", "2026-10-09", "2026-10-15", "2026-10-16"], "days with readings this month")

        var cache = EnergyCache()
        try truth(cache.needsSync(now: now) && cache.latestRecordDate == nil, "first sync is a full pull")
        cache.merge(rows, at: now)
        try equal(cache.latestRecordDate, "2026-10-16 12:00:00", "last_record_date is the newest row")
        try truth(!cache.needsSync(now: now.addingTimeInterval(5 * 3600)) && cache.needsSync(now: now.addingTimeInterval(6 * 3600)), "6 h cadence")
        cache.merge([KWhReading(date: "2026-10-16 12:00:00", kwhValue: 113.5), KWhReading(date: "2026-10-16 18:00:00", kwhValue: 114)], at: now)
        try equal(cache.readings.count, 7, "incremental rows merge without duplicates")
        let restored = try JSONDecoder().decode(EnergyCache.self, from: JSONEncoder().encode(cache))
        try equal(restored, cache, "cache round trip")

        let first = Energy.requestBody(sub: "sub", thingID: "thing-a", lastRecordDate: nil)
        try equal(first["Request_type"] as? String, "GET_KWH_DATA", "capital-R Request_type"); try truth(first["last_record_date"] is NSNull, "null on the first sync")
        try equal(Energy.requestBody(sub: "sub", thingID: "thing-a", lastRecordDate: "2026-10-16 12:00:00")["last_record_date"] as? String, "2026-10-16 12:00:00", "incremental sync")
        try equal(try Energy.parseRows([["date": "2026-10-01 00:00:00", "kwh_value": 1.5]]), [KWhReading(date: "2026-10-01 00:00:00", kwhValue: 1.5)], "kwh_data rows")
        try truth(!Energy.cacheURL(thingID: "thing-a").lastPathComponent.contains("thing-a"), "cache file name hides the thing_id")
    }

    static func testDeviceHealth() throws {
        let now = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 10, day: 19, hour: 12).date!
        try equal(DeviceHealth.subscriptionWarning(CloudSubscription(status: "ACTIVE", expiryDate: "2027-03-01"), now: now), nil, "far expiry")
        try equal(DeviceHealth.subscriptionWarning(CloudSubscription(status: "ACTIVE", expiryDate: "2026-11-02"), now: now), "Cloud subscription ends in 14 days.", "within 30 days")
        try truth(DeviceHealth.subscriptionWarning(CloudSubscription(status: "ACTIVE", expiryDate: "2026-10-01"), now: now)?.hasPrefix("Cloud subscription expired") == true, "expired")
        try equal(DeviceHealth.subscriptionWarning(CloudSubscription(status: "EXPIRED", expiryDate: nil), now: now), "Cloud subscription is expired.", "inactive status")

        let firmware = DeviceHealth.firmwareBody(sub: "sub", thingID: "thing-a", firmwareVersion: "p1.0.4.2")
        try equal(firmware["request_type"] as? String, "GET_LATEST_FIRMWARE_DATA", "read-only firmware request")
        try equal((firmware["data"] as? [[String: String]])?.first, ["thing_id": "thing-a", "fw_version": "p1.0.4.2"], "firmware data row")
        let latest = DeviceHealth.parseFirmware(["status": "ok", "data": [["thing_id": "thing-a", "fw_status": "UPGRADE_AVAILABLE", "latest_fw_version": "p1.0.5.0"]]], thingID: "thing-a")
        try equal(latest?.summary, "Update available: p1.0.5.0", "upgrade available")
        try equal(DeviceHealth.parseFirmware(["data": [["thing_id": "thing-a", "fw_status": "LATEST"]]], thingID: "thing-a")?.summary, "Up to date", "latest")
        try truth(DeviceHealth.parseFirmware(["data": []], thingID: "thing-a") == nil, "no rows")
        try rejects("firmware statusCode 1") { _ = try APIStatus.statusCode(["statusCode": 1, "message": "x"], endpoint: "firmware") }

        let body = DeviceHealth.diagnosticsBody(thingID: "thing-a", cognitoID: "us-east-1:id", sub: "sub", accessToken: "token", localReachable: false)
        try equal(body["share_diagnostic_data"] as? String, "No", "diagnostic data is never shared")
        try equal(body["cognito_id"] as? String, "us-east-1:id", "cognito_id is the Identity Pool id")
        let report = DeviceHealth.parseDiagnostics(["statusCode": 200, "data": [
            "device_access_mode": "CLOUD", "firmware_version": "p1.0.4.2", "status_texts": ["AC is online"],
            "diagnosis_results": [["label": "App Connectivity Check", "status": "passed"]], "device_error_data": ["error_code": ""],
            "email": "hidden", "mobile": "hidden", "thing_latitude": 1.0]])
        try equal(report, DiagnosticReport(accessMode: "CLOUD", firmwareVersion: "p1.0.4.2", statusTexts: ["AC is online"],
                                           results: [.init(label: "App Connectivity Check", status: "passed")], deviceErrorCode: nil), "diagnostics report")
    }
}
