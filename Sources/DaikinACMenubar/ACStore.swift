import SwiftUI
import Network

// What survives a restart: the e-mail shown in Settings and the refresh token.
// The password is never stored.
// The unit used on the local network without sign-in. Saved from GET_THING_INFO after a
// sign-in, or typed by the user (the Device Key from the Daikin app's Home Assistant screen).
struct LocalDevice: Codable, Equatable {
    var name: String
    var apn: String?
    var key: String
}

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
    @Published private(set) var channel: StateChannel?
    @Published private(set) var localStatus: String?
    // On by default: the local network is tried first, the cloud is the fallback.
    @Published var preferLocal = UserDefaults.standard.object(forKey: "preferLocal") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preferLocal, forKey: "preferLocal"); if panelVisible { disconnectAll(); Task { await connectBest() } } }
    }
    @Published private(set) var unitType: String?
    @Published private(set) var sendingCommand: Port1?
    @Published var notice: String?
    @Published private(set) var energy: EnergySummary?
    @Published private(set) var energyCache: EnergyCache?
    @Published private(set) var syncingEnergy = false
    @Published private(set) var errorTranslations: [String: String] = [:]
    @Published private(set) var firmware: FirmwareInfo?
    @Published private(set) var checkingFirmware = false
    @Published private(set) var diagnostics: DiagnosticReport?
    @Published private(set) var runningDiagnostics = false
    @Published private(set) var comfortProfiles: [ComfortProfile]?
    @Published private(set) var executionLogs: [ExecutionLog] = []
    @Published private(set) var logsNextToken: String?
    @Published private(set) var loadingSchedules = false
    // On by default (the user's choice); Settings can turn commands off.
    @Published var commandsAllowed = UserDefaults.standard.object(forKey: "commandsAllowed") as? Bool ?? true {
        didSet { UserDefaults.standard.set(commandsAllowed, forKey: "commandsAllowed") }
    }
    @Published var status = "Not signed in"
    @Published var error: String?

    var signedIn: Bool { tokens != nil }
    var things: [Thing] { thingInfo?.things ?? [] }
    var selectedThing: Thing? { things.first { $0.id == selectedThingID } ?? things.first }
    var deviceName: String { selectedThing?.name ?? localDevice?.name ?? "Daikin AC" }
    @Published private(set) var localDevice: LocalDevice? = Keychain.read(.localDevice).flatMap { try? JSONDecoder().decode(LocalDevice.self, from: $0) }
    var canUseLocalOnly: Bool { !signedIn && localDevice != nil }
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
            if panelVisible { await connectBest() }
        } catch {
            self.error = "Could not load devices: \(error.localizedDescription)"
        }
    }

    // Remembers the selected unit for local control without sign-in.
    private func rememberLocalDevice(_ thing: Thing?) {
        guard let thing, let key = thing.secretKey else { return }
        let device = LocalDevice(name: thing.name, apn: thing.apn, key: key)
        guard device != localDevice, let data = try? JSONEncoder().encode(device) else { return }
        try? Keychain.save(data, as: .localDevice)
        localDevice = device
    }

    // Saves a typed Device Key and tries it on the local network; it is kept only if the unit answers.
    func useLocalDevice(key text: String, name: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalChannel.key(fromDeviceKey: text) != nil else { error = "That is not a valid device key (base64 of 16, 24 or 32 bytes)."; return }
        let previous = localDevice
        localDevice = LocalDevice(name: name.isEmpty ? "Daikin AC" : name, apn: nil, key: text)
        disconnectAll()
        await connectBest()
        if channel == .local, let device = localDevice, let data = try? JSONEncoder().encode(device) {
            try? Keychain.save(data, as: .localDevice)
        } else {
            localDevice = previous
            error = "The key did not open any Daikin unit on this network. " + (localStatus ?? "")
        }
    }

    func forgetLocalDevice() {
        Keychain.delete(.localDevice)
        localDevice = nil
        if !signedIn { disconnectAll(); state = nil }
    }

    func select(_ thing: Thing?) {
        rememberLocalDevice(thing)
        let changed = thing?.id != selectedThingID
        selectedThingID = thing?.id
        if let id = thing?.id { try? Keychain.save(id, as: .selectedThing) } else { Keychain.delete(.selectedThing) }
        guard changed else { return }
        disconnectAll()
        state = nil; pendingDesired = nil; lastRead = nil; unitType = nil; energy = nil; energyCache = nil; firmware = nil; diagnostics = nil
        if panelVisible { Task { await connectBest() } }
    }

    // MARK: Shadow state

    private var credentials: AWSCredentials?
    // Published so controls update the moment a channel opens or closes.
    @Published private var connection: ShadowConnection?
    private var panelVisible = false

    // The shadow connection is open only while the panel is visible. A failed attempt is
    // not retried on its own; reopening the panel tries once more.
    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible { Task { await connectBest() } } else { disconnectAll() }
    }

    // MARK: Local network

    @Published private var localEndpoint: NWEndpoint?
    private var localKey: Data?
    private var localPoll: Task<Void, Never>?
    private var connecting = false
    static let localPollInterval: Duration = .seconds(10)

    // Tries the unit on the local network first (mDNS + a decrypted GET /acstatus proves it is
    // this device), then falls back to the cloud shadow.
    func connectBest() async {
        guard panelVisible, connection == nil, localEndpoint == nil, !connecting else { return }
        // Signed in: the selected device from GET_THING_INFO. Signed out: the saved local device.
        let target: (id: String?, apn: String?, key: String?)
        if signedIn, let thing = selectedThing { target = (thing.id, thing.apn, thing.secretKey ?? localDevice?.key) }
        else if !signedIn, let device = localDevice { target = (nil, device.apn, device.key) }
        else { return }
        connecting = true
        defer { connecting = false }
        if preferLocal || !signedIn, let text = target.key, let key = LocalChannel.key(fromDeviceKey: text) {
            reading = true
            let units = await LocalDiscovery.browse()
            var failures: [String] = []
            for unit in LocalDiscovery.candidates(units, apn: target.apn) {
                guard panelVisible, selectedThing?.id == target.id || !signedIn else { reading = false; return }
                do {
                    guard let endpoint = await LocalDiscovery.localAPIEndpoint(for: unit.endpoint) else {
                        throw DaikinError.message("Could not resolve the unit's address.")
                    }
                    let reported = try await LocalChannel.status(at: endpoint, key: key)
                    localEndpoint = endpoint; localKey = key; channel = .local
                    localStatus = "Connected on the local network."
                    applyLocal(reported)
                    startLocalPolling()
                    return
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            reading = false
            localStatus = units.isEmpty ? "No Daikin unit found on this network\(signedIn ? "; using the cloud." : ".")"
                : "Found \(units.count) unit\(units.count == 1 ? "" : "s") but could not read it: \(failures.joined(separator: " / "))"
            if let data = try? JSONSerialization.data(withJSONObject: ["found": units.count, "errors": failures]) {
                ResponseShapes.record("local-attempt", data: data, status: 0)
            }
        }
        guard signedIn, panelVisible, let thing = selectedThing, thing.id == target.id else { return }
        await connectShadow()
    }

    private func applyLocal(_ reported: Port1) {
        reading = false
        state = reported; pendingDesired = nil; lastRead = Date()
    }

    private func startLocalPolling() {
        localPoll?.cancel()
        localPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ACStore.localPollInterval)
                guard !Task.isCancelled else { return }
                await self?.pollLocal()
            }
        }
    }

    private var localFailures = 0

    // One failed poll is tolerated (Wi-Fi blips, sleep); two in a row fall back to the cloud.
    private func pollLocal() async {
        guard let endpoint = localEndpoint, let key = localKey, sendingCommand == nil else { return }
        do {
            applyLocal(try await LocalChannel.status(at: endpoint, key: key))
            localFailures = 0
        } catch {
            localFailures += 1
            guard localFailures >= 2 else { return }
            localFailures = 0
            stopLocal()
            localStatus = "Lost the AC on the local network\(signedIn ? "; using the cloud" : ""). Reopen the panel to try again."
            self.error = "Lost the AC on the local network\(signedIn ? "; using the cloud" : ""). (\(error.localizedDescription))"
            if signedIn { await connectShadow() }
        }
    }

    private func stopLocal() {
        localPoll?.cancel(); localPoll = nil
        localEndpoint = nil; localKey = nil
        if channel == .local { channel = nil }
    }

    func disconnectAll() {
        stopLocal()
        disconnectShadow()
        channel = nil
    }

    func connectShadow() async {
        guard signedIn, panelVisible, connection == nil, let thing = selectedThing else { return }
        let connection = ShadowConnection(thingID: thing.id)
        self.connection = connection
        reading = true
        connection.onDocument = { [weak self] document in
            guard let self, self.selectedThing?.id == thing.id else { return }
            self.reading = false
            self.channel = .cloud
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

    // MARK: Energy

    // Shows the cached readings at once and asks the server for newer rows at most every 6 h.
    func loadEnergy() async {
        guard signedIn, let thing = selectedThing, !syncingEnergy else { return }
        var cache = Energy.loadCache(thingID: thing.id)
        show(cache)
        guard cache.needsSync() else { return }
        syncingEnergy = true
        defer { syncingEnergy = false }
        do {
            let rows = try await Energy.fetch(try await validTokens(), thingID: thing.id, lastRecordDate: cache.latestRecordDate)
            guard thing.id == selectedThing?.id else { return }
            cache.merge(rows, at: Date())
            try Energy.saveCache(cache, thingID: thing.id)
            show(cache)
        } catch {
            self.error = "Could not sync energy data: \(error.localizedDescription)"
        }
    }

    private func show(_ cache: EnergyCache) {
        energyCache = cache
        energy = cache.readings.isEmpty ? nil : EnergySummary(usage: Energy.dailyUsage(cache.rows), now: Date())
    }

    // MARK: Health

    // Translates each reported code once per session (pt-BR, as the official app does).
    func translateErrors() async {
        guard signedIn, let thing = selectedThing, let info = thingInfo else { return }
        for item in info.errors(for: thing) where errorTranslations[item.code] == nil && item.description == nil {
            errorTranslations[item.code] = ""   // mark as requested so it is not asked again
            do {
                if let text = try await DeviceHealth.translateError(code: item.manufacturerCode ?? item.code, tokens: try await validTokens()) {
                    errorTranslations[item.code] = text
                }
            } catch {
                self.error = "Could not translate error \(item.code): \(error.localizedDescription)"
            }
        }
    }

    // On demand only; the firmware endpoint is not polled.
    func checkFirmware() async {
        guard signedIn, let thing = selectedThing, let version = state?.fwVer, !checkingFirmware else { return }
        checkingFirmware = true
        defer { checkingFirmware = false }
        do {
            firmware = try await DeviceHealth.latestFirmware(tokens: try await validTokens(), thingID: thing.id, firmwareVersion: version)
            if firmware == nil { error = "The firmware service returned no status for this unit." }
        } catch {
            self.error = "Could not check firmware: \(error.localizedDescription)"
        }
    }

    func runDiagnostics() async {
        guard signedIn, let thing = selectedThing, !runningDiagnostics else { return }
        runningDiagnostics = true
        defer { runningDiagnostics = false }
        do {
            let credentials = try await validCredentials()
            guard let cognitoID = credentials.identityID else { throw DaikinError.message("The Identity Pool returned no IdentityId.") }
            diagnostics = try await DeviceHealth.runDiagnostics(tokens: try await validTokens(), cognitoID: cognitoID, thingID: thing.id,
                                                                localReachable: channel == .local)
        } catch {
            self.error = "Could not run diagnostics: \(error.localizedDescription)"
        }
    }

    // MARK: Schedules (read-only)

    var schedules: [ComfortRule] { comfortProfiles?.first { $0.thingID == selectedThing?.id }?.rules ?? [] }
    // The logs cover the whole account; keep the ones whose rule belongs to this device.
    var deviceLogs: [ExecutionLog] {
        let ids = Set(schedules.map(\.id))
        return ids.isEmpty ? executionLogs : executionLogs.filter { $0.ruleID.map(ids.contains) ?? true }
    }

    // Loaded once when the tab opens; Reload asks again.
    func loadSchedules(force: Bool = false) async {
        guard signedIn, !loadingSchedules, force || comfortProfiles == nil else { return }
        loadingSchedules = true
        defer { loadingSchedules = false }
        do {
            let tokens = try await validTokens()
            comfortProfiles = try await Schedules.profiles(tokens: tokens)
            let page = try await Schedules.executionLogs(tokens: tokens, nextToken: nil)
            executionLogs = page.logs; logsNextToken = page.nextToken
        } catch {
            self.error = "Could not load schedules: \(error.localizedDescription)"
        }
    }

    func loadMoreLogs() async {
        guard signedIn, !loadingSchedules, let token = logsNextToken else { return }
        loadingSchedules = true
        defer { loadingSchedules = false }
        do {
            let page = try await Schedules.executionLogs(tokens: try await validTokens(), nextToken: token)
            executionLogs += page.logs; logsNextToken = page.nextToken
        } catch {
            self.error = "Could not load more history: \(error.localizedDescription)"
        }
    }

    // MARK: Commands

    private var commandTimeout: Task<Void, Never>?
    var canSendCommands: Bool { commandsAllowed && state != nil && (connection != nil || localEndpoint != nil) && sendingCommand == nil }
    var availableModes: [ACMode] { unitType?.uppercased() == "COOL_ONLY" ? ACMode.allCases.filter { $0 != .heat } : ACMode.allCases }

    // Sends one change after a successful read. The command counts as applied once the
    // shadow's `desired` is cleared and `reported` shows the new values (10 s, like the app).
    func send(_ change: Port1) async {
        guard canSendCommands else { return }
        sendingCommand = change; notice = nil; error = nil
        // On the local network the reply is the unit's new state.
        if let endpoint = localEndpoint, let key = localKey {
            do {
                let reported = try await LocalChannel.command(change, at: endpoint, key: key)
                applyLocal(reported)
                finishCommand(notice: reported.satisfies(change) ? "Applied by the AC (local network)." : nil)
                if !reported.satisfies(change) { error = "The AC answered but did not apply the change." }
            } catch {
                finishCommand(notice: nil)
                self.error = "Could not send the command on the local network: \(error.localizedDescription)"
            }
            return
        }
        guard let connection else { finishCommand(notice: nil); return }
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
        if localEndpoint != nil { await pollLocal() }
        else if let connection { try? await connection.requestDocument() } else { await connectBest() }
    }

    private func validCredentials() async throws -> AWSCredentials {
        if let credentials, !credentials.needsRefresh() { return credentials }
        let fresh = try await IdentityPool.credentials(idToken: try await validTokens().idToken)
        credentials = fresh
        return fresh
    }

    func stop() { disconnectAll() }

    private func validTokens() async throws -> CognitoTokens {
        guard let current = tokens else { throw DaikinError.message("Not signed in.") }
        guard current.needsRefresh() else { return current }
        let refreshed = try await CognitoAuth.refresh(current)
        tokens = refreshed
        return refreshed
    }

    private func forgetSession() {
        disconnectAll()
        tokens = nil; accountEmail = nil; thingInfo = nil; state = nil; energy = nil; energyCache = nil; firmware = nil; diagnostics = nil; errorTranslations = [:]; comfortProfiles = nil; executionLogs = []; logsNextToken = nil; credentials = nil; pendingDesired = nil; lastRead = nil
        Keychain.delete(.session)
    }
}

enum StateChannel: String {
    case local = "the local network", cloud = "the cloud"
}
