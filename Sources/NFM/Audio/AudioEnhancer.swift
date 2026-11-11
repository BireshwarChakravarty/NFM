import AudioToolbox
import CoreAudio
import Foundation

/// NFM's audio enhancer: Loudness Match, Voice Boost and extra boost.
///
/// Netflix's sound is DRM-protected and played by WebKit's helper processes,
/// so the page itself can't change it. Instead NFM uses a Core Audio process
/// tap (the mechanism behind per-app volume mixers) on *its own* WebKit
/// helpers: it mutes the original and plays the tapped audio back through the
/// current output device after processing it (see `EnhancerDSP`).
///
/// Nothing is recorded. macOS asks once for "System Audio Recording" access.
/// If the tap stays silent while Netflix is playing (access denied, or the
/// system withholds protected audio), the tap is torn down so the original
/// sound comes straight back.
final class AudioEnhancer {
    enum Failure {
        case setupFailed(OSStatus)
        case silent
    }

    /// What the enhancer is doing right now, for the UI.
    struct Status {
        var running = false
        var loudnessMatch = false
        var addedGainDB: Double = 0
        var targetLUFS = -16
        var voiceBoost = false
        var extraBoost = 100
    }

    /// Called on the main queue when enhancement had to be switched off.
    var onFailure: ((Failure) -> Void)?

