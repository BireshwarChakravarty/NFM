import Foundation
import os

/// ITU-R BS.1770-4 / EBU R128 loudness meter.
///
/// `process` runs on the real-time audio thread (K-weighting + 100 ms
/// blocks); `snapshot()` is called from the main thread and derives
/// momentary, short-term and integrated loudness, loudness range, sample peak
/// and a "limiter signature" from the stored blocks.
final class LoudnessMeter {
    struct Snapshot {
        var seconds: Double = 0            // measured audio with signal
        var momentary: Double? = nil       // LUFS, last 400 ms
        var shortTerm: Double? = nil       // LUFS, last 3 s
        var integrated: Double? = nil      // LUFS, gated
        var range: Double? = nil           // LU (EBU Tech 3342)
        var samplePeak: Double? = nil      // dBFS, whole measurement
        var ceilingShare: Double = 0       // share of loud blocks with a peak within 0.5 dB of the max
        var hasSignal = false
    }

    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private struct Block { var power: Double; var peak: Float }

    private var sampleRate: Double
    private var shelf: [Biquad] = []
    private var highpass: [Biquad] = []
    private var channelCount = 0

    // Audio-thread accumulation for the current 100 ms block.
    private var blockFrames = 0
    private var framesInBlock = 0
    private var blockSum = 0.0
    private var blockPeak: Float = 0

    private let blocks = OSAllocatedUnfairLock(initialState: [Block]())

