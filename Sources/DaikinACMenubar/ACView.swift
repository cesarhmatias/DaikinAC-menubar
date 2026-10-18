import SwiftUI
import AppKit
import Charts

enum ACTab: String, CaseIterable, Identifiable {
    case control = "Control", energy = "Energy", health = "Health", schedules = "Schedules", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .control: return "thermometer.medium"
        case .energy: return "bolt"
        case .health: return "stethoscope"
        case .schedules: return "calendar.badge.clock"
        case .settings: return "gearshape"
        }
    }
    // `--tab <name>` opens the panel on that tab.
    static var launchTab: ACTab? {
        guard let index = CommandLine.arguments.firstIndex(of: "--tab"), CommandLine.arguments.count > index + 1 else { return nil }
        return allCases.first { $0.rawValue.lowercased() == CommandLine.arguments[index + 1].lowercased() }
    }
}

struct ACView: View {
    @ObservedObject var store: ACStore
    @State private var tab: ACTab
    @State private var email = ""
    @State private var password = ""
    @State private var localKey = ""
    @State private var localName = ""
    private var accent: Color { store.accent }
    init(store: ACStore) {
        self.store = store
        _tab = State(initialValue: ACTab.launchTab ?? (store.signedIn || store.localDevice != nil ? .control : .settings))
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header.padding(.top, 16).padding(.bottom, 16)
                tabs.padding(.bottom, 14)
            }.measured("chrome")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if tab != .control { sectionTitle(tab.rawValue.uppercased()) }
                    tabContent
                    feedback
                }.padding(.bottom, 12).measured("content")
            }.scrollIndicators(.never)
            footer.padding(.top, 10).padding(.bottom, 12).measured("footer")
        }.padding(.horizontal, Theme.horizontalPadding).frame(width: Theme.panelWidth)
            // The panel grows to fit the visible tab; it scrolls only when the screen is too short.
            .onPreferenceChange(MeasuredHeights.self) { heights in
                guard let chrome = heights["chrome"], let content = heights["content"], let footer = heights["footer"] else { return }
                store.preferredPanelHeight = (Theme.arrowHeight + chrome + content + footer + 1).rounded(.up)
            }
            .background(Theme.background)
            .foregroundStyle(Theme.ink).preferredColorScheme(.dark)
            .font(.system(size: 12))
            .tint(accent)
            .animation(.easeOut(duration: 0.22), value: store.state?.mode)
            .onChange(of: tab) { _, value in
                if value == .energy { Task { await store.loadEnergy() } }
            }
            .onChange(of: store.thingInfo) { _, _ in if tab == .energy { Task { await store.loadEnergy() } } }
            .onChange(of: store.selectedThingID) { _, _ in if tab == .energy { Task { await store.loadEnergy() } } }
            .onAppear {
                if tab == .energy { Task { await store.loadEnergy() } }
            }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .control: controlPanel
        case .energy: energyPanel
        case .health: healthPanel
        case .schedules: schedulesPanel
        case .settings: settingsPanel
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "air.conditioner.horizontal").font(.system(size: 15, weight: .medium)).foregroundStyle(accent)
                .frame(width: 31, height: 31).background(Circle().fill(accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text(store.deviceName).font(.system(size: 17, weight: .semibold)).tracking(-0.3)
                Text("Daikin · Smart AC").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.mutedInk)
            }
            Spacer()
            Menu {
                Button("Quit DaikinAC-menubar") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 30).foregroundStyle(Theme.mutedInk) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Button { if let state = store.state { command(.setting(power: !state.isOn)) } } label: {
                Image(systemName: "power").font(.system(size: 17)).foregroundStyle(store.state?.isOn == true ? accent : Theme.mutedInk)
                    .frame(width: 34, height: 34).background(Circle().fill(store.state?.isOn == true ? accent.opacity(0.18) : Theme.buttonFill))
            }.buttonStyle(.plain).disabled(!store.canSendCommands)
                .help(store.commandsAllowed ? (store.state?.isOn == true ? "Turn the AC off" : "Turn the AC on") : "Allow commands in Settings first")
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(ACTab.allCases) { item in
                Button { tab = item } label: {
                    Image(systemName: item.symbol).font(.system(size: 16, weight: .medium))
                        .foregroundStyle(tab == item ? accent : Theme.mutedInk)
                        .frame(maxWidth: .infinity).frame(height: 35)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(tab == item ? accent.opacity(0.2) : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(item.rawValue).accessibilityLabel(item.rawValue)
            }
        }.padding(4).background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.tabBarFill))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.tabBarBorder, lineWidth: Theme.borderWidth))
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.mutedInk)
            Spacer()
        }.padding(.horizontal, 1)
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelCard {
                VStack(spacing: 8) {
                    ACUnitIllustration(accent: accent, running: store.state?.isOn == true,
                                       display: store.state.map { $0.isOn ? ($0.temperature.map { "\($0)°" } ?? "--") : "OFF" } ?? "--")
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 14) {
                        reading("Room", store.state?.sensors?.room)
                        reading("Outdoor", store.state?.sensors?.outdoor)
                        Spacer()
                        Text(store.state.map { $0.isOn ? ($0.acMode?.title.uppercased() ?? "ON") : "OFF" } ?? "")
                            .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(store.state?.isOn == true ? accent : Theme.mutedInk)
                    }
                    TemperatureControl(value: store.state?.temperature,
                                       range: store.state?.acMode?.temperatureRange ?? ACMode.cool.temperatureRange!,
                                       enabled: store.canSendCommands && store.state?.canChangeTemperature == true,
                                       accent: accent) { target in command(.setting(temperature: target)) }
                    if let state = store.state, !state.canChangeTemperature {
                        Text(state.powerchill == 1 ? "The target is fixed while Powerful is on." : "\(state.acMode?.title ?? "This") mode has no target temperature.")
                            .font(.system(size: 9)).foregroundStyle(Theme.mutedInk)
                    }
                }
            }
            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Mode").fontWeight(.semibold)
                    HStack(spacing: 6) {
                        ForEach(store.availableModes) { mode in
                            let current = store.state?.acMode == mode
                            Button { command(.setting(mode: mode)) } label: { VStack(spacing: 5) {
                                Image(systemName: mode.symbol).font(.system(size: 14))
                                Text(mode.title).font(.system(size: 9, weight: current ? .bold : .medium))
                            }.frame(maxWidth: .infinity).frame(height: 46)
                                .foregroundStyle(Theme.accent(for: mode).opacity(current || store.state == nil ? 1 : 0.55))
                                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                                    .fill(Theme.accent(for: mode).opacity(current ? 0.24 : 0.07)))
                                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                                    .strokeBorder(current ? Theme.accent(for: mode).opacity(0.7) : .clear, lineWidth: 1))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!store.canSendCommands || (current && store.state?.isOn == true))
                                .help(mode.title)
                        }
                    }
                    if let state = store.state {
                        HStack {
                            Text("Fan").foregroundStyle(Theme.mutedInk)
                            Spacer()
                            Menu {
                                ForEach(FanSpeed.allCases) { speed in Button(speed.title) { command(.setting(fan: speed)) } }
                            } label: {
                                Text(state.fanSpeed?.title ?? state.fan.map { "Unknown (\($0))" } ?? "Not reported").fontWeight(.medium)
                            }.menuStyle(.borderlessButton).fixedSize().disabled(!store.canSendCommands || !state.canChangeFan)
                        }.font(.system(size: 11))
                        HStack(spacing: 6) {
                            extra("Econo", "leaf", on: state.econo == 1, enabled: state.canUseEcono, state.setting(econo: state.econo != 1))
                            extra("Powerful", "bolt", on: state.powerchill == 1, enabled: state.canUseExtras, state.setting(powerchill: state.powerchill != 1))
                            extra("Coanda", "wind", on: state.coanda == 1, enabled: state.canUseExtras, state.setting(coanda: state.coanda != 1))
                            extra("Swing", "arrow.up.and.down", on: state.vSwing == 1, enabled: state.canUseExtras, .setting(verticalSwing: state.vSwing != 1))
                        }.padding(.top, 2)
                        let others = [state.goodSleep == 1 ? "Good sleep" : nil, state.streamer == 1 ? "Streamer" : nil,
                                      state.outQuite == 1 ? "Outdoor quiet" : nil, state.hSwing == 1 ? "Horizontal swing" : nil].compactMap { $0 }
                        if !others.isEmpty { detailRow("Also on", others.joined(separator: ", ")) }
                    }
                }
            }
            readStatus
        }
    }

    @ViewBuilder private var readStatus: some View {
        if !store.signedIn && store.localDevice == nil {
            placeholder("Sign in to read your AC", "Open Settings and sign in, or add the Device Key for local control.", symbol: "lock")
        } else if let lastRead = store.lastRead {
            HStack(spacing: 6) {
                if store.reading { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark.circle").foregroundStyle(Theme.mutedInk) }
                Text("Read from \(store.channel?.rawValue ?? "the cloud") at \(lastRead.formatted(date: .omitted, time: .standard))\(store.pendingDesired == nil ? "" : " · command pending")")
                    .font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
                Spacer()
                if store.sendingCommand != nil { ProgressView().controlSize(.mini); Text("Sending…").font(.system(size: 9)).foregroundStyle(Theme.mutedInk) }
                else if !store.commandsAllowed { Text("Read-only").font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.faintInk) }
            }.padding(.horizontal, 2)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(store.reading ? "Reading the AC state…" : "Waiting for the first read…").font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
            }.padding(.horizontal, 2)
        }
    }

    private var energyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                tile("TODAY", kwh(store.energy?.today))
                tile(store.energy.map { "WEEK \($0.weekNumber)" } ?? "THIS WEEK", kwh(store.energy?.week))
                tile("THIS MONTH", kwh(store.energy?.month))
            }
            if let energy = store.energy {
                PanelCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Daily use this month").fontWeight(.semibold)
                        if energy.monthDays.isEmpty {
                            Text("No readings this month yet.").font(.system(size: 11)).foregroundStyle(Theme.mutedInk)
                        } else {
                            Chart(energy.monthDays, id: \.day) { entry in
                                BarMark(x: .value("Day", Int(entry.day.suffix(2)) ?? 0), y: .value("kWh", entry.kwh))
                                    .foregroundStyle(accent.gradient).cornerRadius(2)
                            }
                            .chartXScale(domain: 0...32)
                            .chartXAxis { AxisMarks(values: [1, 8, 15, 22, 29]) { AxisValueLabel().font(.system(size: 8)) } }
                            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                                AxisGridLine().foregroundStyle(Theme.cardBorder); AxisValueLabel().font(.system(size: 8)) } }
                            .frame(height: 110)
                        }
                        HStack(spacing: 6) {
                            ForEach(1...5, id: \.self) { week in
                                VStack(spacing: 2) {
                                    Text("W\(week)").font(.system(size: 8, weight: .bold)).foregroundStyle(week == energy.weekNumber ? accent : Theme.mutedInk)
                                    Text(String(format: "%.1f", energy.weeks[week] ?? 0)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                                }.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            } else if !store.syncingEnergy {
                placeholder("No readings yet", "Energy totals come from the cloud meter, synced at most every 6 hours.", symbol: "bolt")
            }
            HStack(spacing: 6) {
                if store.syncingEnergy { ProgressView().controlSize(.mini); Text("Syncing energy data…") }
                else if let cache = store.energyCache, let last = cache.lastSync {
                    Text("Synced \(last.formatted(date: .abbreviated, time: .shortened)) · next after \((cache.nextSync() ?? last).formatted(date: .omitted, time: .shortened))")
                }
            }.font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
            Text("Usage is an estimate calculated by the Daikin system and may differ from your actual consumption.")
                .font(.system(size: 9)).foregroundStyle(Theme.faintInk).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func kwh(_ value: Double?) -> String { value.map { String(format: "%.1f kWh", $0) } ?? "— kWh" }

    private var healthPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let thing = store.selectedThing, let info = store.thingInfo {
                let errors = info.errors(for: thing)
                if let warning = DeviceHealth.subscriptionWarning(thing.subscription) {
                    PanelCard { Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.system(size: 11, weight: .medium)) }
                }
                PanelCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(errors.isEmpty ? "No reported errors" : "\(errors.count) reported error\(errors.count == 1 ? "" : "s")",
                              systemImage: errors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle").fontWeight(.semibold)
                            .foregroundStyle(errors.isEmpty ? Theme.ink : Theme.warning)
                        ForEach(errors) { item in
                            HStack(alignment: .top) {
                                Text(item.code).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Text(item.description ?? store.errorTranslations[item.code].flatMap { $0.isEmpty ? nil : $0 } ?? "Translating…")
                                    .font(.system(size: 11)).foregroundStyle(Theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                PanelCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Cloud subscription", systemImage: "cloud").fontWeight(.semibold)
                        detailRow("Status", thing.subscription?.status?.capitalized ?? "Not reported")
                        detailRow("Expires", thing.subscription.map(expiryText) ?? "Not reported")
                    }
                }
                PanelCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Firmware", systemImage: "cpu").fontWeight(.semibold)
                            Spacer()
                            if store.checkingFirmware { ProgressView().controlSize(.mini) }
                            else { Button("Check for update") { Task { await store.checkFirmware() } }.controlSize(.small).disabled(store.state?.fwVer == nil) }
                        }
                        detailRow("Installed", store.state?.fwVer ?? "Read the AC first")
                        if let firmware = store.firmware { detailRow("Latest", firmware.summary) }
                        if store.firmware?.status.uppercased() == "UPGRADE_AVAILABLE" {
                            Text("Install updates from the Daikin Smart AC app. This app only checks.").font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
                        }
                    }
                }
                PanelCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Diagnostics", systemImage: "stethoscope").fontWeight(.semibold)
                            Spacer()
                            if store.runningDiagnostics { ProgressView().controlSize(.mini) }
                            else { Button("Run") { Task { await store.runDiagnostics() } }.controlSize(.small) }
                        }
                        if let report = store.diagnostics {
                            if let mode = report.accessMode { detailRow("Access", mode) }
                            ForEach(Array(report.results.enumerated()), id: \.offset) { _, result in detailRow(result.label, result.status.capitalized) }
                            ForEach(report.statusTexts, id: \.self) { text in
                                Text(text).font(.system(size: 10)).foregroundStyle(Theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                            }
                            if let code = report.deviceErrorCode { detailRow("Device error", code) }
                        } else {
                            Text("Runs Daikin's connectivity check. Diagnostic data is not shared.").font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
                        }
                    }
                }
            } else {
                placeholder("Sign in to see device health", "Errors, subscription, firmware and diagnostics appear after sign-in.", symbol: "stethoscope")
            }
        }
        .task(id: store.thingInfo) { await store.translateErrors() }
        // Like the official firmware screen: fetched once when shown, never polled.
        .task(id: store.state?.fwVer) { if store.firmware == nil, store.state?.fwVer != nil { await store.checkFirmware() } }
    }

    private func expiryText(_ subscription: CloudSubscription) -> String {
        guard let date = subscription.expiry else { return subscription.expiryDate ?? "Not reported" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(Theme.mutedInk); Spacer(); Text(value).fontWeight(.medium) }.font(.system(size: 11))
    }

    private var schedulesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.signedIn {
                placeholder("Sign in to see schedules", "Your comfort profiles and their run history appear after sign-in.", symbol: "calendar")
            } else if store.comfortProfiles == nil {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading schedules…").font(.system(size: 10)).foregroundStyle(Theme.mutedInk) }
            } else {
                if store.schedules.isEmpty {
                    placeholder("No schedules", "Comfort profiles created in the Daikin app appear here.", symbol: "calendar")
                }
                ForEach(store.schedules) { rule in scheduleCard(rule) }
                PanelCard {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Recent runs", systemImage: "clock.arrow.circlepath").fontWeight(.semibold)
                        if store.deviceLogs.isEmpty { Text("No runs recorded.").font(.system(size: 11)).foregroundStyle(Theme.mutedInk) }
                        ForEach(store.deviceLogs.prefix(20)) { log in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(log.ruleName ?? "Schedule").font(.system(size: 11, weight: .medium))
                                    if let message = log.statusMessage, !message.isEmpty {
                                        Text(message).font(.system(size: 9)).foregroundStyle(Theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(log.executedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—").font(.system(size: 10)).monospacedDigit()
                                    Text(log.status?.capitalized ?? "").font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(log.status?.lowercased() == "success" ? Theme.mutedInk : Theme.warning)
                                }
                            }
                        }
                        if store.logsNextToken != nil {
                            Button("Load more") { Task { await store.loadMoreLogs() } }.controlSize(.small).disabled(store.loadingSchedules)
                        }
                    }
                }
                HStack {
                    Text("Read-only. Schedules are edited in the Daikin app for now.").font(.system(size: 9)).foregroundStyle(Theme.faintInk)
                    Spacer()
                    Button { Task { await store.loadSchedules(force: true) } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.mutedInk).disabled(store.loadingSchedules).help("Reload schedules")
                }
            }
        }
        .task(id: store.thingInfo) { await store.loadSchedules() }
    }

    private func scheduleCard(_ rule: ComfortRule) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(rule.name).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Text(rule.enabled ? "ON" : "OFF").font(.system(size: 8, weight: .bold)).tracking(0.8)
                        .foregroundStyle(rule.enabled ? accent : Theme.mutedInk)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(rule.enabled ? accent.opacity(0.15) : Theme.buttonFill))
                }
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
                    Text("\(rule.executeAt ?? "--:--") · \(Schedules.describe(rule.days))").font(.system(size: 11)).monospacedDigit()
                }
                Text(scheduleAction(rule.settings)).font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
                if rule.startDate != nil || rule.endDate != nil {
                    Text("\(rule.startDate ?? "…") → \(rule.endDate ?? "…")").font(.system(size: 9)).foregroundStyle(Theme.faintInk)
                }
            }
        }
    }

    private func scheduleAction(_ settings: Port1) -> String {
        guard settings.power == 1 else { return "Turns the AC off" }
        let parts = [settings.acMode?.title, settings.temperature.map { "\($0)°" }, settings.fanSpeed.map { "fan \($0.title.lowercased())" }].compactMap { $0 }
        return "Turns the AC on" + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", "))
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.signedIn { accountCard; devicesCard; commandsCard } else { signInCard; localOnlyCard; if store.localDevice != nil { commandsCard } }
            Button("Quit DaikinAC-menubar") { NSApplication.shared.terminate(nil) }.buttonStyle(.link).font(.system(size: 11))
        }
    }

    private var signInCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Daikin account", systemImage: "person.crop.circle").fontWeight(.semibold)
                Text("Sign in with your own Daikin Smart AC account. Your password is not stored; the session stays in the macOS Keychain.")
                    .font(.system(size: 11)).foregroundStyle(Theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                TextField("E-mail", text: $email).textFieldStyle(.roundedBorder).textContentType(.username)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).textContentType(.password)
                    .onSubmit(submitSignIn)
                HStack {
                    Button(store.signingIn ? "Signing in…" : "Sign in", action: submitSignIn)
                        .disabled(store.signingIn || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                    if store.signingIn { ProgressView().controlSize(.small) }
                }
                Text("Each click sends one sign-in request. Repeated failures can lock the account.")
                    .font(.system(size: 10)).foregroundStyle(Theme.faintInk).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submitSignIn() {
        guard !store.signingIn, !password.isEmpty else { return }
        let typed = password
        Task { await store.signIn(email: email, password: typed); password = "" }
    }

    private var localOnlyCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Local network only", systemImage: "wifi").fontWeight(.semibold)
                if let device = store.localDevice {
                    HStack {
                        Text(device.name).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button("Forget") { store.forgetLocalDevice() }.controlSize(.small)
                    }
                    Text(store.channel == .local ? "Controlling the AC on your Wi-Fi without the cloud." : (store.localStatus ?? "Open the panel near the AC's Wi-Fi to connect."))
                        .font(.system(size: 10)).foregroundStyle(Theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Control the AC on your Wi-Fi without signing in. Copy the Device Key from the Daikin app: Menu → Integrations → Home Assistant.")
                        .font(.system(size: 10)).foregroundStyle(Theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                    TextField("Name (optional)", text: $localName).textFieldStyle(.roundedBorder)
                    SecureField("Device Key", text: $localKey).textFieldStyle(.roundedBorder)
                    Button("Connect on the local network") {
                        let key = localKey, name = localName
                        Task { await store.useLocalDevice(key: key, name: name); if store.localDevice != nil { localKey = "" } }
                    }.disabled(localKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var commandsCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $store.commandsAllowed) { Text("Allow sending commands").fontWeight(.semibold) }.toggleStyle(.switch).controlSize(.small)
                Text("Commands change the AC in your home. They are sent only after the app has read its current state.")
                    .font(.system(size: 10)).foregroundStyle(Theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                Divider().opacity(0.3)
                Toggle(isOn: $store.preferLocal) { Text("Use the local network when available").fontWeight(.semibold) }.toggleStyle(.switch).controlSize(.small)
                Text("Talks to the AC directly on your Wi-Fi, with the cloud as the fallback. macOS asks once for local network access.")
                    .font(.system(size: 10)).foregroundStyle(Theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                if let status = store.localStatus {
                    Text(status).font(.system(size: 10)).foregroundStyle(store.channel == .local ? Theme.ink : Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func command(_ change: Port1) { Task { await store.send(change) } }

    private func extra(_ title: String, _ symbol: String, on: Bool, enabled: Bool, _ change: Port1) -> some View {
        Button { command(change) } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title).font(.system(size: 9, weight: on ? .bold : .medium))
            }.frame(maxWidth: .infinity).frame(height: 38)
        }.buttonStyle(PanelButton(selected: on, accent: accent))
            .disabled(!store.canSendCommands || !enabled)
            .help(on ? "Turn \(title) off" : enabled ? "Turn \(title) on" : "\(title) needs the AC on\(title == "Econo" ? " and not in Fan mode" : "")")
    }

    private var accountCard: some View {
        PanelCard {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.mutedInk)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.accountEmail ?? "Signed in").fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    Text("Daikin Smart AC account").font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
                }
                Spacer()
                Button("Sign out") { store.signOut() }
            }
        }
    }

    private var devicesCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Devices", systemImage: "air.conditioner.horizontal").fontWeight(.semibold)
                    Spacer()
                    if store.loadingDevices { ProgressView().controlSize(.mini) }
                    else {
                        Button { Task { await store.refreshDevices() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.mutedInk).help("Reload devices")
                    }
                }
                if store.things.isEmpty && !store.loadingDevices {
                    Text("No devices on this account.").font(.system(size: 11)).foregroundStyle(Theme.mutedInk)
                }
                ForEach(store.things) { thing in
                    Button { store.select(thing) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: thing.id == store.selectedThing?.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(thing.id == store.selectedThing?.id ? accent : Theme.mutedInk)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thing.name).font(.system(size: 12, weight: .medium))
                                if let model = thing.model { Text(model).font(.system(size: 10)).foregroundStyle(Theme.mutedInk) }
                            }
                            Spacer()
                            if thing.isAuthorized == false { Text("Not authorized").font(.system(size: 9)).foregroundStyle(Theme.warning) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func reading(_ title: String, _ value: Double?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
            Text(value.map { String(format: "%.1f°", $0) } ?? "—").font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Theme.mutedInk)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(accent.opacity(0.08)))
    }

    private func placeholder(_ title: String, _ detail: String, symbol: String) -> some View {
        PanelCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(accent).frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var feedback: some View {
        if let notice = store.notice, store.error == nil {
            Label(notice, systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Theme.mutedInk)
        }
        if let error = store.error {
            PanelCard {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warning)
                    Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.error = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).help("Dismiss message")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(store.signedIn ? Theme.online : Theme.mutedInk).frame(width: 5, height: 5)
            Text(store.status).font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
            Spacer()
            Text(store.state?.fwVer.map { "FW \($0)" } ?? "").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(Theme.faintInk)
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// Heights of the panel's parts, used to size the panel to its content.
struct MeasuredHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

extension View {
    func measured(_ name: String) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: MeasuredHeights.self, value: [name: proxy.size.height]) })
    }
}