    private let dsp = EnhancerDSP()
    private let queue = DispatchQueue(label: "app.nfm.audio")
    private let ioQueue = DispatchQueue(label: "app.nfm.audio.io", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tappedPIDs: Set<pid_t> = []
    private var listenersInstalled = false

    // Main-thread state
    private var wanted = false
    private var running = false
    private var playing = false
    private var failedThisSession = false
    private var watchdog: Timer?
    private var playingSeconds = 0
    private var verified = false
    private var lastSignalTicks: UInt64 = 0
    private var retryWork: DispatchWorkItem?

    /// Whether any processing is switched on.
    static var isRequested: Bool { Prefs.loudnessMatch || Prefs.soundBoost > 100 || Prefs.voiceBoost }

    var status: Status {
        Status(running: running && verified,
               loudnessMatch: Prefs.loudnessMatch,
               addedGainDB: Double(dsp.matchGainDB),
               targetLUFS: Prefs.loudnessTarget,
               voiceBoost: Prefs.voiceBoost,
               extraBoost: Prefs.soundBoost)
    }

    // MARK: Control (main thread)

    /// Call whenever playback state or settings change.
    func update(watching: Bool, audible: Bool) {
        dsp.manualGain = Float(Prefs.soundBoost) / 100
        dsp.voiceBoost = Prefs.voiceBoost
        dsp.loudnessMatch = Prefs.loudnessMatch
        dsp.targetLUFS = Float(Prefs.loudnessTarget)
        playing = audible
        let want = watching && Self.isRequested && !failedThisSession
        guard want != wanted else { return }
        wanted = want
        if want { start() } else { stop() }
    }

    /// The user changed a setting themselves: give it another try even if it failed earlier.
    func resetFailure() {
        failedThisSession = false
    }

    private func start(attempt: Int = 0) {
        verified = false
        playingSeconds = 0
        lastSignalTicks = dsp.signalTicks
        dsp.prime(gainDB: Float(Prefs.lastMatchGain))
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.build()
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.running = true
                    self.startWatchdog()
                    if !self.wanted { self.stop() }
                case .waitingForAudio:
                    // WebKit hasn't started its audio process yet: try again shortly.
                    guard self.wanted, attempt < 60 else { return }
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.wanted, !self.running else { return }
                        self.start(attempt: attempt + 1)
                    }
                    self.retryWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
                case .failure(let failure):
                    self.fail(failure)
                }
            }
        }
    }

    private func stop() {
        retryWork?.cancel()
        retryWork = nil
        watchdog?.invalidate()
        watchdog = nil
        if running && verified && Prefs.loudnessMatch {
            Prefs.lastMatchGain = Double(dsp.matchGainDB)
        }
        running = false
        queue.async { [weak self] in self?.teardown() }
    }

    private func fail(_ failure: Failure) {
        failedThisSession = true
        wanted = false
        stop()
        onFailure?(failure)
    }

    /// If no sound at all comes through the tap during the first seconds of
    /// playback, give the original audio back.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.running, !self.verified else { return }
            if self.dsp.signalTicks != self.lastSignalTicks {
                self.verified = true
                self.watchdog?.invalidate()
                return
            }
            if self.playing { self.playingSeconds += 1 }
            if self.playingSeconds >= 8 { self.fail(.silent) }
        }
    }

    // MARK: Core Audio (serial queue)

    private enum BuildResult { case success, waitingForAudio, failure(Failure) }

    private func build() -> BuildResult {
        teardown()
        let processes = AudioHelpers.ownAudioProcesses()
        guard !processes.isEmpty else { return .waitingForAudio }

        let description = CATapDescription(stereoMixdownOfProcesses: processes.map(\.objectID))
        description.uuid = UUID()
        description.name = "NFM Audio"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { return .failure(.setupFailed(status)) }
        tapID = tap
        tappedPIDs = Set(processes.map(\.pid))

        var format = AudioStreamBasicDescription()
        AudioHelpers.get(tap, kAudioTapPropertyFormat, &format)
        dsp.configure(sampleRate: format.mSampleRate > 0 ? format.mSampleRate : 48_000)

        guard let outputUID = AudioHelpers.defaultOutputDeviceUID() else {
            teardown()
            return .failure(.setupFailed(OSStatus(kAudioHardwareBadDeviceError)))
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NFM Audio",
            kAudioAggregateDeviceUIDKey: "app.nfm.audio." + UUID().uuidString,
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
        guard status == noErr else { teardown(); return .failure(.setupFailed(status)) }
        aggregateID = device

        let dsp = self.dsp
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue) { _, input, _, output, _ in
            dsp.process(input: input, output: output)
        }
        guard status == noErr, let procID else { teardown(); return .failure(.setupFailed(status)) }
        ioProcID = procID

        status = AudioDeviceStart(device, procID)
        guard status == noErr else { teardown(); return .failure(.setupFailed(status)) }

        installListeners()
        return .success
    }

    private func teardown() {
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
        tappedPIDs = []
    }

    /// Rebuild when the output device changes (headphones, AirPods) or when
    /// WebKit starts a new audio process.
    private func installListeners() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        let system = AudioObjectID(kAudioObjectSystemObject)

        var outputAddress = AudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(system, &outputAddress, queue) { [weak self] _, _ in
            self?.rebuildIfRunning(force: true)
        }
        var processAddress = AudioHelpers.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(system, &processAddress, queue) { [weak self] _, _ in
            self?.rebuildIfRunning(force: false)
        }
    }

    private func rebuildIfRunning(force: Bool) {
        guard tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        if !force && Set(AudioHelpers.ownAudioProcesses().map(\.pid)) == tappedPIDs { return }
        switch build() {
        case .success, .waitingForAudio: break
        case .failure(let failure): DispatchQueue.main.async { self.fail(failure) }
        }
    }

}

// MARK: - Signal processing (audio I/O thread)

/// The enhancer's signal chain, run per sample frame on the real-time audio
/// thread (no locks, no allocation once configured):
///
/// 1. Voice Boost (optional): +3 dB presence lift at 3 kHz for clearer
///    dialogue, then a gentle 3:1 compressor that lifts quiet speech.
/// 2. Loudness Match (optional): a running BS.1770 loudness estimate of the
///    programme sets a gain that brings it to the target (e.g. -16 LUFS),
///    capped by the measured headroom so the limiter rarely has anything to do.
///    Gain moves slowly (1 dB/s up, 3 dB/s down) so scenes never "pump".
/// 3. Extra boost (⌘↑ past 100%).
/// 4. Peak limiter at -1 dBFS plus a soft-clip safety net.
final class EnhancerDSP {
    // Controls: written on the main thread, read on the audio thread.
    var manualGain: Float = 1
    var voiceBoost = false
    var loudnessMatch = true
    var targetLUFS: Float = -16

