import Foundation
import AudioToolbox
import CoreAudio
import Synchronization

struct VoiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw VoiceError(message: "\(operation) (audio error \(status)).") }
}
func fourCC(_ value: String) -> UInt32 { value.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
func makeUnit(_ subtype: String, type: String = "aufx") throws -> AudioUnit {
    var description = AudioComponentDescription(componentType: fourCC(type), componentSubType: fourCC(subtype), componentManufacturer: fourCC("appl"), componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else { throw VoiceError(message: "Missing Apple audio effect: \(subtype)") }
    var unit: AudioUnit?
    try check(AudioComponentInstanceNew(component, &unit), "Create \(subtype)")
    guard let unit else { throw VoiceError(message: "Cannot create \(subtype)") }
    return unit
}
func property<T>(_ unit: AudioUnit, _ key: AudioUnitPropertyID, _ scope: AudioUnitScope, _ bus: UInt32, _ value: inout T) throws {
    try withUnsafePointer(to: &value) { pointer in
        try check(AudioUnitSetProperty(unit, key, scope, bus, pointer, UInt32(MemoryLayout<T>.size)), "Set audio property \(key)")
    }
}
func stereoFormat(_ rate: Double = 48000) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
}
struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
    let outputChannels: Int
    let transport: UInt32
    static func string(_ id: AudioObjectID, _ key: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: key, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "" }
        return value?.takeRetainedValue() as String? ?? ""
    }
    static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func transport(_ id: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var value: UInt32 = 0, size: UInt32 = 4
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }
    var isMicrophone: Bool {
        inputChannels > 0 && transport != kAudioDeviceTransportTypeVirtual && transport != kAudioDeviceTransportTypeAggregate && !uid.hasPrefix("BlackHole")
    }
    static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { AudioDevice(id: $0, name: string($0, kAudioObjectPropertyName), uid: string($0, kAudioDevicePropertyDeviceUID), inputChannels: channels($0, kAudioObjectPropertyScopeInput), outputChannels: channels($0, kAudioObjectPropertyScopeOutput), transport: transport($0)) }
    }
    static func required(inputUID: String, inputChannel: Int) throws -> (AudioDevice, AudioDevice) {
        let devices = all()
        guard let microphone = devices.first(where: { $0.uid == inputUID && $0.isMicrophone }) else {
            throw VoiceError(message: "Reconnect your selected microphone or choose another one.")
        }
        guard inputChannel >= 0 && inputChannel < microphone.inputChannels else { throw VoiceError(message: "Choose an available microphone channel.") }
        guard let output = devices.first(where: { $0.uid == "BlackHole2ch_UID" && $0.outputChannels == 2 }) else { throw VoiceError(message: "Install BlackHole 2ch, then restart your Mac.") }
        return (microphone, output)
    }
}

