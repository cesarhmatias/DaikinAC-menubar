import SwiftUI
import AppKit

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
    var preferredHeight: CGFloat {
        switch self {
        case .control: return 510
        case .energy: return 350
        case .health: return 470
        case .schedules: return 300
        case .settings: return 470
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
    private var accent: Color { store.accent }
    init(store: ACStore) {
        self.store = store
        _tab = State(initialValue: ACTab.launchTab ?? (store.signedIn ? .control : .settings))
    }
    var body: some View {
        VStack(spacing: 0) {
            header.padding(.top, 16).padding(.bottom, 16)
            tabs.padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(tab.rawValue.uppercased())
                    tabContent
                    feedback
                }.padding(.bottom, 12)
            }.scrollIndicators(.hidden)
            footer.padding(.top, 10).padding(.bottom, 12)
        }.padding(.horizontal, Theme.horizontalPadding).frame(width: Theme.panelWidth)
            .background(Theme.background)
            .foregroundStyle(Theme.ink).preferredColorScheme(.dark)
            .font(.system(size: 12))
            .tint(accent)
            .animation(.easeOut(duration: 0.22), value: store.state?.mode)
            .onChange(of: tab) { _, value in store.preferredPanelHeight = value.preferredHeight }
            .onAppear { store.preferredPanelHeight = tab.preferredHeight }
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
            Image(systemName: "power").font(.system(size: 17)).foregroundStyle(store.state?.isOn == true ? .white : Theme.mutedInk)
                .frame(width: 34, height: 34).background(Circle().fill(Theme.buttonFill))
                .help("AC power is available after sign-in")
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
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TARGET").font(.system(size: 8, weight: .bold)).tracking(1.2).foregroundStyle(Theme.mutedInk)
                        Text(store.state?.temperature.map { "\($0)°" } ?? "--")
                            .font(.system(size: 44, weight: .medium, design: .rounded)).tracking(-1)
                            .foregroundStyle(store.state?.temperature == nil ? Theme.faintInk : accent)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        reading("Room", store.state?.sensors?.roomTemp)
                        reading("Outdoor", store.state?.sensors?.outTemp)
                    }
                }
            }
            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Mode").fontWeight(.semibold)
                    HStack(spacing: 6) {
                        ForEach(ACMode.allCases) { mode in
                            VStack(spacing: 5) {
                                Image(systemName: mode.symbol).font(.system(size: 14))
                                Text(mode.title).font(.system(size: 9, weight: .medium))
                            }.frame(maxWidth: .infinity).frame(height: 46)
                                .foregroundStyle(Theme.accent(for: mode))
                                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous).fill(Theme.accent(for: mode).opacity(0.1)))
                        }
                    }
                }
            }
            placeholder("Controls arrive after sign-in", "The app reads your AC state first. Commands are only sent after a successful read.", symbol: "lock")
        }
    }

    private var energyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                tile("TODAY", "— kWh"); tile("THIS WEEK", "— kWh"); tile("THIS MONTH", "— kWh")
            }
            placeholder("No readings yet", "Energy totals come from the cloud meter, synced at most every 6 hours.", symbol: "bolt")
        }
    }

    private var healthPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let thing = store.selectedThing, let info = store.thingInfo {
                let errors = info.errors(for: thing)
                PanelCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(errors.isEmpty ? "No reported errors" : "\(errors.count) reported error\(errors.count == 1 ? "" : "s")",
                              systemImage: errors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle").fontWeight(.semibold)
                            .foregroundStyle(errors.isEmpty ? Theme.ink : Theme.warning)
                        ForEach(errors) { item in
                            HStack(alignment: .top) {
                                Text(item.code).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Text(item.description ?? "Description arrives with error translation.").font(.system(size: 11)).foregroundStyle(Theme.mutedInk)
                            }
                        }
                    }
                }
                PanelCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Cloud subscription", systemImage: "cloud").fontWeight(.semibold)
                        detailRow("Status", thing.subscription?.status ?? "Not reported")
                        detailRow("Expires", thing.subscription.map(expiryText) ?? "Not reported")
                    }
                }
            } else {
                placeholder("Errors", "Reported error codes appear here with their Daikin description.", symbol: "exclamationmark.triangle")
                placeholder("Cloud subscription", "Remote access status and expiry date. Local control does not depend on it.", symbol: "cloud")
            }
            placeholder("Firmware", "Installed version and whether an update is available. Read-only.", symbol: "cpu")
        }
    }

    private func expiryText(_ subscription: CloudSubscription) -> String {
        guard let date = subscription.expiry else { return subscription.expiryDate ?? "Not reported" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(Theme.mutedInk); Spacer(); Text(value).fontWeight(.medium) }.font(.system(size: 11))
    }

    private var schedulesPanel: some View {
        placeholder("Comfort profiles", "Your schedules and their run history. They are shown read-only first.", symbol: "calendar")
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.signedIn { accountCard; devicesCard } else { signInCard }
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