    // Published for the UI: written on the audio thread.
    private(set) var signalTicks: UInt64 = 0
    private(set) var matchGainDB: Float = 0
    private(set) var measuredLUFS: Float = -70

    private struct Biquad {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var z1: Float = 0, z2: Float = 0
        mutating func run(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private static let maxChannels = 16
    private var sampleRate: Float = 48_000
    private var presence = [Biquad](repeating: Biquad(), count: maxChannels)
    private var shelf = [Biquad](repeating: Biquad(), count: maxChannels)
    private var highpass = [Biquad](repeating: Biquad(), count: maxChannels)
    private let frame = UnsafeMutablePointer<Float>.allocate(capacity: maxChannels)
    private var inputs = ContiguousArray<(UnsafeMutablePointer<Float>, Int)>()
    private var outputs = ContiguousArray<(UnsafeMutablePointer<Float>, Int)>()

    // Voice compressor
    private var envelope: Float = 0
    private var attack: Float = 0
    private var release: Float = 0
    private let threshold: Float = 0.05      // -26 dBFS
    private let ratio: Float = 3

    // Loudness measurement (100 ms blocks, 400 ms momentary window)
    private var blockFrames = 4_800
    private var framesInBlock = 0
    private var blockSum: Float = 0
    private var blockPeak: Float = 0
    private var window: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var windowIndex = 0
    private var windowFilled = 0
    private var programPower: Float = 0
    private var programBlocks = 0
    private var peakHold: Float = 0

    // Gain + limiter
    private var gain: Float = 1
    private var glide: Float = 0.0005
    private var limiterEnvelope: Float = 0
    private var limiterRelease: Float = 0.999
    private let ceiling: Float = 0.891       // -1 dBFS
    private static let maxTotalGain: Float = 7.94 // +18 dB

    init() {
        frame.initialize(repeating: 0, count: Self.maxChannels)
        inputs.reserveCapacity(Self.maxChannels)
        outputs.reserveCapacity(Self.maxChannels)
        configure(sampleRate: 48_000)
    }

    deinit { frame.deallocate() }

    /// Call while audio is stopped.
    func configure(sampleRate fs: Double) {
        sampleRate = Float(fs)
        let k = LoudnessMeter.kWeightingCoefficients(sampleRate: fs)
        let s = Biquad(b0: Float(k.shelf.0), b1: Float(k.shelf.1), b2: Float(k.shelf.2),
                       a1: Float(k.shelf.3), a2: Float(k.shelf.4))
        let h = Biquad(b0: Float(k.highpass.0), b1: Float(k.highpass.1), b2: Float(k.highpass.2),
                       a1: Float(k.highpass.3), a2: Float(k.highpass.4))
        shelf = [Biquad](repeating: s, count: Self.maxChannels)
        highpass = [Biquad](repeating: h, count: Self.maxChannels)
        presence = [Biquad](repeating: Self.peakingEQ(frequency: 3_000, gainDB: 3, q: 0.9, sampleRate: fs),
                            count: Self.maxChannels)
        attack = expf(-1 / (0.005 * sampleRate))
        release = expf(-1 / (0.200 * sampleRate))
        limiterRelease = expf(-1 / (0.080 * sampleRate))
        glide = 1 - expf(-1 / (0.050 * sampleRate))
        blockFrames = max(1, Int(sampleRate / 10))
        framesInBlock = 0
        blockSum = 0
        blockPeak = 0
        window = (0, 0, 0, 0)
        windowIndex = 0
        windowFilled = 0
        programPower = 0
        programBlocks = 0
        peakHold = 0
        envelope = 0
        limiterEnvelope = 0
    }

    /// Start from a known-good gain (the last one used) instead of 0 dB.
    func prime(gainDB: Float) {
        matchGainDB = loudnessMatch ? max(0, min(12, gainDB)) : 0
        gain = powf(10, matchGainDB / 20) * manualGain
    }

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        inputs.removeAll(keepingCapacity: true)
        outputs.removeAll(keepingCapacity: true)
        var inFrames = Int.max
        var outFrames = Int.max

        for buffer in inList {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            inFrames = min(inFrames, Int(buffer.mDataByteSize) / (4 * channels))
            for c in 0..<channels where inputs.count < Self.maxChannels { inputs.append((data + c, channels)) }
        }
        for buffer in outList {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            outFrames = min(outFrames, Int(buffer.mDataByteSize) / (4 * channels))
            for c in 0..<channels { outputs.append((data + c, channels)) }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
        guard !inputs.isEmpty, !outputs.isEmpty, inFrames != .max, outFrames != .max else { return }

        let frames = min(inFrames, outFrames)
        let inCount = inputs.count
        let voice = voiceBoost
        let match = loudnessMatch
        let makeup: Float = voice && !match ? 2.0 : 1.0   // Loudness Match does the level when it's on
        var heard = false

        for f in 0..<frames {
            // 1. Read + Voice Boost
            var peak: Float = 0
            for c in 0..<inCount {
                let (pointer, stride) = inputs[c]
                var x = pointer[f * stride]
                if x != 0 { heard = true }
                if voice { x = presence[c].run(x) }
                frame[c] = x
                peak = max(peak, abs(x))
            }
            var pre: Float = 1
            if voice {
                envelope = (peak > envelope ? attack : release) * (envelope - peak) + peak
                if envelope > threshold { pre = powf(envelope / threshold, 1 / ratio - 1) }
                pre *= makeup
            }

            // 2. Measure programme loudness (before the match gain)
            if match {
                var power: Float = 0
                for c in 0..<inCount {
                    let k = highpass[c].run(shelf[c].run(frame[c] * pre))
                    power += k * k
                }
                blockSum += power
                blockPeak = max(blockPeak, peak * pre)
                framesInBlock += 1
                if framesInBlock == blockFrames { finishBlock() }
            }

            // 3. Gain (glides towards match gain × extra boost, never more than +18 dB in total)
            let target = min(Self.maxTotalGain, (match ? powf(10, matchGainDB / 20) : 1) * manualGain)
            gain += (target - gain) * glide
            let g = pre * gain

            // 4. Limiter
            var outPeak: Float = 0
            for c in 0..<inCount {
                let y = frame[c] * g
                frame[c] = y
                outPeak = max(outPeak, abs(y))
            }
            limiterEnvelope = outPeak > limiterEnvelope
                ? outPeak
                : limiterRelease * (limiterEnvelope - outPeak) + outPeak
            let reduction: Float = limiterEnvelope > ceiling ? ceiling / limiterEnvelope : 1

            for o in 0..<outputs.count {
                let (out, stride) = outputs[o]
                out[f * stride] = Self.softClip(frame[o % inCount] * reduction)
            }
        }
        if heard { signalTicks &+= 1 }
    }

    /// Every 100 ms: update the programme loudness estimate and the match gain.
    private func finishBlock() {
        let power = blockSum / Float(blockFrames)
        let peak = blockPeak
        blockSum = 0
        blockPeak = 0
        framesInBlock = 0

        switch windowIndex {
        case 0: window.0 = power
        case 1: window.1 = power
        case 2: window.2 = power
        default: window.3 = power
        }
        windowIndex = (windowIndex + 1) % 4
        windowFilled = min(4, windowFilled + 1)
        guard windowFilled == 4 else { return }
        let momentary = (window.0 + window.1 + window.2 + window.3) / 4
        let momentaryLUFS = Self.lufs(momentary)

        // Headroom: hold recent peaks, letting them fall 1 dB per 10 s.
        peakHold = max(peak, peakHold * 0.99885)

        // Gates (BS.1770 style): ignore silence and passages far below the programme.
        guard momentaryLUFS > -70 else { return }
        if programBlocks > 0 && momentaryLUFS < measuredLUFS - 20 { return }

        // Running mean for the first 30 s, then a slow (15 s) moving average.
        programBlocks += 1
        let alpha = programBlocks < 300 ? 1 / Float(programBlocks) : 1 - expf(-0.1 / 15)
        programPower += (momentary - programPower) * alpha
        measuredLUFS = Self.lufs(programPower)

        var desired = targetLUFS - measuredLUFS
        if peakHold > 0 {
            let headroom = 20 * log10f(ceiling / peakHold)
            desired = min(desired, headroom + 3) // the limiter may shave rare peaks by up to 3 dB
        }
        desired = max(0, min(12, desired))
        let step = desired - matchGainDB
        matchGainDB += max(-0.3, min(0.1, step)) // 3 dB/s down, 1 dB/s up
    }

    @inline(__always)
    private static func lufs(_ power: Float) -> Float {
        power > 0 ? -0.691 + 10 * log10f(power) : -100
    }

    /// Transparent below -0.4 dBFS; only catches what the limiter's attack misses.
    @inline(__always)
    private static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.95
        let a = abs(x)
        if a <= knee { return x }
        let y = knee + (1 - knee) * tanhf((a - knee) / (1 - knee))
        return x < 0 ? -y : y
    }