// One shared implementation is used by the live host and offline verification.
// Apple's audio units do the processing. No microphone data is saved or sent over a network.
final class VoiceEffects {
    var units: [AudioUnit] = []
    let maximumFrames: UInt32 = 4096
    init(settings: VoiceSettings, input: AURenderCallbackStruct, sampleRate: Double = 48000) throws {
        do {
            for (subtype, name) in [("dcmp", "Voice Gate"), ("pmeq", "Broad Bass"), ("dcmp", "Voice Compression"), ("mcmp", "Gentle Sibilance"), ("nbeq", "Warm Shelf"), ("pmeq", "Midrange Presence"), ("lmtr", "Restored Level Limiter")] {
                let unit = try makeUnit(subtype)
                units.append(unit)
                var format = stereoFormat(sampleRate)
                var maxFrames = maximumFrames
                try property(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames)
                if subtype == "nbeq" {
                    var bands: UInt32 = 1
                    try property(unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &bands)
                    for (parameter, value): (UInt32, Float) in [(kAUNBandEQParam_BypassBand, 0), (kAUNBandEQParam_FilterType, Float(kAUNBandEQFilterType_HighShelf)), (kAUNBandEQParam_Frequency, 1200), (kAUNBandEQParam_Gain, -12), (kAUNBandEQParam_Bandwidth, 1)] {
                        try check(AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0), "Set warm shelf")
                    }
                } else {
                    let values: [(UInt32, Float)]
                    switch name {
                    case "Voice Gate": values = [(0,20),(1,40),(2,4),(3,-40),(4,0.005),(5,0.15),(6,0)]
                    case "Broad Bass": values = [(0,120),(1,0.1),(2,6)]
                    case "Voice Compression": values = [(0,-30),(1,12),(2,1),(3,-80),(4,0.023),(5,0.15),(6,2)]
                    case "Gentle Sibilance": values = [(0,0),(1,0),(2,120),(3,700),(4,5500),(5,0),(6,0),(7,0),(8,-38),(9,40),(10,40),(11,40),(12,10),(13,0.002),(14,0.08),(15,0),(16,0),(17,0),(18,0)]
                    case "Midrange Presence": values = [(0,900),(1,1),(2,1.5)]
                    default: values = [(0,0.001),(1,0.06),(2,6)]
                    }
                    for (parameter, value) in values { try check(AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0), "Configure \(name)") }
                }
                try property(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format)
                try property(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format)
                if units.count == 1 {
                    var callback = input
                    try property(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback)
                } else {
                    var connection = AudioUnitConnection(sourceAudioUnit: units[units.count - 2], sourceOutputNumber: 0, destInputNumber: 0)
                    try property(unit, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &connection)
                }
            }
            try apply(settings)
            for unit in units { try check(AudioUnitInitialize(unit), "Initialize effect") }
        } catch { dispose(); throw error }
    }
    /// AudioUnitSetParameter is the AU host API for runtime control changes.
    /// The UI eases macro changes over several updates; it never rebuilds the audio graph.
    func apply(_ settings: VoiceSettings) throws {
        guard units.count == 7 else { throw VoiceError(message: "The effect chain is incomplete.") }
        let p = settings.parameters
        let changes: [(Int, UInt32, Float)] = [
            (0,2,p.gateRatio), (0,3,p.gateThreshold), (1,2,p.bassGain),
            (2,0,p.compressionThreshold), (2,1,p.compressionHeadroom), (2,6,p.compressionMakeup),
            (4,kAUNBandEQParam_Gain,p.shelfGain), (5,2,p.presenceGain)
        ]
        for (index, parameter, value) in changes { try check(AudioUnitSetParameter(units[index], parameter, kAudioUnitScope_Global, 0, value, 0), "Adjust sound") }
    }
    func dispose() { for unit in units.reversed() { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }; units = [] }
    deinit { dispose() }
    func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: UInt32, _ buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let last = units.last else { return kAudioUnitErr_Uninitialized }
        let status = AudioUnitRender(last, flags, timestamp, 0, frames, buffers)
        if status == noErr {
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(frames) { data[i] *= 0.89125094 }
            }
        }
        return status
    }
}

