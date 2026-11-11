import AppKit
import SwiftUI

// MARK: - Page info

/// What the Netflix page reports about its audio (from nfm.js `audioInfo`).
struct PageAudioInfo {
    var watching = false
    var playing = false
    var netflixVolume: Double?
    var netflixMuted: Bool?
    var elementVolume: Double?
    var elementMuted: Bool?
    var formats: [String] = []
    var track: [String: String] = [:]

    init() {}

    init(_ dict: [String: Any]) {
        watching = dict["watching"] as? Bool ?? false
        playing = dict["playing"] as? Bool ?? false
        netflixVolume = (dict["netflixVolume"] as? NSNumber)?.doubleValue
        netflixMuted = dict["netflixMuted"] as? Bool
        elementVolume = (dict["elementVolume"] as? NSNumber)?.doubleValue
        elementMuted = dict["elementMuted"] as? Bool
        formats = dict["formats"] as? [String] ?? []
        if let raw = dict["audioTrack"] as? [String: Any] {
            track = raw.mapValues { "\($0)" }
        }
    }

    var audioFormat: String? { formats.last { $0.lowercased().hasPrefix("audio") } }

    /// "AAC-LC", "Dolby Digital Plus (E-AC-3)", …
    var codecName: String? {
        guard let format = audioFormat?.lowercased() else { return nil }
        if format.contains("ec-3") { return "Dolby Digital Plus (E-AC-3)" }
        if format.contains("ac-3") { return "Dolby Digital (AC-3)" }
        if format.contains("mp4a.40.42") { return "xHE-AAC" }
        if format.contains("mp4a.40.5") || format.contains("mp4a.40.29") { return "HE-AAC" }
        if format.contains("mp4a.40.2") { return "AAC-LC" }
        if format.contains("opus") { return "Opus" }
        return format
    }

    /// The channel layout if Netflix's player exposes it (e.g. "2.0", "5.1").
    var channels: String? {
        track.first { $0.key.lowercased().contains("channel") }?.value
    }

    /// Effective attenuation applied inside the page, in dB (0 = none).
    var pageAttenuation: Double? {
        let volume = (netflixVolume ?? 1) * (elementVolume ?? 1)
        guard volume > 0 else { return nil }
        return 20 * log10(volume)
    }
}

// MARK: - Findings

struct AudioFinding: Identifiable {
    enum Kind { case ok, info, issue }
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String

    var symbol: String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .issue: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch kind {
        case .ok: return .green
        case .info: return .blue
        case .issue: return .orange
        }
    }
}

enum AudioFindings {
    static let reference = -14.0   // YouTube / Spotify
    static let minimumSeconds = 20.0