    /// RBJ cookbook peaking EQ.
    private static func peakingEQ(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha / a
        return Biquad(b0: Float((1 + alpha * a) / a0),
                      b1: Float((-2 * cos(w0)) / a0),
                      b2: Float((1 - alpha * a) / a0),
                      a1: Float((-2 * cos(w0)) / a0),
                      a2: Float((1 - alpha / a) / a0))
    }
}

// MARK: - Self-check (used by CI)

extension EnhancerDSP {
    /// Runs synthetic programmes through the enhancer and reports the results.
    /// - A steady tone at -26 LUFS with Loudness Match (target -16) must settle
    ///   at about +10 dB and come out at about -16 LUFS.
    /// - A loud tone pushed +12 dB by extra boost must never exceed full scale.
    static func calibrationReport() -> [String: Double] {
        func run(amplitude: Float, seconds: Int, match: Bool, manualGain: Float,
                 measureFrom: Int) -> (gain: Double, lufs: Double, peak: Double) {
            let fs = 48_000.0
            let dsp = EnhancerDSP()
            dsp.loudnessMatch = match
            dsp.targetLUFS = -16
            dsp.manualGain = manualGain
            dsp.configure(sampleRate: fs)
            dsp.prime(gainDB: 0)

            let frames = 512
            let input = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            let output = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            defer { input.deallocate(); output.deallocate() }
            let inList = AudioBufferList.allocate(maximumBuffers: 1)
            let outList = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer) }
            inList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: input)
            outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: output)

            let meter = LoudnessMeter(sampleRate: fs)
            var peak: Float = 0
            var phase = 0.0
            let step = 2 * Double.pi * 997 / fs
            let blocks = Int(fs) * seconds / frames
            let startMeasuring = Int(fs) * measureFrom / frames
            for block in 0..<blocks {
                for i in 0..<frames {
                    let s = amplitude * Float(sin(phase))
                    phase += step
                    input[2 * i] = s
                    input[2 * i + 1] = s
                }
                dsp.process(input: UnsafePointer(inList.unsafeMutablePointer), output: outList.unsafeMutablePointer)
                guard block >= startMeasuring else { continue }
                for i in 0..<frames * 2 { peak = max(peak, abs(output[i])) }
                let channels = [(output, 2), (output + 1, 2)]
                channels.withUnsafeBufferPointer { meter.process($0, frames: frames) }
            }
            return (Double(dsp.matchGainDB), meter.snapshot().integrated ?? -999, Double(peak))
        }

        let quiet = run(amplitude: 0.05, seconds: 40, match: true, manualGain: 1, measureFrom: 25)
        let loud = run(amplitude: 0.5, seconds: 5, match: false, manualGain: 4, measureFrom: 1)
        return [
            "match_gain_db": quiet.gain,
            "match_output_lufs": quiet.lufs,
            "match_output_peak": quiet.peak,
            "limiter_output_peak": loud.peak,
        ]
    }
}
