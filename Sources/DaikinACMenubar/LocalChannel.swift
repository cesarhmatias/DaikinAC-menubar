import Foundation
import CommonCrypto
import Network

// Local LAN channel: HTTP on port 15914 with an AES-CFB128 frame, as in daikin-br's
// pyiotdevice. No cloud and no Cognito; the key is the device's thing_secret_key,
// kept in memory only. See research/CROSS_CHECK.md.
enum LocalChannel {
    static let port: UInt16 = 15914
    static let serviceType = "_iota._tcp"
    static let commandSuffix = "BZ"

    // The app appends "\n" before decoding; unknown characters are ignored, so both forms work.
    static func key(fromDeviceKey text: String) -> Data? {
        guard let key = Data(base64Encoded: text + "\n", options: .ignoreUnknownCharacters), [16, 24, 32].contains(key.count) else { return nil }
        return key
    }

    static func cfb(_ operation: CCOperation, key: Data, iv: Data, _ input: Data) throws -> Data {
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(operation, CCMode(kCCModeCFB), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                        ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0, 0, &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { throw DaikinError.message("AES setup failed (\(created)).") }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: input.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in CCCryptorUpdate(cryptor, inp.baseAddress, input.count, out.baseAddress, input.count, &moved) }
        }
        guard status == kCCSuccess, moved == input.count else { throw DaikinError.message("AES failed (\(status)).") }
        return output
    }

    // `[IV16][ciphertext of JSON + "BZ"][CRC16 little-endian]`, base64-encoded.
    static func requestBody(json: Data, key: Data, iv: Data) throws -> String {
        var frame = iv + (try cfb(CCOperation(kCCEncrypt), key: key, iv: iv, json + Data(commandSuffix.utf8)))
        let crc = CRC16.genibus(frame)
        frame.append(UInt8(crc & 0xFF)); frame.append(UInt8(crc >> 8))
        return frame.base64EncodedString()
    }

    static func randomIV() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &bytes) == errSecSuccess else { throw DaikinError.message("Could not generate an IV.") }
        return Data(bytes)
    }

    // Replies are `[IV16][length byte][ciphertext][CRC16 LE]` (pyiotdevice reads data[17:-2]);
    // the protocol doc also describes a form without the length byte, tried second.
    static func decodeReply(_ body: String, key: Data) throws -> [String: Any] {
        guard let data = Data(base64Encoded: body.trimmingCharacters(in: .whitespacesAndNewlines)), data.count > 19 else {
            throw DaikinError.message("The AC sent an unreadable reply.")
        }
        let bytes = [UInt8](data)
        let expected = UInt16(bytes[bytes.count - 2]) | UInt16(bytes[bytes.count - 1]) << 8
        guard CRC16.genibus(bytes.dropLast(2)) == expected else { throw DaikinError.message("The AC reply failed its checksum.") }
        let iv = Data(bytes[0..<16])
        for start in [17, 16] {
            let plain = try cfb(CCOperation(kCCDecrypt), key: key, iv: iv, Data(bytes[start..<(bytes.count - 2)]))
            if let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] { return json }
        }
        throw DaikinError.message("The AC reply did not decrypt; the device key may be wrong.")
    }

    static func status(at endpoint: NWEndpoint, key: Data) async throws -> Port1 {
        let request = Data("GET /acstatus HTTP/1.1\r\nhost: \(LocalHTTP.hostHeader(endpoint))\r\n\r\n".utf8)
        let reply = try await LocalQueue.run { try await LocalHTTP.send(request, to: endpoint) }
        return try port1(from: reply, key: key, shape: "local-acstatus")
    }

    // POST /acstatus answers with the unit's new state.
    static func command(_ change: Port1, at endpoint: NWEndpoint, key: Data) async throws -> Port1 {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try requestBody(json: try encoder.encode(PortEnvelope(port1: change)), key: key, iv: try randomIV())
        let request = Data("POST /acstatus HTTP/1.1\r\nHost: \(LocalHTTP.hostHeader(endpoint))\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        var reply = try await LocalQueue.run { try await LocalHTTP.send(request, to: endpoint) }
        // The unit has answered 404 to a valid command once while busy; one retry after a pause.
        if reply.status == 404 {
            recordRefusal(reply)
            try await Task.sleep(for: .milliseconds(500))
            reply = try await LocalQueue.run { try await LocalHTTP.send(request, to: endpoint) }
        }
        return try port1(from: reply, key: key, shape: "local-acstatus-command")
    }

    private static func recordRefusal(_ reply: LocalHTTP.Reply) {
        let summary: [String: Any] = ["http": reply.status, "body_length": reply.body.count, "body_start": String(reply.body.prefix(40))]
        if let data = try? JSONSerialization.data(withJSONObject: summary) { ResponseShapes.record("local-refusal", data: data, status: reply.status) }
    }

    private static func port1(from reply: LocalHTTP.Reply, key: Data, shape: String) throws -> Port1 {
        guard reply.status == 200 else { recordRefusal(reply); throw DaikinError.message("The AC answered HTTP \(reply.status).") }
        let json = try decodeReply(reply.body, key: key)
        if let data = try? JSONSerialization.data(withJSONObject: json) { ResponseShapes.record(shape, data: data, status: reply.status) }
        guard let object = json["port1"], let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw DaikinError.message("The AC reply has no port1 state.")
        }
        return try JSONDecoder().decode(Port1.self, from: data)
    }
}

