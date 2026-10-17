import Foundation
import AVFoundation
import AudioToolbox

final class TestInput {
    let samples: [Float]
    init(_ samples: [Float]) { self.samples = samples }
    static let callback: AURenderCallback = { context, _, time, _, frames, buffers in
        let source = Unmanaged<TestInput>.fromOpaque(context).takeUnretainedValue()
        guard let buffers else { return kAudio_ParamError }
        let start = Int(time.pointee.mSampleTime)
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let output = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<Int(frames) { let j = start+i; output[i] = j >= 0 && j < source.samples.count ? source.samples[j] : 0 }
        }
        return noErr
    }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw VoiceError(message: message) }
}
func sine(_ frequency: Double, db: Double, seconds: Int = 2) -> [Float] {
    let gain = pow(10, db/20)
    return (0..<48000*seconds).map { Float(gain * sin(2 * .pi * frequency * Double($0)/48000)) }
}
func rmsDB(_ samples: [Float]) -> Double { 10*log10(samples.reduce(0) { $0+Double($1)*Double($1) }/Double(samples.count)+1e-30) }
func render(_ samples: [Float], settings: VoiceSettings, sweep: Bool = false) throws -> [Float] {
    let source = TestInput(samples)
    let effects = try VoiceEffects(settings: settings, input: AURenderCallbackStruct(inputProc: TestInput.callback, inputProcRefCon: Unmanaged.passUnretained(source).toOpaque()))
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
    var output: [Float] = []; output.reserveCapacity(samples.count)
    for start in stride(from: 0, to: samples.count, by: 256) {
        if sweep { let x = Double(start)/Double(samples.count); try effects.apply(VoiceSettings(compression: x, depth: 1-x, rejection: x)) }
        let n = UInt32(min(256,samples.count-start)); buffer.frameLength = n
        var time = AudioTimeStamp(); time.mSampleTime = Double(start); time.mFlags = .sampleTimeValid
        var flags: AudioUnitRenderActionFlags = []
        try check(effects.render(&flags, &time, n, buffer.mutableAudioBufferList), "Test rendering")
        let a = buffer.floatChannelData![0], b = buffer.floatChannelData![1]
        for i in 0..<Int(n) {
            try require(a[i].isFinite && b[i].isFinite, "Nonfinite output")
            try require(abs(a[i]-b[i]) < 1e-6, "Stereo channels differ")
            try require(abs(a[i]) < 1, "Clipped output")
            output.append(a[i])
        }
    }
    return output
}
@main struct AudioTests {
    static func main() throws {
        let current = VoiceSettings.warmBroadcast.parameters
        try require(current.bassGain == 6 && current.shelfGain == -12 && current.presenceGain == 1.5, "Warm Broadcast tone changed")
        try require(current.compressionThreshold == -30 && current.compressionHeadroom == 12 && current.compressionMakeup == 2, "Warm Broadcast compression changed")
        try require(current.gateThreshold == -40 && current.gateRatio == 4, "Warm Broadcast gate changed")
        let bad = VoiceSettings(compression: .nan, depth: 100, rejection: -1).normalized
        try require(bad.compression.isFinite && bad.depth == 1 && bad.rejection == 0, "Invalid settings not normalized")
        let defaults = UserDefaults(suiteName: "SoundOff.Tests.\(UUID().uuidString)")!
        var prefs = SavedPreferences(); prefs.sound = .warmBroadcast; prefs.inputUID = "synthetic-test-device"; prefs.inputChannel = 2
        prefs.save(defaults); let restored = SavedPreferences.load(defaults)
        try require(restored.sound == .warmBroadcast && restored.inputChannel == 2 && restored.inputUID == prefs.inputUID, "Settings not restored")
        defaults.removeObject(forKey: SavedPreferences.key)
        print("PASS preserved preset, setting bounds and persistence")
        let silence = try render([Float](repeating: 0, count: 48000), settings: .warmBroadcast)
        try require(silence.allSatisfy { abs($0) < 1e-8 }, "Silent input not silent")
        for compression in [0.0,1] { for depth in [0.0,1] { for rejection in [0.0,1] {
            _ = try render(sine(120, db: 6), settings: VoiceSettings(compression: compression, depth: depth, rejection: rejection))
        } } }
        _ = try render(sine(400, db: -12), settings: .balanced, sweep: true)
        print("PASS silence, limiter overload at all control extremes, stereo and live parameter sweep")
        let natural = VoiceSettings(compression: 0, depth: 0, rejection: 0), deep = VoiceSettings(compression: 0, depth: 1, rejection: 0)
        for (frequency, range) in [(120.0, 5.0...7.0),(8000.0, -13.0 ... -11.0)] {
            let a = try render(sine(frequency, db: -50), settings: natural), b = try render(sine(frequency, db: -50), settings: deep)
            let gain = rmsDB(Array(b.suffix(48000)))-rmsDB(Array(a.suffix(48000)))
            try require(range.contains(gain), "Tone control frequency response incorrect: \(frequency) Hz, \(gain) dB")
            print(String(format: "PASS tone: %.0f Hz changes by %.2f dB", frequency, gain))
        }
        var quiet = natural; quiet.rejection = 1
        let noise = sine(500, db: -55)
        let open = try render(noise, settings: natural), gated = try render(noise, settings: quiet)
        let attenuation = rmsDB(Array(gated.suffix(48000)))-rmsDB(Array(open.suffix(48000)))
        try require(attenuation < -35, "Noise rejection too weak: \(attenuation)")
        print(String(format: "PASS noise rejection: %.1f dB quiet-signal attenuation", attenuation))
        let phrases = sine(500, db: -40) + sine(500, db: -10)
        var compressed = natural; compressed.compression = 1
        let dynamic = try render(phrases, settings: natural), even = try render(phrases, settings: compressed)
        func contrast(_ a: [Float]) -> Double { rmsDB(Array(a[144000..<192000]))-rmsDB(Array(a[48000..<96000])) }
        try require(contrast(even) < contrast(dynamic)-8, "Compression did not reduce dynamic range")
        print(String(format: "PASS compression: phrase contrast %.1f → %.1f dB", contrast(dynamic), contrast(even)))
        print("All audio tests passed. Synthetic signals only; no microphone permission required.")
    }
}
