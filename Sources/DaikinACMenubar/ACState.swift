import Foundation

// The `port1` object is the AC state on every channel: the cloud shadow, the
// local LAN channel and comfort-profile `settings` all use the same integers.
enum ACMode: Int, CaseIterable, Identifiable, Codable {
    case auto = 1, dry = 2, cool = 3, heat = 4, fan = 6
    var id: Int { rawValue }

    // Some units report 0 while in AUTO (daikin-br ha-custom-integration, 2025-06-22).
    init?(wire: Int) { self.init(rawValue: wire == 0 ? ACMode.auto.rawValue : wire) }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .dry: return "Dry"
        case .cool: return "Cool"
        case .heat: return "Heat"
        case .fan: return "Fan"
        }
    }
    var symbol: String {
        switch self {
        case .auto: return "arrow.triangle.2.circlepath"
        case .dry: return "drop"
        case .cool: return "snowflake"
        case .heat: return "sun.max"
        case .fan: return "fan"
        }
    }
    // Target ranges the official integration enforces; nil means the target is fixed.
    var temperatureRange: ClosedRange<Int>? {
        switch self {
        case .cool: return 18...32
        case .heat: return 10...30
        case .auto: return 18...30
        case .dry, .fan: return nil
        }
    }
}

enum FanSpeed: Int, CaseIterable, Identifiable, Codable {
    case low = 3, lowMedium = 4, medium = 5, mediumHigh = 6, high = 7, auto = 17, quiet = 18
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .low: return "Low"
        case .lowMedium: return "Low-medium"
        case .medium: return "Medium"
        case .mediumHigh: return "Medium-high"
        case .high: return "High"
        case .auto: return "Auto"
        case .quiet: return "Quiet"
        }
    }
}

struct Sensors: Codable, Equatable {
    var roomTemp: Double?
    var outTemp: Double?
    enum CodingKeys: String, CodingKey { case roomTemp = "room_temp", outTemp = "out_temp" }

    // Units report 255 when a sensor has no reading (observed for out_temp).
    static func valid(_ value: Double?) -> Double? {
        guard let value, value > -50, value < 100 else { return nil }
        return value
    }
    var room: Double? { Sensors.valid(roomTemp) }
    var outdoor: Double? { Sensors.valid(outTemp) }
}

// Every field is optional: a reported state carries all of them, while a command
// carries only the keys being changed (synthesized encoding skips nil values).
struct Port1: Codable, Equatable {
    static let temperatureRange = 10...32

    var power: Int?
    var mode: Int?
    var temperature: Int?
    var fan: Int?
    var hSwing: Int?
    var vSwing: Int?
    var coanda: Int?
    var econo: Int?
    var powerchill: Int?
    var goodSleep: Int?
    var streamer: Int?
    var outQuite: Int?
    var onTimerSet: Int?
    var onTimerValue: Int?
    var offTimerSet: Int?
    var offTimerValue: Int?
    var sensors: Sensors?
    var fwVer: String?

    enum CodingKeys: String, CodingKey {
        case power, mode, temperature, fan, coanda, econo, powerchill, streamer, sensors
        case hSwing = "h_swing", vSwing = "v_swing", goodSleep = "good_sleep", outQuite = "out_quite"
        case onTimerSet = "on_timer_set", onTimerValue = "on_timer_value"
        case offTimerSet = "off_timer_set", offTimerValue = "off_timer_value"
        case fwVer = "fw_ver"
    }

    init() {}

    // Integers are read leniently: the protocol has only been checked statically,
    // so a unit that reports 24.0 instead of 24 must not break decoding.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) -> Int? {
            if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(value.rounded()) }
            return nil
        }
        power = int(.power); mode = int(.mode); temperature = int(.temperature); fan = int(.fan)
        hSwing = int(.hSwing); vSwing = int(.vSwing); coanda = int(.coanda); econo = int(.econo)
        powerchill = int(.powerchill); goodSleep = int(.goodSleep); streamer = int(.streamer); outQuite = int(.outQuite)
        onTimerSet = int(.onTimerSet); onTimerValue = int(.onTimerValue)
        offTimerSet = int(.offTimerSet); offTimerValue = int(.offTimerValue)
        sensors = try? c.decodeIfPresent(Sensors.self, forKey: .sensors)
        fwVer = try? c.decodeIfPresent(String.self, forKey: .fwVer)
    }

    var isOn: Bool { power == 1 }
    // Rules the official integration enforces before sending a change.
    var canChangeTemperature: Bool { acMode?.temperatureRange != nil && powerchill != 1 }
    var canChangeFan: Bool { acMode != .dry && powerchill != 1 }

    // True when every key set in `change` has the same value here.
    func satisfies(_ change: Port1) -> Bool {
        guard let mine = Port1.dictionary(self), let wanted = Port1.dictionary(change) else { return false }
        return wanted.allSatisfy { key, value in (mine[key] as? NSObject)?.isEqual(value) == true }
    }
    private static func dictionary(_ value: Port1) -> [String: Any]? {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    var acMode: ACMode? { mode.flatMap(ACMode.init(wire:)) }
    var fanSpeed: FanSpeed? { fan.flatMap(FanSpeed.init(rawValue:)) }

    static func clampTemperature(_ value: Int) -> Int {
        min(temperatureRange.upperBound, max(temperatureRange.lowerBound, value))
    }

    // Changes. Each returns only the keys that must be sent.
    static func setting(power on: Bool) -> Port1 { var p = Port1(); p.power = on ? 1 : 0; return p }
    static func setting(mode: ACMode) -> Port1 {
        var p = Port1(); p.power = 1; p.mode = mode.rawValue
        // DRY runs with automatic fan speed, as in the official integration.
        if mode == .dry { p.fan = FanSpeed.auto.rawValue }
        return p
    }
    static func setting(temperature: Int) -> Port1 { var p = Port1(); p.temperature = clampTemperature(temperature); return p }
    // A target one step up or down, kept inside the current mode's range.
    func steppedTemperature(by delta: Int) -> Int? {
        guard let range = acMode?.temperatureRange, let current = temperature else { return nil }
        let next = min(range.upperBound, max(range.lowerBound, current + delta))
        return next == current ? nil : Port1.clampTemperature(next)
    }
    static func setting(fan: FanSpeed) -> Port1 { var p = Port1(); p.fan = fan.rawValue; return p }

    // Extras, following the official app's "More" screen (HomeRemoteMoreFragment).
    // Econo (energy saving) and PowerChill exclude each other; Coanda runs with automatic fan.
    func setting(econo on: Bool) -> Port1 {
        var p = Port1(); p.econo = on ? 1 : 0
        if on, powerchill == 1 { p.powerchill = 0 }
        return p
    }
    func setting(powerchill on: Bool) -> Port1 {
        var p = Port1(); p.powerchill = on ? 1 : 0
        if on, econo == 1 { p.econo = 0 }
        if on, coanda == 1 { p.coanda = 0 }
        return p
    }
    func setting(coanda on: Bool) -> Port1 {
        var p = Port1(); p.coanda = on ? 1 : 0
        if on { p.fan = FanSpeed.auto.rawValue }
        if on, powerchill == 1 { p.powerchill = 0 }
        return p
    }
    static func setting(verticalSwing on: Bool) -> Port1 { var p = Port1(); p.vSwing = on ? 1 : 0; return p }
    var canUseExtras: Bool { isOn }
    var canUseEcono: Bool { isOn && acMode != .fan }
}

// The shadow document wraps port1 as `{"state":{"reported":{"port1":…},"desired":…}}`.
struct PortEnvelope: Codable, Equatable {
    var port1: Port1
}
