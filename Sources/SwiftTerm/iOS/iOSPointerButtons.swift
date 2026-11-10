//
//  iOSPointerButtons.swift
//
//  Reports the buttons of an attached mouse or trackpad (primary, secondary and
//  middle), button drags, and a two-finger tap as a secondary click to
//  applications that enabled mouse tracking.
//
//  The tap and pan gestures in iOSTerminalView only know about a single primary
//  "button": a tap is a click and a one-finger drag is the wheel. With a real
//  pointer the user expects press, drag and release with any button, which is
//  what this file provides. Pointer presses require the app to set
//  `UIApplicationSupportsIndirectInputEvents` in its Info.plist, otherwise UIKit
//  delivers them as ordinary touches without a button mask.
//

#if os(iOS) || os(visionOS)
#if !SWIFTTERM_EMBEDDED
import UIKit

/// Begins as soon as an indirect pointer presses inside the view, so the press is
/// reported immediately instead of after the tap recognizers settle.
@MainActor
final class PointerButtonGestureRecognizer: UIGestureRecognizer {
    /// Asked when a press starts; returning false lets the other recognizers
    /// (selection, links, scrolling) handle the touch.
    var shouldTrack: ((_ location: CGPoint, _ modifiers: UIKeyModifierFlags) -> Bool)?
    private(set) var pressedButtons: UIEvent.ButtonMask = []

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        cancelsTouchesInView = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let touch = touches.first else {
            return
        }
        pressedButtons = event.buttonMask
        if shouldTrack?(touch.location(in: view), modifierFlags) ?? false {
            state = .began
        } else {
            state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = (state == .began || state == .changed) ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        pressedButtons = []
    }
}

extension TerminalView {
    /// xterm button numbers: 0 = left, 1 = middle, 2 = right.
    static func xtermButton(for mask: UIEvent.ButtonMask) -> Int {
        if mask.contains(.secondary) {
            return 2
        }
        if mask.contains(.button(3)) {
            return 1
        }
        return 0
    }

    func setupPointerButtonGestures() {
        let pointer = PointerButtonGestureRecognizer(target: self, action: #selector(pointerButtonHandler(_:)))
        pointer.shouldTrack = { [weak self] location, modifiers in
            guard let self else { return false }
            return self.pointerReportingActive(modifiers: modifiers)
        }
        addGestureRecognizer(pointer)

        // Touch screens have no secondary button: a two-finger tap stands in for it.
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapHandler(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(twoFingerTap)

        // While an application tracks the mouse every tap is a click, reported without
        // waiting to see whether a double tap follows (the application times multi-clicks).
        let mouseTap = UITapGestureRecognizer(target: self, action: #selector(mouseTapHandler(_:)))
        mouseTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                      NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        mouseTap.isEnabled = false
        addGestureRecognizer(mouseTap)
        mouseTapGesture = mouseTap
    }

    func refreshMouseTapGestures(mouseMode: Terminal.MouseMode? = nil) {
        let mode = mouseMode ?? withTerminal { $0.mouseMode }
        let tracking = allowMouseReporting && mode.sendButtonPress()
        mouseTapGesture?.isEnabled = tracking
        for gesture in localTapGestures {
            gesture.isEnabled = !tracking
        }
    }

    @objc func mouseTapHandler(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let hadSelection = withTerminal { _ in selection.active }
        if hadSelection {
            // First tap after a long-press selection just clears it.
            withTerminal { _ in selection.selectNone() }
            disableSelectionPanGesture()
            frameDriver.markDirty()
            return
        }
        let modifiers = gesture.modifierFlags
        guard pointerReportingActive(modifiers: modifiers) else { return }
        let point = gesture.location(in: self)
        reportPointer(button: 0, release: false, motion: false, at: point, modifiers: modifiers)
        if withTerminal({ $0.mouseMode.sendButtonRelease() }) {
            reportPointer(button: 0, release: true, motion: false, at: point, modifiers: modifiers)
        }
    }

    func pointerReportingActive(modifiers: UIKeyModifierFlags) -> Bool {
        guard allowMouseReporting else { return false }
        return withTerminal { terminal in
            terminal.mouseMode.sendButtonPress() &&
                (!modifiers.contains(.shift) || terminal.mouseShiftCapture)
        }
    }

    /// Sends a press, release or motion report for `button` at `point`.
    /// Returns the grid cell that was reported, or nil when nothing was sent.
    @discardableResult
    func reportPointer(button: Int, release: Bool, motion: Bool, at point: CGPoint,
                       modifiers: UIKeyModifierFlags) -> Position? {
        let control = modifiers.contains(.control) || (terminalAccessory?.controlModifier ?? controlModifier)
        let cell: Position? = withTerminal { terminal in
            let hit = calculateTapHitLocked(point: point)
            guard let grid = hit.grid.toScreenCoordinate(from: terminal.displayBuffer),
                  grid.row < terminal.rows else { return nil }
            let flags = terminal.encodeButton(
                button: button, release: release,
                shift: modifiers.contains(.shift),
                meta: modifiers.contains(.alternate),
                control: control)
            if motion {
                terminal.sendMotion(buttonFlags: flags, x: grid.col, y: grid.row,
                                    pixelX: hit.pixels.col, pixelY: hit.pixels.row)
            } else {
                terminal.sendEvent(buttonFlags: flags, x: grid.col, y: grid.row,
                                   pixelX: hit.pixels.col, pixelY: hit.pixels.row)
            }
            return grid
        }
        if !motion && !release {
            terminalAccessory?.controlModifier = false
            controlModifier = false
        }
        frameDriver.markDirty()
        return cell
    }

    @objc func pointerButtonHandler(_ gesture: PointerButtonGestureRecognizer) {
        let point = gesture.location(in: self)
        let modifiers = gesture.modifierFlags
        switch gesture.state {
        case .began:
            if !isFirstResponder {
                _ = becomeFirstResponder()
            }
            pointerButtonPressed = TerminalView.xtermButton(for: gesture.pressedButtons)
            pointerLastReportedCell = reportPointer(button: pointerButtonPressed, release: false,
                                                    motion: false, at: point, modifiers: modifiers)
        case .changed:
            let tracks = withTerminal { $0.mouseMode.sendButtonTracking() }
            guard tracks else { return }
            // Report each cell once, as xterm does.
            let cell = withTerminal { terminal in
                calculateTapHitLocked(point: point).grid.toScreenCoordinate(from: terminal.displayBuffer)
            }
            guard let cell, cell != pointerLastReportedCell else { return }
            pointerLastReportedCell = reportPointer(button: pointerButtonPressed, release: false,
                                                    motion: true, at: point, modifiers: modifiers)
        case .ended, .cancelled:
            if withTerminal({ $0.mouseMode.sendButtonRelease() }) {
                reportPointer(button: pointerButtonPressed, release: true, motion: false,
                              at: point, modifiers: modifiers)
            }
            pointerLastReportedCell = nil
        default:
            break
        }
    }

    @objc func twoFingerTapHandler(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, pointerReportingActive(modifiers: gesture.modifierFlags) else {
            return
        }
        let point = gesture.location(in: self)
        reportPointer(button: 2, release: false, motion: false, at: point, modifiers: gesture.modifierFlags)
        if withTerminal({ $0.mouseMode.sendButtonRelease() }) {
            reportPointer(button: 2, release: true, motion: false, at: point, modifiers: gesture.modifierFlags)
        }
    }
}

#endif
#endif
