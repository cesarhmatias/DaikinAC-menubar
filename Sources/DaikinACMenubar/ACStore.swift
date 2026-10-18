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
    @Published private(set) var pendingDesired: Port1?
    @Published private(set) var lastRead: Date?
    @Published private(set) var reading = false
    @Published private(set) var unitType: String?
    @Published private(set) var sendingCommand: Port1?
    @Published var notice: String?
    // Off by default: commands change a physical device, so the user turns them on in Settings.
    @Published var commandsAllowed = UserDefaults.standard.bool(forKey: "commandsAllowed") {
        didSet { UserDefaults.standard.set(commandsAllowed, forKey: "commandsAllowed") }
    }
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
            if panelVisible { await connectShadow() }
        } catch {
            self.error = "Could not load devices: \(error.localizedDescription)"
        }
    }

    func select(_ thing: Thing?) {
        let changed = thing?.id != selectedThingID
        selectedThingID = thing?.id
        if let id = thing?.id { try? Keychain.save(id, as: .selectedThing) } else { Keychain.delete(.selectedThing) }
        guard changed else { return }
        disconnectShadow()
        state = nil; pendingDesired = nil; lastRead = nil; unitType = nil
        if panelVisible { Task { await connectShadow() } }
    }

    // MARK: Shadow state

    private var credentials: AWSCredentials?
    private var connection: ShadowConnection?
    private var panelVisible = false

    // The shadow connection is open only while the panel is visible. A failed attempt is
    // not retried on its own; reopening the panel tries once more.
    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible { Task { await connectShadow() } } else { disconnectShadow() }
    }

    func connectShadow() async {
        guard signedIn, panelVisible, connection == nil, let thing = selectedThing else { return }
        let connection = ShadowConnection(thingID: thing.id)
        self.connection = connection
        reading = true
        connection.onDocument = { [weak self] document in
            guard let self, self.selectedThing?.id == thing.id else { return }
            self.reading = false
            self.state = document.reported
            self.pendingDesired = document.desired
            self.unitType = document.unitType ?? self.unitType
            self.lastRead = Date()
            if let command = self.sendingCommand, document.desired == nil, document.reported?.satisfies(command) == true {
                self.finishCommand(notice: "Applied by the AC.")
            }
            if document.reported == nil { self.error = "The shadow has no reported port1 state yet." }
        }
        connection.onClose = { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            self.connection = nil
            self.reading = false
            if let error { self.error = "Shadow connection: \(error.localizedDescription)" }
        }
        do {
            let credentials = try await validCredentials()
            guard let sub = tokens?.sub else { throw DaikinError.message("The ID token has no sub claim.") }
            // A client ID of our own: reusing the phone app's (the bare sub) would disconnect it.
            try await connection.open(clientID: sub + "-mac", credentials: credentials)
        } catch {
            connection.close(error)
        }
    }

    func disconnectShadow() {
        let current = connection
        connection = nil
        reading = false
        if sendingCommand != nil { finishCommand(notice: nil) }
        current?.close()
    }

    // MARK: Commands

    private var commandTimeout: Task<Void, Never>?
    var canSendCommands: Bool { commandsAllowed && state != nil && connection != nil && sendingCommand == nil }
    var availableModes: [ACMode] { unitType?.uppercased() == "COOL_ONLY" ? ACMode.allCases.filter { $0 != .heat } : ACMode.allCases }

    // Sends one change after a successful read. The command counts as applied once the
    // shadow's `desired` is cleared and `reported` shows the new values (10 s, like the app).
    func send(_ change: Port1) async {
        guard canSendCommands, let connection else { return }
        sendingCommand = change; notice = nil; error = nil
        do {
            try await connection.publishDesired(change)
        } catch {
            finishCommand(notice: nil)
            self.error = "Could not send the command: \(error.localizedDescription)"
            return
        }
        commandTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.sendingCommand != nil else { return }
            self.finishCommand(notice: nil)
            self.error = "The AC did not confirm the command within 10 s. It may still apply it."
        }
    }

    private func finishCommand(notice: String?) {
        commandTimeout?.cancel(); commandTimeout = nil
        sendingCommand = nil
        self.notice = notice
    }

    func readState() async {
        if let connection { try? await connection.requestDocument() } else { await connectShadow() }
    }

    private func validCredentials() async throws -> AWSCredentials {
        if let credentials, !credentials.needsRefresh() { return credentials }
        let fresh = try await IdentityPool.credentials(idToken: try await validTokens().idToken)
        credentials = fresh
        return fresh
    }

    func stop() { disconnectShadow() }

    private func validTokens() async throws -> CognitoTokens {
        guard let current = tokens else { throw DaikinError.message("Not signed in.") }
        guard current.needsRefresh() else { return current }
        let refreshed = try await CognitoAuth.refresh(current)
        tokens = refreshed
        return refreshed
    }

    private func forgetSession() {
        disconnectShadow()
        tokens = nil; accountEmail = nil; thingInfo = nil; state = nil; credentials = nil; pendingDesired = nil; lastRead = nil
        Keychain.delete(.session)
    }
}
