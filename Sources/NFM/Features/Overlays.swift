import AppKit

// MARK: - HUD

/// A QuickTime-style bezel ("1.5×", "Volume 60%", "Skipped Intro") that fades out.
final class HUDView: NSGlassEffectView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let content = NSView()
        contentView = content
        cornerRadius = 24
        appearance = NSAppearance(named: .darkAqua)
        alphaValue = 0
        translatesAutoresizingMaskIntoConstraints = false

        icon.symbolConfiguration = .init(pointSize: 30, weight: .semibold)
        icon.contentTintColor = .white
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.alignment = .center

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            heightAnchor.constraint(equalToConstant: 110),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func flash(symbol: String, text: String) {
        guard Prefs.showHUD else { return }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        label.stringValue = text
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                self?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}

// MARK: - Loading & error

/// Shown until Netflix has painted its first page, and when it can't be reached.
final class StatusOverlayView: NSView {
    enum Mode { case loading, error(String) }

    var onRetry: (() -> Void)?

    private let spinner = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "Try Again", target: nil, action: nil)
    private let mark = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        mark.image = NSApp.applicationIconImage
        mark.imageScaling = .scaleProportionallyUpOrDown
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.appearance = NSAppearance(named: .darkAqua)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = NSColor(white: 1, alpha: 0.6)
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 380
        retry.bezelStyle = .rounded
        retry.controlSize = .large
        retry.keyEquivalent = "\r"
        retry.target = self
        retry.action = #selector(retryPressed)

        let stack = NSStackView(views: [mark, spinner, title, detail, retry])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 96),
            mark.heightAnchor.constraint(equalToConstant: 96),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        show(.loading)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { true }

    func show(_ mode: Mode) {
        switch mode {
        case .loading:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            title.isHidden = true
            detail.isHidden = true
            retry.isHidden = true
        case .error(let message):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            title.isHidden = false
            title.stringValue = "Can’t reach Netflix"
            detail.isHidden = false
            detail.stringValue = message
            retry.isHidden = false
        }
    }

    @objc private func retryPressed() { onRetry?() }
}

// MARK: - Quick search

/// ⌘K / ⌘F / ⌘L: a Spotlight-style field over the window. Type to search
/// Netflix, or paste a Netflix link / title ID to open it.
final class QuickSearchView: NSGlassEffectView, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    let field = NSTextField()
    private(set) var isPresented = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let content = NSView()
        contentView = content
        cornerRadius = 30
        appearance = NSAppearance(named: .darkAqua)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")!)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.contentTintColor = NSColor(white: 1, alpha: 0.7)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.textColor = .white
        field.placeholderString = "Search Netflix, or paste a link"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true

        let stack = NSStackView(views: [icon, field])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            heightAnchor.constraint(equalToConstant: 60),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present(prefill: String? = nil) {
        if let prefill { field.stringValue = prefill }
        isPresented = true
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isPresented else { return }
            self.isHidden = true
        })
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onSubmit?(text) }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking back into the page dismisses the bar.
        if isPresented { onCancel?() }
    }
}

// MARK: - Mini player controls

/// Covers the web view while in the mini player: it owns the mouse (so the
/// window can be dragged anywhere and Netflix's own controls stay hidden) and
/// shows a compact set of controls on hover.
final class MiniPlayerOverlayView: NSView {
    var onCommand: ((String) -> Void)?

    private let controls = NSGlassEffectView()
    private let controlsContent = NSView()
    private let playButton = MiniPlayerOverlayView.makeButton("pause.fill", size: 22)
    private let progress = NSProgressIndicator()
    private var tracking: NSTrackingArea?
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        controls.contentView = controlsContent
        controls.cornerRadius = 22
        controls.appearance = NSAppearance(named: .darkAqua)
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.alphaValue = 0

        let back = Self.makeButton("gobackward.10", size: 17)
        let forward = Self.makeButton("goforward.10", size: 17)
        let next = Self.makeButton("forward.end.fill", size: 15)
        let expand = Self.makeButton("arrow.up.left.and.arrow.down.right", size: 14)
        let close = Self.makeButton("xmark", size: 13)

        bind(back, "seekBack")
        bind(playButton, "togglePlay")
        bind(forward, "seekForward")
        bind(next, "nextEpisode")
        bind(expand, "exitMini")
        bind(close, "closeMini")

        back.toolTip = "Back 10 seconds"
        forward.toolTip = "Forward 10 seconds"
        next.toolTip = "Next episode"
        expand.toolTip = "Return to full window"
        close.toolTip = "Pause and return to full window"

        let row = NSStackView(views: [back, playButton, forward, next])
        row.orientation = .horizontal
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false

        controlsContent.addSubview(row)
        controlsContent.addSubview(progress)
        addSubview(controls)

        let corner = NSStackView(views: [expand, close])
        corner.orientation = .horizontal
        corner.spacing = 10
        corner.translatesAutoresizingMaskIntoConstraints = false
        cornerControls = corner
        corner.alphaValue = 0
        addSubview(corner)

        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            controls.widthAnchor.constraint(equalToConstant: 230),
            controls.heightAnchor.constraint(equalToConstant: 58),
            row.centerXAnchor.constraint(equalTo: controlsContent.centerXAnchor),
            row.topAnchor.constraint(equalTo: controlsContent.topAnchor, constant: 9),
            progress.leadingAnchor.constraint(equalTo: controlsContent.leadingAnchor, constant: 18),
            progress.trailingAnchor.constraint(equalTo: controlsContent.trailingAnchor, constant: -18),
            progress.bottomAnchor.constraint(equalTo: controlsContent.bottomAnchor, constant: -7),
            corner.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            corner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    private var cornerControls: NSView?

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(with state: PlayerState) {
        playButton.image = NSImage(systemSymbolName: state.playing ? "pause.fill" : "play.fill",
                                   accessibilityDescription: state.playing ? "Pause" : "Play")
        progress.doubleValue = state.duration > 0 ? min(1, state.time / state.duration) : 0
        if !state.playing { reveal() }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { reveal() }
    override func mouseMoved(with event: NSEvent) { reveal() }
    override func mouseExited(with event: NSEvent) { conceal(after: 0.4) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onCommand?("exitMini")
        } else {
            window?.performDrag(with: event)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var lastSwipe = Date.distantPast

    override func scrollWheel(with event: NSEvent) {
        // A sideways two-finger swipe skips 10 seconds. Trackpad momentum after
        // the swipe is ignored, and swipes closer than 0.4 s count once.
        guard event.momentumPhase == [],
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5, abs(event.scrollingDeltaX) > 6,
              Date().timeIntervalSince(lastSwipe) > 0.4 else { return }
        lastSwipe = Date()
        onCommand?(event.scrollingDeltaX > 0 ? "seekBack" : "seekForward")
    }

    private func reveal() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            controls.animator().alphaValue = 1
            cornerControls?.animator().alphaValue = 1
        }
        conceal(after: 2.2)
    }

    private func conceal(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self?.controls.animator().alphaValue = 0
                self?.cornerControls?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Buttons

    private static func makeButton(_ symbol: String, size: CGFloat) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)!,
                              target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.symbolConfiguration = .init(pointSize: size, weight: .semibold)
        button.contentTintColor = .white
        button.imagePosition = .imageOnly
        return button
    }

    private func bind(_ button: NSButton, _ command: String) {
        button.identifier = NSUserInterfaceItemIdentifier(command)
        button.target = self
        button.action = #selector(buttonPressed(_:))
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let command = sender.identifier?.rawValue else { return }
        onCommand?(command)
        reveal()
    }
}