final class VoiceHost {
    var aggregate: AudioDeviceID = 0
    var io: AudioUnit?
    var effects: VoiceEffects?
    var microphoneID: AudioDeviceID = 0
    var outputID: AudioDeviceID = 0
    let inputPeak = Atomic<Float>(0)
    let outputPeak = Atomic<Float>(0)
    let callbackError = Atomic<Int32>(0)
    let renderedFrames = Atomic<UInt64>(0)
    private(set) var isRunning = false
    static let capture: AURenderCallback = { context, flags, timestamp, _, frames, buffers in
        let host = Unmanaged<VoiceHost>.fromOpaque(context).takeUnretainedValue()
        guard let io = host.io, let buffers else { return kAudioUnitErr_Uninitialized }
        let status = AudioUnitRender(io, flags, timestamp, 1, frames, buffers)
        if status == noErr { host.inputPeak.store(VoiceHost.peak(buffers, frames), ordering: .relaxed) }
        return status
    }
    static let playback: AURenderCallback = { context, flags, timestamp, _, frames, buffers in
        let host = Unmanaged<VoiceHost>.fromOpaque(context).takeUnretainedValue()
        guard let effects = host.effects, let buffers else { return kAudioUnitErr_Uninitialized }
        let status = effects.render(flags, timestamp, frames, buffers)
        if status == noErr {
            host.outputPeak.store(VoiceHost.peak(buffers, frames), ordering: .relaxed)
            host.renderedFrames.wrappingAdd(UInt64(frames), ordering: .relaxed)
        } else {
            host.callbackError.store(status, ordering: .relaxed)
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            flags.pointee.insert(.unitRenderAction_OutputIsSilence)
        }
        return noErr
    }
    static func peak(_ buffers: UnsafeMutablePointer<AudioBufferList>, _ frames: UInt32) -> Float {
        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<Int(frames) { peak = max(peak, abs(data[i])) }
        }
        return peak
    }
    func start(inputUID: String, inputChannel: Int, settings: VoiceSettings) throws {
        stop()
        let (microphone, output) = try AudioDevice.required(inputUID: inputUID, inputChannel: inputChannel)
        microphoneID = microphone.id; outputID = output.id
        do {
            // A private aggregate keeps the two hardware clocks in sync without changing
            // system playback. BlackHole channels come first; microphone channels follow.
            let description: [String: Any] = [
                kAudioAggregateDeviceUIDKey: "io.soundoff.private.\(UUID().uuidString)",
                kAudioAggregateDeviceNameKey: "SoundOff Internal",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: output.uid],
                    [kAudioSubDeviceUIDKey: microphone.uid, kAudioSubDeviceDriftCompensationKey: 1]
                ]
            ]
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "Connect microphone to BlackHole")
            var rate: Double = 48000
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            try check(AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &rate), "Set sample rate")
            var frames: UInt32 = 128
            address.mSelector = kAudioDevicePropertyBufferFrameSize
            try check(AudioObjectSetPropertyData(aggregate, &address, 0, nil, 4, &frames), "Set audio buffer")
            let inputs = AudioDevice.channels(aggregate, kAudioObjectPropertyScopeInput)
            let outputs = AudioDevice.channels(aggregate, kAudioObjectPropertyScopeOutput)
            guard inputs == output.inputChannels + microphone.inputChannels, outputs == output.outputChannels + microphone.outputChannels else { throw VoiceError(message: "Audio devices are still connecting. Try Start again.") }
            // Verify the active device order before using the channel map.
            address.mSelector = kAudioAggregateDevicePropertyActiveSubDeviceList
            var subdevices = [AudioObjectID](repeating: 0, count: 2)
            var size: UInt32 = 8
            try check(AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &subdevices), "Verify audio route")
            guard subdevices == [output.id, microphone.id] else { throw VoiceError(message: "Audio channel order could not be verified.") }
            let unit = try makeUnit("ahal", type: "auou"); io = unit
            var enabled: UInt32 = 1
            try property(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled)
            try property(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &aggregate)
            var format = stereoFormat()
            try property(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format)
            try property(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format)
            var inputMap: [Int32] = [Int32(output.inputChannels + inputChannel), Int32(output.inputChannels + inputChannel)]
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &inputMap, 8), "Select microphone channel")
            var outputMap = [Int32](repeating: -1, count: outputs)
            outputMap[0] = 0; outputMap[1] = 1
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 0, &outputMap, UInt32(outputs * 4)), "Select BlackHole output channels")
            let context = Unmanaged.passUnretained(self).toOpaque()
            effects = try VoiceEffects(settings: settings, input: AURenderCallbackStruct(inputProc: Self.capture, inputProcRefCon: context))
            var callback = AURenderCallbackStruct(inputProc: Self.playback, inputProcRefCon: context)
            try property(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback)
            try check(AudioUnitInitialize(unit), "Initialize microphone route")
            callbackError.store(0, ordering: .relaxed)
            renderedFrames.store(0, ordering: .relaxed)
            try check(AudioOutputUnitStart(unit), "Start microphone")
            isRunning = true
        } catch { stop(); throw error }
    }
    func apply(_ settings: VoiceSettings) throws { try effects?.apply(settings) }
    func stop() {
        if let io { AudioOutputUnitStop(io); AudioUnitUninitialize(io) }
        effects = nil
        if let io { AudioComponentInstanceDispose(io) }; io = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        isRunning = false
        inputPeak.store(0, ordering: .relaxed); outputPeak.store(0, ordering: .relaxed)
    }
    deinit { stop() }
}