    static func make(snapshot: LoudnessMeter.Snapshot, page: PageAudioInfo,
                     device: AudioHelpers.OutputDeviceInfo?, enhancer: AudioEnhancer.Status?) -> [AudioFinding] {
        var out: [AudioFinding] = []

        // 1. Attenuation inside Netflix's player.
        if page.netflixMuted == true || page.elementMuted == true {
            out.append(.init(kind: .issue, title: "Netflix is muted",
                             detail: "The player itself is muted. Unmute it in the player or with ⌥⌘↓."))
        } else if let attenuation = page.pageAttenuation, attenuation < -0.5 {
            let percent = Int(((page.netflixVolume ?? 1) * (page.elementVolume ?? 1) * 100).rounded())
            out.append(.init(kind: .issue, title: "Netflix’s own volume is at \(percent)%",
                             detail: String(format: "That lowers everything by %.1f dB before macOS gets it. "
                                 + "Drag Netflix’s volume slider to the top or press ⌘↑ until it says 100%%.", -attenuation)))
        } else if page.netflixVolume != nil {
            out.append(.init(kind: .ok, title: "Netflix’s own volume is at 100%",
                             detail: "The player isn’t turning anything down."))
        }

        // 2. What Netflix is streaming.
        if let codec = page.codecName {
            let channels = page.channels.map { " \($0)" } ?? ""
            do {
                let heaac = codec == "HE-AAC" || codec == "xHE-AAC"
                out.append(.init(kind: .info, title: "Streaming \(codec)\(channels.isEmpty ? " (stereo)" : channels)",
                                 detail: (heaac
                                     ? "HE-AAC rebuilds the high frequencies from a compact description, which can make "
                                         + "voices sound slightly dull. "
                                     : "")
                                     + (Prefs.voiceBoost
                                         ? "Voice Boost is on to keep dialogue clear."
                                         : "If voices sound dull, try Voice Boost (⌥⌘B).")))
            }
        }

        // 3. Measured loudness and dynamics.
        if snapshot.seconds < minimumSeconds {
            out.append(.init(kind: .info, title: "Keep it playing",
                             detail: String(format: "%.0f of %.0f seconds measured. Play a scene with talking and some "
                                 + "action for the most useful reading.", snapshot.seconds, minimumSeconds)))
            return out
        }

        if let integrated = snapshot.integrated, let peak = snapshot.samplePeak, integrated > -10 || peak > -0.1 {
            out.append(.init(kind: .issue, title: "These readings look wrong",
                             detail: String(format: "%.1f LUFS with peaks at %+.1f dBFS is far louder than any Netflix "
                                 + "mix. Something else is being measured along with Netflix. Click Start Over; if it "
                                 + "repeats, please send this report.", integrated, peak)))
            return out
        }

        if let integrated = snapshot.integrated {
            let gap = reference - integrated
            if gap >= 6 {
                out.append(.init(kind: .issue, title: String(format: "Mixed %.0f dB quieter than YouTube or Spotify", gap),
                                 detail: String(format: "Average loudness is %.1f LUFS against about -14 LUFS for "
                                     + "YouTube and Spotify. That matches Netflix’s published target of -27 LKFS for "
                                     + "dialogue: the quietness is in the mix itself, before your Mac’s volume.", integrated)))
            } else {
                out.append(.init(kind: .ok, title: String(format: "Loudness is normal (%.1f LUFS)", integrated),
                                 detail: "The sound leaving Netflix is not unusually quiet. If it still sounds low, the "
                                     + "loss is after NFM: check the output device below."))
            }
        }

        if let peak = snapshot.samplePeak, let integrated = snapshot.integrated {
            let plr = peak - integrated
            if snapshot.ceilingShare > 0.15 && plr < 12 {
                out.append(.init(kind: .issue, title: String(format: "Peaks are pinned at %.1f dBFS", peak),
                                 detail: String(format: "%.0f%% of loud moments hit the same ceiling and the "
                                     + "peak-to-loudness ratio is only %.1f dB. Something in the chain is limiting.",
                                     snapshot.ceilingShare * 100, plr)))
            } else {
                var detail = String(format: "Loudest peak %.1f dBFS, so %.1f dB of headroom goes unused. "
                    + "Peak-to-loudness ratio %.1f dB", peak, -peak, plr)
                if let range = snapshot.range { detail += String(format: ", loudness range %.1f LU", range) }
                detail += ". That’s a wide, uncompressed film mix: quiet dialogue with room for loud scenes, not a limiter."
                out.append(.init(kind: .ok, title: "No sign of limiting or compression", detail: detail))
            }
        }

        // 4. After NFM: the output device.
        if let device {
            if device.muted == true {
                out.append(.init(kind: .issue, title: "\(device.name) is muted", detail: "Unmute it in Control Center."))
            } else if let volume = device.volume, volume < 0.5 {
                out.append(.init(kind: .info, title: "\(device.name) volume is \(Int(volume * 100))%",
                                 detail: "Your Mac’s output volume is under half."))
            }
            if device.isBluetooth {
                out.append(.init(kind: .info, title: "Listening on Bluetooth (\(device.name))",
                                 detail: "AirPods and Beats can lower loud audio: check System Settings ▸ Sound ▸ "
                                     + "Headphone Safety and the headphones’ own settings."))
            }
        }

        // 5. What NFM is doing about it.
        if let enhancer, enhancer.running {
            var parts: [String] = []
            if enhancer.loudnessMatch {
                parts.append(String(format: "Loudness Match is adding %+.1f dB (target %ld LUFS)", enhancer.addedGainDB,
                                    enhancer.targetLUFS))
            }
            if enhancer.voiceBoost { parts.append("Voice Boost is on") }
            if enhancer.extraBoost > 100 { parts.append("extra boost \(enhancer.extraBoost)%") }
            out.append(.init(kind: .ok, title: parts.first ?? "Audio enhancements are on",
                             detail: (parts.dropFirst().joined(separator: ", ") + (parts.count > 1 ? ". " : ""))
                                 + "The readings above are Netflix’s own level, measured before NFM’s processing."))
        } else if !AudioEnhancer.isRequested {
            out.append(.init(kind: .info, title: "Loudness Match is off",
                             detail: "Turn it on in Playback ▸ Sound to bring Netflix up to the level of other apps."))
        }

        // 6. Speakers with their own volume.
        if let device, device.volume ?? 0 >= 0.99, !device.isBluetooth, device.transport != "Built-in" {
            out.append(.init(kind: .info, title: "Your Mac is at full volume for \(device.name)",
                             detail: "macOS can’t go any louder. External speakers usually have their own volume "
                                 + "knob, and some play louder depending on how they’re powered, so check the "
                                 + "speaker’s knob and the maker’s power guidance."))
        }
        return out
    }
}

