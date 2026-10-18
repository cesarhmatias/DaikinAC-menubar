import SwiftUI

@MainActor final class ACStore: ObservableObject {
    // The panel shell resizes itself whenever this changes.
    @Published var preferredPanelHeight: CGFloat = 600
    @Published var deviceName = "Daikin AC"
    @Published var state: Port1?
    @Published var status = "Not signed in"
    @Published var error: String?

    var signedIn: Bool { false }
    var accent: Color { state?.isOn == true ? Theme.accent(for: state?.acMode) : Theme.neutralAccent }

    func stop() {}
}
