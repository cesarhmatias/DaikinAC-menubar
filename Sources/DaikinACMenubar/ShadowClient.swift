import Foundation
import CryptoKit

// Temporary AWS credentials from the Cognito Identity Pool, used to sign shadow requests.
struct AWSCredentials: Equatable {
    var accessKeyID: String
    var secretKey: String
    var sessionToken: String
    var expiration: Date
    func needsRefresh(now: Date = Date()) -> Bool { expiration.timeIntervalSince(now) < 5 * 60 }
}

enum IdentityPool {
    // GetId + GetCredentialsForIdentity with the ID token as the login. The official app
    // does the same; it never calls the policy-attach endpoint after sign-in (that is part
    // of onboarding a new unit), so this app does not call it either.
    static func credentials(idToken: String) async throws -> AWSCredentials {
        let logins = [CognitoConfig.identityProvider: idToken]
        let id = try await call("GetId", ["IdentityPoolId": CognitoConfig.identityPoolID, "Logins": logins], shape: "cognito-identity-get-id")
        guard let identityID = id["IdentityId"] as? String else { throw DaikinError.message("The Identity Pool returned no IdentityId.") }
        let result = try await call("GetCredentialsForIdentity", ["IdentityId": identityID, "Logins": logins], shape: "cognito-identity-get-credentials")
        return try parseCredentials(result)
    }

    static func parseCredentials(_ json: [String: Any]) throws -> AWSCredentials {
        guard let credentials = json["Credentials"] as? [String: Any],
              let accessKey = credentials["AccessKeyId"] as? String, let secret = credentials["SecretKey"] as? String,
              let token = credentials["SessionToken"] as? String else {
            throw DaikinError.message("The Identity Pool returned no credentials.")
        }
        let expiration = (credentials["Expiration"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date().addingTimeInterval(3600)
        return AWSCredentials(accessKeyID: accessKey, secretKey: secret, sessionToken: token, expiration: expiration)
    }

    static func request(_ action: String, _ body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: CognitoConfig.identityEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityService.\(action)", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 20
        return request
    }

    private static func call(_ action: String, _ body: [String: Any], shape: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: try request(action, body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        ResponseShapes.record(shape, data: data, status: status)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let failure = CognitoAuth.failure(json, status: status) { throw failure }
        return json
    }
}

// AWS Signature Version 4 query presigning. Checked against botocore in FeatureChecks.
enum SigV4 {
    // AWS IoT WebSocket URL: the session token is appended after signing, as AWS IoT requires.
    static func presignedIoTURL(host: String, credentials: AWSCredentials, region: String, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        let day = String(amzDate.prefix(8))
        let service = "iotdevicegateway"
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let parameters = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"), ("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"),
            ("X-Amz-Date", amzDate), ("X-Amz-Expires", "86400"), ("X-Amz-SignedHeaders", "host"),
        ]
        let query = parameters.map { "\(uriEncode($0.0))=\(uriEncode($0.1))" }.sorted().joined(separator: "&")
        let canonical = ["GET", "/mqtt", query, "host:\(host)\n", "host", hex(SHA256.hash(data: Data()))].joined(separator: "\n")
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(credentials.secretKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))
        return URL(string: "wss://\(host)/mqtt?\(query)&X-Amz-Signature=\(signature)&X-Amz-Security-Token=\(uriEncode(credentials.sessionToken))")!
    }

    static func uriEncode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
}

struct ShadowDocument: Equatable {
    var reported: Port1?
    var desired: Port1?
    // Beside port1 in `state.reported`: "COOL_ONLY" or "HEAT_PUMP" (masked shape AAAA_AAAA).
    var unitType: String?
    var version: Int?
    var timestamp: Date?
}

// Topics and payloads of the AWS IoT classic shadow, as used by the official app over MQTT.
enum ShadowClient {
    static let host = "a2zl28lcjjddi3-ats.iot.us-east-1.amazonaws.com"

    static func topic(_ thingID: String, _ suffix: String) -> String { "$aws/things/\(thingID)/shadow/\(suffix)" }

    // `{"state":{"desired":{"port1":{…only changed keys…},"src":5}}}`; src 5 marks the mobile app.
    static func commandBody(_ change: Port1) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let port1 = try JSONSerialization.jsonObject(with: encoder.encode(change))
        return try JSONSerialization.data(withJSONObject: ["state": ["desired": ["port1": port1, "src": 5]]], options: [.sortedKeys])
    }

