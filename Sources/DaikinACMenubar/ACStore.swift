import SwiftUI

// What survives a restart: the e-mail shown in Settings and the refresh token.
// The password is never stored.
struct StoredSession: Codable {
    var email: String
    var refreshToken: String
}

@MainActor final class ACStore: ObservableObject {
    // The panel shell resizes itself whenever this changes.
    @Published var preferredPanelHeight: CGFloat = 600
    @Published private(set) var tokens: CognitoTokens?
    @Published private(set) var accountEmail: String?
    @Published private(set) var signingIn = false
    @Published private(set) var loadingDevices = false
    @Published private(set) var thingInfo: ThingInfo?
    @Published private(set) var selectedThingID = Keychain.readString(.selectedThing)
    @Published var state: Port1?
    @Published var status = "Not signed in"
    @Published var error: String?

    var signedIn: Bool { tokens != nil }
    var things: [Thing] { thingInfo?.things ?? [] }
    var selectedThing: Thing? { things.first { $0.id == selectedThingID } ?? things.first }
    var deviceName: String { selectedThing?.name ?? "Daikin AC" }
    var accent: Color { state?.isOn == true ? Theme.accent(for: state?.acMode) : Theme.neutralAccent }

    // Restores the saved session with a single refresh. A rejected refresh token
    // signs out; a network failure keeps the session for the next launch.
    func start() async {
        guard tokens == nil, let data = Keychain.read(.session),
              let saved = try? JSONDecoder().decode(StoredSession.self, from: data) else { return }
        accountEmail = saved.email
        status = "Restoring session…"
        do {
            let placeholder = CognitoTokens(idToken: "", accessToken: "", refreshToken: saved.refreshToken, expiresAt: .distantPast)
            tokens = try await CognitoAuth.refresh(placeholder)
            status = "Signed in"
            await refreshDevices()
        } catch let failure as CognitoFailure where failure.type == "NotAuthorizedException" {
            forgetSession()
            error = "Your session expired. Sign in again. (\(failure.localizedDescription))"
        } catch {
            status = "Not signed in"
            self.error = "Could not restore the session: \(error.localizedDescription)"
        }
    }

    // Exactly one InitiateAuth request per call; the button is disabled while it runs.
    func signIn(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signingIn, !email.isEmpty, !password.isEmpty else { return }
        signingIn = true; error = nil; status = "Signing in…"
        defer { signingIn = false }
        do {
            let result = try await CognitoAuth.signIn(username: email, password: password)
            tokens = result
            accountEmail = result.email ?? email
            try Keychain.save(JSONEncoder().encode(StoredSession(email: accountEmail ?? email, refreshToken: result.refreshToken)), as: .session)
            status = "Signed in"
            await refreshDevices()
        } catch {
            tokens = nil
            status = "Sign-in failed"
            self.error = error.localizedDescription
        }
    }

    func signOut() {
        forgetSession()
        select(nil)
        status = "Not signed in"
    }

    func refreshDevices() async {
        guard !loadingDevices else { return }
        loadingDevices = true
        defer { loadingDevices = false }
        do {
            let info = try await DaikinAPI.thingInfo(try await validTokens())
            thingInfo = info
            if selectedThingID == nil || !info.things.contains(where: { $0.id == selectedThingID }) {
                select(info.things.first)
            }
            status = info.things.isEmpty ? "No devices on this account" : "Signed in"
        } catch {
            self.error = "Could not load devices: \(error.localizedDescription)"
        }
    }

    func select(_ thing: Thing?) {
        selectedThingID = thing?.id
        if let id = thing?.id { try? Keychain.save(id, as: .selectedThing) } else { Keychain.delete(.selectedThing) }
        state = nil
    }

    func stop() {}

    private func validTokens() async throws -> CognitoTokens {
        guard let current = tokens else { throw DaikinError.message("Not signed in.") }
        guard current.needsRefresh() else { return current }
        let refreshed = try await CognitoAuth.refresh(current)
        tokens = refreshed
        return refreshed
    }

    private func forgetSession() {
        tokens = nil; accountEmail = nil; thingInfo = nil; state = nil
        Keychain.delete(.session)
    }
}