// CRC-16/GENIBUS: polynomial 0x1021, MSB first, init 0xFFFF, final xor 0xFFFF.
// The table is generated from the polynomial rather than copied.
enum CRC16 {
    static let table: [UInt16] = (0..<256).map { index in
        var value = UInt16(index) << 8
        for _ in 0..<8 { value = value & 0x8000 != 0 ? (value << 1) ^ 0x1021 : value << 1 }
        return value
    }

    static func genibus<Bytes: Sequence>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes { crc = (crc << 8) ^ table[Int(UInt8(crc >> 8) ^ byte)] }
        return ~crc
    }
}

// The unit's small HTTP server handles one connection at a time, so local requests
// (status polls and commands) run strictly one after another.
@MainActor enum LocalQueue {
    private static var tail: Task<Void, Never>?
    static func run<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            _ = await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

// One raw HTTP/1.1 exchange over TCP, like pyiotdevice: the unit closes the connection
// after replying. 10 s timeout, no retries.
enum LocalHTTP {
    struct Reply { var status: Int; var body: String }

    static func hostHeader(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "daikin.local"
    }

    static func parse(_ data: Data) -> Reply? {
        guard let text = String(data: data, encoding: .utf8), let split = text.range(of: "\r\n\r\n") else { return nil }
        let head = text[..<split.lowerBound]
        let status = head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        return Reply(status: status, body: String(text[split.upperBound...]))
    }

    // True once the headers and the Content-Length body (if declared) have arrived.
    static func hasFullBody(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), let split = text.range(of: "\r\n\r\n") else { return false }
        let head = text[..<split.lowerBound].lowercased()
        guard let line = head.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") }),
              let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) else { return false }
        return text[split.upperBound...].utf8.count >= length
    }

    static func send(_ request: Data, to endpoint: NWEndpoint, timeout: TimeInterval = 10) async throws -> Reply {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "br.local.DaikinAC.local-http")
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var buffer = Data()
            func finish(_ result: Result<Reply, Error>) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(with: result)
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data { buffer += data }
                    if isComplete || error != nil || hasFullBody(buffer) {
                        if let reply = parse(buffer) { finish(.success(reply)) }
                        else { finish(.failure(error ?? DaikinError.message("The AC closed the connection without a reply."))) }
                        return
                    }
                    // Without Content-Length, accept the reply once data stops arriving for a moment
                    // (pyiotdevice reads a single chunk and does not wait for the close).
                    let seen = buffer.count
                    queue.asyncAfter(deadline: .now() + 0.4) {
                        if buffer.count == seen, let reply = parse(buffer), !reply.body.isEmpty { finish(.success(reply)) }
                    }
                    receive()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) } else { receive() }
                    })
                case .failed(let error): finish(.failure(error))
                case .waiting(let error): finish(.failure(error))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(DaikinError.message("The AC did not answer on the local network within \(Int(timeout)) s."))) }
            connection.start(queue: queue)
        }
    }
}

