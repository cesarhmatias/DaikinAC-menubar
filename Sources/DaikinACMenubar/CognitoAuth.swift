import Foundation
import CryptoKit
import Security
import BigInt

// Public identifiers of the official app's Amplify configuration. The Amplify
// app client has no secret, so no request carries a SECRET_HASH.
enum CognitoConfig {
    static let region = "us-east-1"
    static let userPoolID = "us-east-1_s6T1EfUgP"
    static let clientID = "2tl54vtfepvo3nu23um3c6rjs9"
    static let identityPoolID = "us-east-1:656722e8-449d-43c5-958b-987700bc70e8"
    static let identityProvider = "cognito-idp.us-east-1.amazonaws.com/us-east-1_s6T1EfUgP"
    static let userPoolEndpoint = URL(string: "https://cognito-idp.us-east-1.amazonaws.com/")!
    static let identityEndpoint = URL(string: "https://cognito-identity.us-east-1.amazonaws.com/")!
    // The SRP salt prefix is the part of the pool ID after the region.
    static var poolName: String { String(userPoolID.split(separator: "_").last ?? "") }
}

enum CognitoRequest {
    // The client rejects USER_PASSWORD_AUTH ("flow not enabled for this client",
    // research/LIVE_OBSERVATIONS.md), so sign-in uses SRP like the official app.
    static func initiateSRP(username: String, srpA: String) throws -> URLRequest {
        try userPool("InitiateAuth", [
            "AuthFlow": "USER_SRP_AUTH",
            "ClientId": CognitoConfig.clientID,
            "AuthParameters": ["USERNAME": username, "SRP_A": srpA],
        ])
    }

    static func respondToPasswordVerifier(_ responses: [String: String], session: String?) throws -> URLRequest {
        var body: [String: Any] = ["ChallengeName": "PASSWORD_VERIFIER", "ClientId": CognitoConfig.clientID, "ChallengeResponses": responses]
        if let session { body["Session"] = session }
        return try userPool("RespondToAuthChallenge", body)
    }

    static func refresh(refreshToken: String) throws -> URLRequest {
        try userPool("InitiateAuth", [
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "ClientId": CognitoConfig.clientID,
            "AuthParameters": ["REFRESH_TOKEN": refreshToken],
        ])
    }

    static func userPool(_ action: String, _ body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: CognitoConfig.userPoolEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.\(action)", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 20
        return request
    }
}

// Cognito's SRP-6a variant (3072-bit group, SHA-256), matching
// amazon-cognito-identity-js and pycognito. Checked against pycognito vectors in FeatureChecks.
struct CognitoSRP {
    static let nHex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD"
        + "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
        + "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
        + "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
        + "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510"
        + "15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
        + "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C"
        + "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF"
    static let N = BigUInt(nHex, radix: 16)!
    static let g = BigUInt(2)
    static let k = BigUInt(Hex.sha256(hex: Hex.pad(nHex) + Hex.pad("2")), radix: 16)!

    let a: BigUInt
    let A: BigUInt

    init(a: BigUInt) throws {
        self.a = a
        A = CognitoSRP.g.power(a, modulus: CognitoSRP.N)
        guard !A.isZero else { throw DaikinError.message("SRP safety check failed for A.") }
    }

    static func random() throws -> CognitoSRP {
        var bytes = [UInt8](repeating: 0, count: 128)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DaikinError.message("Could not generate random bytes for sign-in.")
        }
        return try CognitoSRP(a: BigUInt(Data(bytes)) % N)
    }

    var srpA: String { Hex.string(A) }

    func passwordAuthenticationKey(userID: String, password: String, serverB: BigUInt, saltHex: String) throws -> Data {
        let N = CognitoSRP.N
        guard !(serverB % N).isZero else { throw DaikinError.message("SRP safety check failed for B.") }
        let u = BigUInt(Hex.sha256(hex: Hex.pad(Hex.string(A)) + Hex.pad(Hex.string(serverB))), radix: 16)!
        guard !u.isZero else { throw DaikinError.message("SRP safety check failed for u.") }
        let identity = Hex.string(Data(SHA256.hash(data: Data((CognitoConfig.poolName + userID + ":" + password).utf8))))
        let x = BigUInt(Hex.sha256(hex: Hex.pad(saltHex) + identity), radix: 16)!
        let kgx = (CognitoSRP.k * CognitoSRP.g.power(x, modulus: N)) % N
        let base = (serverB % N + N - kgx) % N
        let S = base.power(a + u * x, modulus: N)
        let prk = HMAC<SHA256>.authenticationCode(for: Hex.data(Hex.pad(Hex.string(S))), using: SymmetricKey(data: Hex.data(Hex.pad(Hex.string(u)))))
        let info = Data("Caldera Derived Key".utf8) + Data([1])
        return Data(HMAC<SHA256>.authenticationCode(for: info, using: SymmetricKey(data: Data(prk))).prefix(16))
    }

    // Answers PASSWORD_VERIFIER. No SECRET_HASH: the Amplify client has no secret.
    func challengeResponses(_ parameters: [String: String], password: String, date: Date) throws -> [String: String] {
        guard let userID = parameters["USER_ID_FOR_SRP"], let salt = parameters["SALT"], let bHex = parameters["SRP_B"],
              let block = parameters["SECRET_BLOCK"], let serverB = BigUInt(bHex, radix: 16),
              let blockBytes = Data(base64Encoded: block) else {
            throw DaikinError.message("Cognito sent an incomplete PASSWORD_VERIFIER challenge.")
        }
        let key = try passwordAuthenticationKey(userID: userID, password: password, serverB: serverB, saltHex: salt)
        let timestamp = CognitoSRP.timestamp(date)
        let message = Data(CognitoConfig.poolName.utf8) + Data(userID.utf8) + blockBytes + Data(timestamp.utf8)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))).base64EncodedString()
        return ["USERNAME": parameters["USERNAME"] ?? userID, "TIMESTAMP": timestamp,
                "PASSWORD_CLAIM_SECRET_BLOCK": block, "PASSWORD_CLAIM_SIGNATURE": signature]
    }

    // "Fri Oct 9 05:07:03 UTC 2026": English names, day of month without a leading zero.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss 'UTC' yyyy"
        return formatter.string(from: date)
    }
}

