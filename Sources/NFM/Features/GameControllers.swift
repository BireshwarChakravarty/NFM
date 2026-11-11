import Foundation
import GameController

/// Turns any connected game controller (Xbox, PlayStation, Switch Pro, MFi,
/// or a Siri Remote) into a TV-style remote for NFM.
final class GameControllerManager {
    enum Input {
        case up, down, left, right
        case select     // A / Cross
        case back       // B / Circle
        case playPause  // X / Square
        case search     // Y / Triangle
        case menu       // Menu / Options
    }

    var onInput: ((Input) -> Void)?
    var onConnect: ((String) -> Void)?

    private var repeatTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            self.configure(controller)
            self.onConnect?(controller.vendorName ?? "Controller")
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.repeatTimer?.invalidate()
        })
        GCController.controllers().forEach(configure)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        repeatTimer?.invalidate()
    }

    private func configure(_ controller: GCController) {
        controller.handlerQueue = .main
        if let pad = controller.extendedGamepad {
            bindDirections(pad.dpad)
            bindDirections(pad.leftThumbstick)
            bind(pad.buttonA, .select)
            bind(pad.buttonB, .back)
            bind(pad.buttonX, .playPause)
            bind(pad.buttonY, .search)
            bind(pad.buttonMenu, .menu)
        } else if let micro = controller.microGamepad {
            // Siri Remote and similar: clickpad + select + menu/back.
            micro.reportsAbsoluteDpadValues = false
            bindDirections(micro.dpad)
            bind(micro.buttonA, .select)
            bind(micro.buttonX, .playPause)
            bind(micro.buttonMenu, .back)
        }
    }

    private func bindDirections(_ pad: GCControllerDirectionPad) {
        bindRepeating(pad.up, .up)
        bindRepeating(pad.down, .down)
        bindRepeating(pad.left, .left)
        bindRepeating(pad.right, .right)
    }

    private func bind(_ button: GCControllerButtonInput, _ input: Input) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.onInput?(input) }
        }
    }

    /// Holding a direction keeps moving, like a TV remote.
    private func bindRepeating(_ button: GCControllerButtonInput, _ input: Input) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard let self else { return }
            self.repeatTimer?.invalidate()
            guard pressed else { return }
            self.onInput?(input)
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.14, repeats: true) { [weak self] _ in
                    self?.onInput?(input)
                }
            }
        }
    }
}