// MARK: - Model

final class AudioDiagnosticsModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waiting(String)
        case measuring
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var snapshot = LoudnessMeter.Snapshot()
    @Published private(set) var page = PageAudioInfo()
    @Published private(set) var device: AudioHelpers.OutputDeviceInfo?
    @Published private(set) var findings: [AudioFinding] = []

    private let tap = AudioTapMeter()
    private weak var browser: BrowserWindowController?
    private var timer: Timer?
    private var tick = 0
    private var silentPlayingTicks = 0

    init(browser: BrowserWindowController) {
        self.browser = browser
    }

    var isActive: Bool { timer != nil }

    var enhancerSummary: String {
        guard Prefs.loudnessMatch else { return "Off" }
        guard let status = browser?.audioStatus, status.running else { return "On · waiting for playback" }
        return String(format: "Adding %+.1f dB · target %ld LUFS", status.addedGainDB, status.targetLUFS)
    }

    func start() {
        guard timer == nil else { return }
        tap.meter.reset()
        snapshot = LoudnessMeter.Snapshot()
        silentPlayingTicks = 0
        phase = .waiting("Play something on Netflix…")
        refreshPageAndDevice()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.step() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tap.stop()
        if case .measuring = phase { phase = .idle }
        if case .waiting = phase { phase = .idle }
    }

    func restart() {
        stop()
        start()
    }

    private func step() {
        tick += 1
        if tick % 2 == 0 { refreshPageAndDevice() }

        if !tap.isRunning {
            guard page.playing else {
                phase = .waiting(page.watching ? "Press play to start measuring…" : "Open a title and press play…")
                return
            }
            switch tap.start() {
            case .success:
                phase = .measuring
            case .failure(.noAudioProcesses):
                phase = .waiting("Waiting for Netflix’s audio to start…")
                return
            case .failure(.setupFailed(let status)):
                phase = .failed("macOS refused the audio tap (error \(status)).")
                stop()
                return
            }
        }

        snapshot = tap.meter.snapshot()
        if page.playing && page.netflixMuted != true && !snapshot.hasSignal {
            silentPlayingTicks += 1
            if silentPlayingTicks >= 16 {
                phase = .failed("NFM couldn’t hear Netflix’s audio. Allow NFM in System Settings ▸ Privacy & Security ▸ "
                    + "Screen & System Audio Recording, then measure again.")
                stop()
                return
            }
        }
        findings = AudioFindings.make(snapshot: snapshot, page: page, device: device, enhancer: browser?.audioStatus)
    }

    private func refreshPageAndDevice() {
        device = AudioHelpers.outputDeviceInfo()
        browser?.bridge.run("audioInfo") { [weak self] result in
            guard let dict = result as? [String: Any] else { return }
            self?.page = PageAudioInfo(dict)
        }
    }

    // MARK: Report

    func report() -> String {
        func db(_ value: Double?, _ unit: String) -> String {
            guard let value, value.isFinite else { return "—" }
            return String(format: "%.1f %@", value, unit)
        }
        var lines = [
            "NFM Audio Diagnostics",
            "NFM \(AppInfo.versionLabel) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "",
            "Loudness (ITU-R BS.1770)",
            "  Measured: \(String(format: "%.0f s", snapshot.seconds))",
            "  Integrated: \(db(snapshot.integrated, "LUFS"))",
            "  Short-term: \(db(snapshot.shortTerm, "LUFS"))",
            "  Loudness range: \(db(snapshot.range, "LU"))",
            "  Sample peak: \(db(snapshot.samplePeak, "dBFS"))",
            "  Peaks at ceiling: \(String(format: "%.1f%%", snapshot.ceilingShare * 100))",
            "",
            "Netflix stream",
            "  Codec: \(page.codecName ?? "—")  [\(page.audioFormat ?? "—")]",
            "  Channels: \(page.channels ?? "—")",
            "  Netflix volume: \(page.netflixVolume.map { String(format: "%.0f%%", $0 * 100) } ?? "—")"
                + (page.netflixMuted == true ? " (muted)" : ""),
            "  Element volume: \(page.elementVolume.map { String(format: "%.0f%%", $0 * 100) } ?? "—")"
                + (page.elementMuted == true ? " (muted)" : ""),
            "  Track: \(page.track.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))",
            "",
            "Output",
        ]
        if let device {
            lines += [
                "  Device: \(device.name) (\(device.transport))",
                "  Channels: \(device.channels) · \(String(format: "%.0f Hz", device.sampleRate))",
                "  Volume: \(device.volume.map { String(format: "%.0f%%", $0 * 100) } ?? "—")"
                    + (device.muted == true ? " (muted)" : ""),
            ]
        } else {
            lines.append("  —")
        }
        let status = browser?.audioStatus
        lines.append("  Loudness Match: " + (Prefs.loudnessMatch
            ? String(format: "on, target %ld LUFS, adding %+.1f dB%@", Prefs.loudnessTarget, status?.addedGainDB ?? 0,
                     status?.running == true ? "" : " (not running)")
            : "off"))
        lines.append("  Voice Boost: \(Prefs.voiceBoost ? "on" : "off") · Extra boost: \(Prefs.soundBoost)%")
        lines.append("")
        lines.append("Findings")
        for finding in findings {
            let mark = finding.kind == .issue ? "!" : (finding.kind == .ok ? "✓" : "·")
            lines.append("  \(mark) \(finding.title): \(finding.detail)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - View

struct AudioDiagnosticsView: View {
    @ObservedObject var model: AudioDiagnosticsModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    loudness
                    Divider()
                    details
                    Divider()
                    findingsList
                }
                .padding(.trailing, 6)
            }
            footer
        }
        .padding(22)
        .frame(width: 600, height: 760)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio Diagnostics").font(.title2.bold())
            Text("Measures Netflix’s sound as it leaves the player, using the same loudness standard Netflix uses. "
                 + "It only listens: what you hear doesn’t change. Play a scene with talking and some action for about a minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                statusIcon
                Text(statusText).font(.callout.weight(.medium))
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch model.phase {
        case .measuring: Image(systemName: "waveform").foregroundStyle(.green)
        case .waiting: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: Image(systemName: "pause.circle").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle: return "Not measuring"
        case .waiting(let message): return message
        case .measuring: return String(format: "Measuring · %.0f s of audio", model.snapshot.seconds)
        case .failed(let message): return message
        }
    }

    private var loudness: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                bigReading("Integrated", model.snapshot.integrated, "LUFS")
                bigReading("Short-term", model.snapshot.shortTerm, "LUFS")
                bigReading("Peak", model.snapshot.samplePeak, "dBFS")
                bigReading("Range", model.snapshot.range, "LU")
            }
            LoudnessScale(integrated: model.snapshot.integrated, momentary: model.snapshot.momentary)
                .frame(height: 54)
        }
    }

    private func bigReading(_ label: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.flatMap { $0.isFinite ? String(format: "%.1f", $0) : nil } ?? "—")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Netflix stream", model.page.codecName.map { codec in
                codec + (model.page.channels.map { " · \($0)" } ?? "")
            } ?? "—")
            row("Netflix volume", percent(model.page.netflixVolume) + (model.page.netflixMuted == true ? " (muted)" : ""))
            row("Output", model.device.map { "\($0.name) · \($0.transport) · \($0.channels) ch" } ?? "—")
            row("Output volume", percent(model.device?.volume) + (model.device?.muted == true ? " (muted)" : ""))
            row("Loudness Match", model.enhancerSummary)
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    private var findingsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Findings").font(.headline)
            if model.findings.isEmpty {
                Text("Findings appear once Netflix is playing.").foregroundStyle(.secondary)
            }
            ForEach(model.findings) { finding in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: finding.symbol).foregroundStyle(finding.color).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(finding.title).font(.callout.weight(.semibold))
                        Text(finding.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.isActive {
                Button("Stop") { model.stop() }
            } else {
                Button("Start Measuring") { model.start() }.keyboardShortcut(.defaultAction)
            }
            Button("Start Over") { model.restart() }
            Spacer()
            Button(copied ? "Copied" : "Copy Report") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.report(), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            }
        }
    }
}