// Hex helpers with the padding rule of the Cognito SRP libraries: an odd length gets
// a leading 0, and a value whose first digit is 8–f gets 00 so it hashes as positive.
enum Hex {
    static func string(_ value: BigUInt) -> String { String(value, radix: 16) }
    static func string(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func pad(_ hex: String) -> String {
        if hex.count % 2 == 1 { return "0" + hex }
        if let first = hex.first, "89abcdefABCDEF".contains(first) { return "00" + hex }
        return hex
    }
    static func data(_ hex: String) -> Data {
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }
    static func sha256(hex: String) -> String { string(Data(SHA256.hash(data: data(hex)))) }
}

struct CognitoTokens: Equatable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    // `user_name` everywhere in the REST API is the Cognito `sub`, not the e-mail.
    var sub: String? { JWT.claims(idToken)?["sub"] as? String }
    var email: String? { JWT.claims(idToken)?["email"] as? String }
    func needsRefresh(now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < 5 * 60 }
}

// Cognito reports failures as `{"__type": "NotAuthorizedException", "message": "…"}`.
struct CognitoFailure: LocalizedError, Equatable {
    var type: String
    var message: String
    var httpStatus: Int
    var errorDescription: String? { "Cognito \(type): \(message)" }
}

struct CognitoChallenge {
    var name: String
    var parameters: [String: String]
    var session: String?
}

enum CognitoAuth {
    // One SRP exchange per call (InitiateAuth + RespondToAuthChallenge). Callers never
    // retry on their own: Cognito rate-limits and can lock the account.
    static func signIn(username: String, password: String) async throws -> CognitoTokens {
        let srp = try CognitoSRP.random()
        let initiate = try await send(try CognitoRequest.initiateSRP(username: username, srpA: srp.srpA), shape: "cognito-initiate-auth")
        guard let challenge = try challenge(initiate.data, status: initiate.status) else {
            return try parse(initiate.data, status: initiate.status, previousRefreshToken: nil)
        }
        guard challenge.name == "PASSWORD_VERIFIER" else {
            throw DaikinError.message("Cognito asked for the \(challenge.name) challenge, which this app does not support yet.")
        }
        let responses = try srp.challengeResponses(challenge.parameters, password: password, date: Date())
        let answer = try await send(try CognitoRequest.respondToPasswordVerifier(responses, session: challenge.session), shape: "cognito-respond-to-auth-challenge")
        return try parse(answer.data, status: answer.status, previousRefreshToken: nil)
    }

    static func refresh(_ tokens: CognitoTokens) async throws -> CognitoTokens {
        let result = try await send(try CognitoRequest.refresh(refreshToken: tokens.refreshToken), shape: "cognito-refresh")
        return try parse(result.data, status: result.status, previousRefreshToken: tokens.refreshToken)
    }

    private static func send(_ request: URLRequest, shape: String) async throws -> (data: Data, status: Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        ResponseShapes.record(shape, data: data, status: status)
        return (data, status)
    }

    static func failure(_ json: [String: Any], status: Int) -> CognitoFailure? {
        guard !(200..<300).contains(status) || json["__type"] != nil else { return nil }
        let type = (json["__type"] as? String).map { String($0.split(separator: "#").last ?? Substring($0)) } ?? "HTTP \(status)"
        return CognitoFailure(type: type, message: json["message"] as? String ?? json["Message"] as? String ?? "No message", httpStatus: status)
    }

    // Returns the challenge, or nil when the response already carries tokens.
    static func challenge(_ data: Data, status: Int) throws -> CognitoChallenge? {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let failure = failure(json, status: status) { throw failure }
        guard let name = json["ChallengeName"] as? String else { return nil }
        let parameters = (json["ChallengeParameters"] as? [String: Any] ?? [:]).compactMapValues { Lenient.string($0) }
        return CognitoChallenge(name: name, parameters: parameters, session: json["Session"] as? String)
    }

    // A refresh response carries no new refresh token, so the previous one is kept.
    static func parse(_ data: Data, status: Int, previousRefreshToken: String?, now: Date = Date()) throws -> CognitoTokens {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let failure = failure(json, status: status) { throw failure }
        if let challenge = json["ChallengeName"] as? String {
            throw DaikinError.message("Cognito asked for the \(challenge) challenge, which this app does not support yet.")
        }
        guard let result = json["AuthenticationResult"] as? [String: Any],
              let idToken = result["IdToken"] as? String, let accessToken = result["AccessToken"] as? String,
              let refreshToken = result["RefreshToken"] as? String ?? previousRefreshToken else {
            throw DaikinError.message("Cognito answered without tokens.")
        }
        let expiresIn = (result["ExpiresIn"] as? NSNumber)?.doubleValue ?? 3600
        return CognitoTokens(idToken: idToken, accessToken: accessToken, refreshToken: refreshToken, expiresAt: now.addingTimeInterval(expiresIn))
    }
}

// Reads JWT claims without verifying the signature; only used for `sub`, `email` and `exp`.
enum JWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
