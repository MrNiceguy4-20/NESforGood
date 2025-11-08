import Foundation
import GameController
import AppKit

// MARK: - NES Controller Input Mapping
final class Controller {
    enum Button: CaseIterable {
        case a, b, select, start, up, down, left, right
    }

    private var buttonStates: [Button: Bool] = {
        var dict = [Button: Bool]()
        for b in Button.allCases { dict[b] = false }
        return dict
    }()

    private var shiftRegister: UInt8 = 0
    private var strobe: Bool = false

    init() {
        setupKeyboardMonitor()
        setupGameController()
    }

    // MARK: - Keyboard Handling
    private func setupKeyboardMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self = self else { return event }
            let isPressed = (event.type == .keyDown)
            switch event.keyCode {
            case 0x00: self.buttonStates[.a] = isPressed      // A key
            case 0x0B: self.buttonStates[.b] = isPressed      // B key
            case 0x31: self.buttonStates[.select] = isPressed // Space = Select
            case 0x24: self.buttonStates[.start] = isPressed  // Return = Start
            case 0x7E: self.buttonStates[.up] = isPressed
            case 0x7D: self.buttonStates[.down] = isPressed
            case 0x7B: self.buttonStates[.left] = isPressed
            case 0x7C: self.buttonStates[.right] = isPressed
            default: break
            }
            return event
        }
    }

    // MARK: - Game Controller Support
    private func setupGameController() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let controller = note.object as? GCController {
                self?.configureGamepad(controller)
            }
        }

        // If already connected
        for controller in GCController.controllers() {
            configureGamepad(controller)
        }
    }

    private func configureGamepad(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }

        // D-Pad
        gamepad.dpad.valueChangedHandler = { [weak self] _, x, y in
            guard let self = self else { return }
            self.buttonStates[.up] = y > 0.5
            self.buttonStates[.down] = y < -0.5
            self.buttonStates[.left] = x < -0.5
            self.buttonStates[.right] = x > 0.5
        }

        // Face buttons (no longer optional in macOS 13+)
        gamepad.buttonA.valueChangedHandler = { [weak self] _, _, pressed in
            self?.buttonStates[.a] = pressed
        }

        gamepad.buttonB.valueChangedHandler = { [weak self] _, _, pressed in
            self?.buttonStates[.b] = pressed
        }

        // Optionally map shoulder buttons or menu button to Start/Select
        gamepad.leftShoulder.valueChangedHandler = { [weak self] _, _, pressed in
            self?.buttonStates[.select] = pressed
        }

        gamepad.rightShoulder.valueChangedHandler = { [weak self] _, _, pressed in
            self?.buttonStates[.start] = pressed
        }

        // Handle pause/menu button as Start (if available)
        controller.controllerPausedHandler = { [weak self] _ in
            self?.buttonStates[.start] = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.buttonStates[.start] = false
            }
        }
    }

    // MARK: - NES Register Interface
    func write(value: UInt8) {
        strobe = (value & 1) != 0
        if strobe {
            // Reload the shift register with button states
            reloadShiftRegister()
        }
    }

    func read() -> UInt8 {
        if strobe {
            reloadShiftRegister()
        }
        let bit = shiftRegister & 1
        shiftRegister >>= 1
        shiftRegister |= 0x80 // ensures 1s after 8 reads
        return bit
    }

    private func reloadShiftRegister() {
        // NES controller shift register order: A, B, Select, Start, Up, Down, Left, Right
        var bits: UInt8 = 0
        for (i, button) in Button.allCases.enumerated() {
            if buttonStates[button] == true {
                bits |= (1 << i)
            }
        }
        shiftRegister = bits
    }
}