/// A -50…0 LUFS scale with markers for Netflix’s dialogue target and typical
/// music/video apps, plus the live momentary level and the integrated value.
private struct LoudnessScale: View {
    let integrated: Double?
    let momentary: Double?

    private let low = -50.0
    private let high = 0.0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Capsule().fill(.quaternary).frame(height: 10).offset(y: 16)
                if let momentary, momentary.isFinite {
                    Capsule().fill(.green.opacity(0.75))
                        .frame(width: max(4, x(momentary, width)), height: 10).offset(y: 16)
                }
                marker("Netflix −27", -27, width, .secondary)
                marker("TV −24", -24, width, .secondary)
                marker("YouTube −14", -14, width, .secondary)
                if let integrated, integrated.isFinite {
                    Rectangle().fill(.primary).frame(width: 3, height: 22).offset(x: x(integrated, width) - 1.5, y: 10)
                }
            }
        }
    }

    private func x(_ value: Double, _ width: CGFloat) -> CGFloat {
        CGFloat((min(high, max(low, value)) - low) / (high - low)) * width
    }

    private func marker(_ label: String, _ value: Double, _ width: CGFloat, _ style: HierarchicalShapeStyle) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(style).fixedSize()
            Rectangle().fill(style).frame(width: 1, height: 26)
        }
        .offset(x: x(value, width) - 24, y: -12)
        .frame(width: 48, alignment: .center)
    }
}

final class AudioDiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AudioDiagnosticsModel

    init(browser: BrowserWindowController) {
        model = AudioDiagnosticsModel(browser: browser)
        let window = NSWindow(contentViewController: NSHostingController(rootView: AudioDiagnosticsView(model: model)))
        window.title = "Audio Diagnostics"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.start()
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}
