import Foundation

/// User-facing amounts: zero is least processing, one is most.
struct VoiceSettings: Codable, Equatable {
    var compression: Double
    var depth: Double
    var rejection: Double

    static let natural = VoiceSettings(compression: 0.15, depth: 0, rejection: 0.2)
    static let balanced = VoiceSettings(compression: 0.5, depth: 0.35, rejection: 0.4)
    // Preserves the original app's approved sound, including its final warmer shelf and gate.
    static let warmBroadcast = VoiceSettings(compression: 0.75, depth: 1, rejection: 0.65)

    var normalized: Self {
        func clamp(_ value: Double, fallback: Double) -> Double { value.isFinite ? min(1, max(0, value)) : fallback }
        return Self(compression: clamp(compression, fallback: 0.5), depth: clamp(depth, fallback: 0.35), rejection: clamp(rejection, fallback: 0.4))
    }
    func blended(toward other: Self, fraction: Double) -> Self {
        let t = min(1, max(0, fraction)), a = normalized, b = other.normalized
        return Self(compression: a.compression + (b.compression-a.compression)*t, depth: a.depth+(b.depth-a.depth)*t, rejection: a.rejection+(b.rejection-a.rejection)*t)
    }
    func distance(to other: Self) -> Double { max(abs(compression-other.compression), abs(depth-other.depth), abs(rejection-other.rejection)) }
    var parameters: VoiceParameters {
        let s = normalized
        func piecewise(_ x: Double, middle: Double, _ start: Double, _ center: Double, _ end: Double) -> Float {
            Float(x <= middle ? start + (center-start)*x/middle : center + (end-center)*(x-middle)/(1-middle))
        }
        return VoiceParameters(
            compressionThreshold: piecewise(s.compression, middle: 0.75, 0, -30, -38),
            compressionHeadroom: piecewise(s.compression, middle: 0.75, 40, 12, 6),
            compressionMakeup: piecewise(s.compression, middle: 0.75, 0, 2, 4),
            bassGain: Float(6*s.depth), shelfGain: Float(-12*s.depth), presenceGain: Float(1.5*s.depth),
            gateThreshold: piecewise(s.rejection, middle: 0.65, -65, -40, -28),
            gateRatio: piecewise(s.rejection, middle: 0.65, 1, 4, 10))
    }
}
struct VoiceParameters {
    let compressionThreshold: Float
    let compressionHeadroom: Float
    let compressionMakeup: Float
    let bassGain: Float
    let shelfGain: Float
    let presenceGain: Float
    let gateThreshold: Float
    let gateRatio: Float
}
struct SavedPreferences: Codable {
    var sound = VoiceSettings.balanced
    var inputUID: String?
    var inputChannel: Int = 0
    var startProcessingOnOpen = false
    static let key = "soundOff.preferences.v1"
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), var settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        settings.sound = settings.sound.normalized
        settings.inputChannel = max(0, settings.inputChannel)
        return settings
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