// Finds units advertising `_iota._tcp` on the local network for a few seconds.
enum LocalDiscovery {
    struct Unit { var name: String; var apn: String?; var endpoint: NWEndpoint }
    // Written only on the main queue, where the browser delivers its results.
    private final class Found: @unchecked Sendable { var units: [Unit] = [] }

    @MainActor static func browse(for seconds: Double = 4) async -> [Unit] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LocalChannel.serviceType, domain: nil), using: .tcp)
        let found = Found()
        browser.browseResultsChangedHandler = { results, _ in
            found.units = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var apn: String?
                if case .bonjour(let record) = result.metadata { apn = record["apn"] }
                return Unit(name: name, apn: apn, endpoint: result.endpoint)
            }
        }
        browser.start(queue: .main)
        try? await Task.sleep(for: .seconds(seconds))
        browser.cancel()
        let units = found.units
        // Record the advertised format (masked) so the matching rule can be checked.
        let summary = units.map { ["name": $0.name, "apn": $0.apn ?? NSNull()] as [String: Any] }
        if let data = try? JSONSerialization.data(withJSONObject: ["units": summary]) { ResponseShapes.record("local-discovery", data: data, status: 0) }
        return units
    }

    // The service is advertised on port 80, but the encrypted API listens on 15914
    // (pyiotdevice uses the discovered address with its fixed port). Resolve the service to
    // its address, then talk to port 15914. Nothing is stored. UDP is used only to resolve:
    // it has no handshake, so the connection is ready once the name resolves and nothing is
    // sent (the unit refuses TCP on the advertised port 80).
    static func localAPIEndpoint(for service: NWEndpoint, timeout: TimeInterval = 5) async -> NWEndpoint? {
        let connection = NWConnection(to: service, using: .udp)
        let queue = DispatchQueue(label: "br.local.DaikinAC.resolve")
        let host: NWEndpoint.Host? = await withCheckedContinuation { continuation in
            var done = false
            func finish(_ host: NWEndpoint.Host?) {
                guard !done else { return }
                done = true
                connection.cancel()
                continuation.resume(returning: host)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint { finish(host) } else { finish(nil) }
                case .failed, .waiting: finish(nil)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
            connection.start(queue: queue)
        }
        guard let host, let port = NWEndpoint.Port(rawValue: LocalChannel.port) else { return nil }
        return .hostPort(host: host, port: port)
    }

    // pyiotdevice's get_hostname: "DAIKIN:1234A5…" → "DAIKIN" + the first three hex pairs reversed
    // ("A53412"). That is the form of thing_apn in GET_THING_INFO (research/LIVE_OBSERVATIONS.md).
    static func hostname(fromAPN apn: String) -> String? {
        let parts = apn.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[1].count >= 6 else { return nil }
        let hex = Array(parts[1].prefix(6))
        return String(parts[0]) + String(hex[4...5]) + String(hex[2...3]) + String(hex[0...1])
    }

    // Units most likely to be this device first; the key check in the caller decides.
    static func candidates(_ units: [Unit], apn: String?) -> [Unit] {
        func normalized(_ text: String?) -> String { (text ?? "").uppercased().filter { $0.isLetter || $0.isNumber } }
        let target = normalized(apn)
        let matching = units.filter { unit in
            !target.isEmpty && [unit.apn, unit.apn.flatMap(hostname(fromAPN:)), unit.name].contains { normalized($0) == target }
        }
        return matching + units.filter { unit in !matching.contains { $0.name == unit.name } }
    }
}