    static func parse(_ json: [String: Any]) -> ShadowDocument {
        let state = json["state"] as? [String: Any] ?? [:]
        func port1(_ section: String) -> Port1? {
            guard let object = (state[section] as? [String: Any])?["port1"],
                  let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(Port1.self, from: data)
        }
        let reported = state["reported"] as? [String: Any]
        return ShadowDocument(reported: port1("reported"), desired: port1("desired"), unitType: Lenient.string(reported?["ac_unit_type"]),
                              version: Lenient.int(json["version"]),
                              timestamp: (json["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
    }
}

// The few MQTT 3.1.1 packets the shadow needs.
enum MQTT {
    enum PacketType: UInt8 { case connect = 1, connack, publish, puback, pubrec, pubrel, pubcomp, subscribe, suback, unsubscribe, unsuback, pingreq, pingresp, disconnect }

    struct Packet: Equatable {
        var type: PacketType
        var flags: UInt8
        var body: Data
    }

    static func connect(clientID: String, keepAlive: UInt16, cleanSession: Bool = true) -> Data {
        var body = string("MQTT") + Data([4, cleanSession ? 0x02 : 0x00, UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)])
        body += string(clientID)
        return frame(.connect, 0, body)
    }
    static func subscribe(packetID: UInt16, topics: [String]) -> Data {
        var body = uint16(packetID)
        for topic in topics { body += string(topic) + Data([0]) }   // QoS 0
        return frame(.subscribe, 0x02, body)
    }
    static func publish(topic: String, payload: Data) -> Data { frame(.publish, 0, string(topic) + payload) }   // QoS 0
    static let pingreq = frame(.pingreq, 0, Data())
    static let disconnect = frame(.disconnect, 0, Data())

    static func frame(_ type: PacketType, _ flags: UInt8, _ body: Data) -> Data {
        var data = Data([type.rawValue << 4 | flags])
        var length = body.count
        repeat {
            var byte = UInt8(length % 128); length /= 128
            if length > 0 { byte |= 0x80 }
            data.append(byte)
        } while length > 0
        return data + body
    }

    // Takes one complete packet off the front of the buffer, or returns nil if more bytes are needed.
    static func next(_ buffer: inout Data) throws -> Packet? {
        guard let first = buffer.first else { return nil }
        var length = 0, multiplier = 1, index = buffer.startIndex + 1
        while true {
            guard index < buffer.endIndex else { return nil }
            let byte = buffer[index]; index += 1
            length += Int(byte & 0x7F) * multiplier
            if byte & 0x80 == 0 { break }
            multiplier *= 128
            guard multiplier <= 128 * 128 * 128 else { throw DaikinError.message("Malformed MQTT length.") }
        }
        guard buffer.endIndex - index >= length else { return nil }
        guard let type = PacketType(rawValue: first >> 4) else { throw DaikinError.message("Unknown MQTT packet type \(first >> 4).") }
        let body = Data(buffer[index..<index + length])
        buffer = Data(buffer[(index + length)...])
        return Packet(type: type, flags: first & 0x0F, body: body)
    }

    // PUBLISH → (topic, payload). Incoming QoS 1 messages carry a packet id after the topic.
    static func publishContents(_ packet: Packet) -> (topic: String, payload: Data)? {
        guard packet.type == .publish, packet.body.count >= 2 else { return nil }
        let bytes = [UInt8](packet.body)
        let topicLength = Int(bytes[0]) << 8 | Int(bytes[1])
        guard bytes.count >= 2 + topicLength, let topic = String(bytes: bytes[2..<2 + topicLength], encoding: .utf8) else { return nil }
        let qos = (packet.flags >> 1) & 0x03
        let start = 2 + topicLength + (qos > 0 ? 2 : 0)
        guard bytes.count >= start else { return nil }
        return (topic, Data(bytes[start...]))
    }

    private static func string(_ text: String) -> Data { uint16(UInt16(text.utf8.count)) + Data(text.utf8) }
    private static func uint16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
}

// One MQTT-over-WebSocket session to AWS IoT for a single thing's shadow.
@MainActor final class ShadowConnection {
    static let keepAlive: UInt16 = 60
    let thingID: String
    var onDocument: (ShadowDocument) -> Void = { _ in }
    var onClose: (Error?) -> Void = { _ in }

    private var socket: URLSessionWebSocketTask?
    private var buffer = Data()
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    // CONNACK or SUBACK can arrive before the code awaiting it runs, so arrivals are remembered.
    private enum Step: Hashable { case connack, suback }
    private var arrived: Set<Step> = []
    private var waiters: [Step: CheckedContinuation<Void, Error>] = [:]
    private var closed = false

    init(thingID: String) { self.thingID = thingID }

    // Connects once, subscribes to the shadow replies and asks for the current document.
    // CONNECT and SUBSCRIBE each time out after 10 s; there is no automatic retry.
    func open(clientID: String, credentials: AWSCredentials) async throws {
        let url = SigV4.presignedIoTURL(host: ShadowClient.host, credentials: credentials, region: CognitoConfig.region)
        let socket = URLSession.shared.webSocketTask(with: url, protocols: ["mqtt"])
        self.socket = socket
        socket.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        try await send(MQTT.connect(clientID: clientID, keepAlive: ShadowConnection.keepAlive))
        try await wait(.connack, "CONNECT")
        try await send(MQTT.subscribe(packetID: 1, topics: ["get/accepted", "get/rejected", "update/accepted", "update/rejected"].map { ShadowClient.topic(thingID, $0) }))
        try await wait(.suback, "SUBSCRIBE")
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Int(ShadowConnection.keepAlive) * 3 / 4))
                try? await self?.send(MQTT.pingreq)
            }
        }
        try await requestDocument()
    }

    // Publishes `{"state":{"desired":{"port1":{…},"src":5}}}` to the shadow update topic.
    func publishDesired(_ change: Port1) async throws {
        try await send(MQTT.publish(topic: ShadowClient.topic(thingID, "update"), payload: try ShadowClient.commandBody(change)))
    }

    func requestDocument() async throws {
        try await send(MQTT.publish(topic: ShadowClient.topic(thingID, "get"), payload: Data("{}".utf8)))
    }

    func close(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        pingTask?.cancel(); receiveTask?.cancel()
        if error == nil, let socket { socket.send(.data(MQTT.disconnect)) { _ in } }
        socket?.cancel(with: .normalClosure, reason: nil)
        let failure = error ?? DaikinError.message("Connection closed.")
        for waiter in waiters.values { waiter.resume(throwing: failure) }
        waiters = [:]
        onClose(error)
    }

    private func send(_ data: Data) async throws {
        guard let socket, !closed else { throw DaikinError.message("The shadow connection is closed.") }
        try await socket.send(.data(data))
    }

    private func wait(_ step: Step, _ name: String) async throws {
        if closed { throw DaikinError.message("The shadow connection is closed.") }
        if arrived.remove(step) != nil { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { self?.close(DaikinError.message("AWS IoT did not answer \(name) within 10 s (often a policy refusal).")) }
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { waiters[step] = $0 }
    }

    private func arrive(_ step: Step) {
        if let waiter = waiters.removeValue(forKey: step) { waiter.resume() } else { arrived.insert(step) }
    }

    private func receiveLoop() async {
        while let socket, !closed {
            do {
                switch try await socket.receive() {
                case .data(let data): buffer += data
                case .string(let text): buffer += Data(text.utf8)
                @unknown default: break
                }
                while let packet = try MQTT.next(&buffer) { handle(packet) }
            } catch {
                if !closed { close(DaikinError.message("AWS IoT closed the connection: \(error.localizedDescription)")) }
                return
            }
        }
    }

    private func handle(_ packet: MQTT.Packet) {
        switch packet.type {
        case .connack:
            let code = packet.body.count >= 2 ? packet.body[packet.body.startIndex + 1] : 255
            if code == 0 { arrive(.connack) }
            else { close(DaikinError.message("AWS IoT refused the MQTT connection (CONNACK \(code)).")) }
        case .suback:
            let codes = packet.body.dropFirst(2)
            if codes.contains(0x80) { close(DaikinError.message("AWS IoT refused the shadow subscription (SUBACK 0x80).")) }
            else { arrive(.suback) }
        case .publish:
            guard let (topic, payload) = MQTT.publishContents(packet) else { return }
            if topic.hasSuffix("/get/accepted") {
                ResponseShapes.record("iot-shadow-get-accepted", data: payload, status: 200)
                if let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] { onDocument(ShadowClient.parse(json)) }
            } else if topic.hasSuffix("/update/accepted") {
                ResponseShapes.record("iot-shadow-update-accepted", data: payload, status: 200)
                Task { try? await requestDocument() }   // update/accepted is partial; read the full document again
            } else if topic.hasSuffix("/rejected") {
                ResponseShapes.record("iot-shadow-rejected", data: payload, status: 0)
                let message = ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])?["message"] as? String
                close(DaikinError.message("The shadow rejected the request: \(message ?? "no message")"))
            }
        default:
            break
        }
    }
}
