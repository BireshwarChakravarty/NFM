import AudioToolbox
import CoreAudio
import Foundation

/// Listens to NFM's own audio (the WebKit helper processes playing Netflix)
/// through an *unmuted* Core Audio process tap and feeds it to a
/// `LoudnessMeter`. It never changes what you hear: the original sound keeps
/// playing untouched, and the tap's output is silence.
final class AudioTapMeter {
    enum StartError: Error {
        case noAudioProcesses
        case setupFailed(OSStatus)
    }

    let meter = LoudnessMeter()

    private let ioQueue = DispatchQueue(label: "app.nfm.meter.io", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var channels = ContiguousArray<(UnsafeMutablePointer<Float>, Int)>()

    private(set) var isRunning = false
    private(set) var tapSampleRate = 0.0
    private(set) var tapChannels = 0

    init() {
        channels.reserveCapacity(16)
    }

    deinit { stop() }

    func start() -> Result<Void, StartError> {
        stop()
        let processes = AudioHelpers.ownAudioProcesses()
        guard !processes.isEmpty else { return .failure(.noAudioProcesses) }

        let description = CATapDescription(stereoMixdownOfProcesses: processes.map(\.objectID))
        description.uuid = UUID()
        description.name = "NFM Audio Diagnostics"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { return .failure(.setupFailed(status)) }
        tapID = tap

        var format = AudioStreamBasicDescription()
        AudioHelpers.get(tap, kAudioTapPropertyFormat, &format)
        tapSampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        tapChannels = format.mChannelsPerFrame > 0 ? Int(format.mChannelsPerFrame) : 2
        meter.configure(sampleRate: tapSampleRate, channels: tapChannels)

        guard let outputUID = AudioHelpers.defaultOutputDeviceUID() else {
            stop()
            return .failure(.setupFailed(OSStatus(kAudioHardwareBadDeviceError)))
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NFM Audio Diagnostics",
            kAudioAggregateDeviceUIDKey: "app.nfm.meter." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { stop(); return .failure(.setupFailed(status)) }
        aggregateID = device

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue) { [weak self] _, input, _, output, _ in
            self?.handle(input: input, output: output)
        }
        guard status == noErr, let procID else { stop(); return .failure(.setupFailed(status)) }
        ioProcID = procID

        status = AudioDeviceStart(device, procID)
        guard status == noErr else { stop(); return .failure(.setupFailed(status)) }
        isRunning = true
        return .success(())
    }

    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    private func handle(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        // Never add anything to what's playing.
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        channels.removeAll(keepingCapacity: true)
        var frames = Int.max
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
            let count = Int(buffer.mNumberChannels)
            frames = min(frames, Int(buffer.mDataByteSize) / (4 * count))
            for c in 0..<count { channels.append((data + c, count)) }
        }
        guard !channels.isEmpty, frames != .max, frames > 0 else { return }
        channels.withUnsafeBufferPointer { meter.process($0, frames: frames) }
    }
}