    init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        configure(sampleRate: sampleRate, channels: 2)
    }

    /// Call before audio starts (not from the audio thread while running).
    func configure(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        channelCount = channels
        blockFrames = max(1, Int(sampleRate / 10))
        let (s, h) = Self.kWeighting(sampleRate: sampleRate)
        shelf = Array(repeating: s, count: channels)
        highpass = Array(repeating: h, count: channels)
        framesInBlock = 0
        blockSum = 0
        blockPeak = 0
    }

    func reset() {
        blocks.withLock { $0.removeAll(keepingCapacity: true) }
        configure(sampleRate: sampleRate, channels: channelCount)
    }

    /// `channels`: one (pointer, stride) per channel, all with `frames` samples.
    func process(_ channels: UnsafeBufferPointer<(UnsafeMutablePointer<Float>, Int)>, frames: Int) {
        let count = min(channels.count, channelCount)
        guard count > 0 else { return }
        for frame in 0..<frames {
            var power = 0.0
            for c in 0..<count {
                let (pointer, stride) = channels[c]
                let x = pointer[frame * stride]
                let mag = abs(x)
                if mag > blockPeak { blockPeak = mag }
                let y = highpass[c].run(shelf[c].run(Double(x)))
                power += y * y // stereo channel weights are 1.0
            }
            blockSum += power
            framesInBlock += 1
            if framesInBlock == blockFrames {
                let block = Block(power: blockSum / Double(blockFrames), peak: blockPeak)
                blocks.withLock { $0.append(block) }
                framesInBlock = 0
                blockSum = 0
                blockPeak = 0
            }
        }
    }

    func snapshot() -> Snapshot {
        let all = blocks.withLock { $0 }
        var snap = Snapshot()
        guard !all.isEmpty else { return snap }

        // 400 ms gating blocks with 75 % overlap = sliding window of 4 sub-blocks.
        func windowLoudness(endingAt end: Int, length: Int) -> Double? {
            guard end + 1 >= length else { return nil }
            var sum = 0.0
            for i in (end - length + 1)...end { sum += all[i].power }
            return Self.lufs(sum / Double(length))
        }

        // Below the -70 LUFS gate is silence: report nothing rather than -300 LUFS.
        snap.momentary = windowLoudness(endingAt: all.count - 1, length: 4).flatMap { $0 > -70 ? $0 : nil }
        snap.shortTerm = windowLoudness(endingAt: all.count - 1, length: 30).flatMap { $0 > -70 ? $0 : nil }

        var gating: [Double] = []        // powers of 400 ms blocks
        var shortTerms: [Double] = []    // LUFS of 3 s blocks, every 100 ms
        if all.count >= 4 {
            for end in 3..<all.count {
                var sum = 0.0
                for i in (end - 3)...end { sum += all[i].power }
                gating.append(sum / 4)
            }
        }
        if all.count >= 30 {
            for end in 29..<all.count {
                if let st = windowLoudness(endingAt: end, length: 30) { shortTerms.append(st) }
            }
        }

        // Integrated: absolute gate -70 LUFS, then relative gate -10 LU.
        let absGated = gating.filter { Self.lufs($0) > -70 }
        if !absGated.isEmpty {
            let relativeGate = Self.lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
            let relGated = absGated.filter { Self.lufs($0) > relativeGate }
            if !relGated.isEmpty {
                snap.integrated = Self.lufs(relGated.reduce(0, +) / Double(relGated.count))
            }
        }

        // Loudness range: short-term values, gates -70 LUFS and -20 LU, 10th–95th percentile.
        let stAbs = shortTerms.filter { $0 > -70 }
        if stAbs.count >= 10 {
            let meanPower = stAbs.map { pow(10, ($0 + 0.691) / 10) }.reduce(0, +) / Double(stAbs.count)
            let gate = Self.lufs(meanPower) - 20
            let sorted = stAbs.filter { $0 > gate }.sorted()
            if sorted.count >= 10 {
                let lo = sorted[Int(Double(sorted.count - 1) * 0.10)]
                let hi = sorted[Int(Double(sorted.count - 1) * 0.95)]
                snap.range = hi - lo
            }
        }

        // Peaks and the limiter signature.
        let loud = all.filter { Self.lufs($0.power) > -70 }
        snap.hasSignal = !loud.isEmpty
        snap.seconds = Double(loud.count) / 10
        let maxPeak = all.map(\.peak).max() ?? 0
        if maxPeak > 0 {
            snap.samplePeak = 20 * log10(Double(maxPeak))
            let threshold = maxPeak * powf(10, -0.5 / 20)
            let pinned = loud.filter { $0.peak >= threshold }.count
            snap.ceilingShare = loud.isEmpty ? 0 : Double(pinned) / Double(loud.count)
        }
        return snap
    }

    static func lufs(_ power: Double) -> Double {
        power > 0 ? -0.691 + 10 * log10(power) : -.infinity
    }

    typealias Coefficients = (Double, Double, Double, Double, Double) // b0, b1, b2, a1, a2

    /// BS.1770 K-weighting filters for any sample rate (pre-filter shelf + RLB high-pass).
    static func kWeightingCoefficients(sampleRate fs: Double) -> (shelf: Coefficients, highpass: Coefficients) {
        var f0 = 1681.974450955533
        let gain = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf: Coefficients = ((vh + vb * k / q + k * k) / a0,
                                   2 * (k * k - vh) / a0,
                                   (vh - vb * k / q + k * k) / a0,
                                   2 * (k * k - 1) / a0,
                                   (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highpass: Coefficients = (1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
        return (shelf, highpass)
    }

    private static func kWeighting(sampleRate fs: Double) -> (Biquad, Biquad) {
        let c = kWeightingCoefficients(sampleRate: fs)
        return (Biquad(b0: c.shelf.0, b1: c.shelf.1, b2: c.shelf.2, a1: c.shelf.3, a2: c.shelf.4),
                Biquad(b0: c.highpass.0, b1: c.highpass.1, b2: c.highpass.2, a1: c.highpass.3, a2: c.highpass.4))
    }

    // MARK: Self-check (used by CI)

    /// Feeds calibrated sine waves through the meter and returns the readings.
    /// A 997 Hz sine at -20 dBFS in both channels must read -20.0 LUFS; in one
    /// channel only, -23.0 LUFS.
    static func calibrationReport() -> [String: Double] {
        func measure(amplitude: Float, rightChannel: Bool, sampleRate: Double) -> Snapshot {
            let meter = LoudnessMeter(sampleRate: sampleRate)
            let frames = 512
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            var phase = 0.0
            let step = 2 * Double.pi * 997 / sampleRate
            for _ in 0..<Int(sampleRate * 10) / frames {
                for i in 0..<frames {
                    let s = amplitude * Float(sin(phase))
                    phase += step
                    left[i] = s
                    right[i] = rightChannel ? s : 0
                }
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        let channels = [(l.baseAddress!, 1), (r.baseAddress!, 1)]
                        channels.withUnsafeBufferPointer { meter.process($0, frames: frames) }
                    }
                }
            }
            return meter.snapshot()
        }
        let stereo48 = measure(amplitude: 0.1, rightChannel: true, sampleRate: 48_000)
        let mono48 = measure(amplitude: 0.1, rightChannel: false, sampleRate: 48_000)
        let stereo44 = measure(amplitude: 0.1, rightChannel: true, sampleRate: 44_100)
        return [
            "stereo48_integrated": stereo48.integrated ?? -999,
            "mono48_integrated": mono48.integrated ?? -999,
            "stereo44_integrated": stereo44.integrated ?? -999,
            "stereo48_peak": stereo48.samplePeak ?? -999,
            "stereo48_range": stereo48.range ?? -999,
        ]
    }
}
