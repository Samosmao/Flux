import SwiftUI
import MetalKit
import AppKit

struct FluxDisplayView: NSViewRepresentable {

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = FluxDiagnosticDisplayView()
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ [FluxDisplayView] Metal is not supported on this Mac")
            return mtkView
        }

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false

        let renderer = FluxMetalRenderer(device: device)
        context.coordinator.renderer = renderer
        mtkView.delegate = renderer

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
    }

    final class Coordinator {
        var renderer: FluxMetalRenderer?
    }
}

/// Native USB HID Boot Keyboard, Absolute Pointer, and diagnostic serial-console input view.
private final class FluxDiagnosticDisplayView: MTKView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private var scrollAccumulator: CGFloat = 0.0

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func resignFirstResponder() -> Bool {
        scrollAccumulator = 0.0
        FluxHIDKeyboard.shared.resetState()
        FluxHIDPointer.shared.resetButtons()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window = self.window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey), name: NSApplication.didResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidChangeFullScreen), name: NSWindow.didEnterFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidChangeFullScreen), name: NSWindow.didExitFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize), name: NSWindow.didResizeNotification, object: window)
        }
    }

    private var resizeDebounceTimer: Timer?

    @objc private func windowDidResize() {
        resizeDebounceTimer?.invalidate()
        resizeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.handleDebouncedWindowResize()
        }
    }

    private func handleDebouncedWindowResize() {
        let viewSize = bounds.size
        guard viewSize.width > 0 && viewSize.height > 0 else { return }

        let target = FluxDisplayManager.targetResolution(for: viewSize)
        let current = FluxFramebuffer.shared.snapshot()
        print("🖥️ [DYNAMIC-RESO] Viewport resized: \(Int(viewSize.width))x\(Int(viewSize.height)) -> Target: \(target.width)x\(target.height) (Active: \(current.width)x\(current.height))")

        if current.width != target.width || current.height != target.height {
            FluxDisplayManager.shared.requestResolutionChange(width: target.width, height: target.height)
        }
    }

    @objc private func windowDidResignKey() {
        scrollAccumulator = 0.0
        FluxHIDKeyboard.shared.resetState()
        FluxHIDPointer.shared.resetButtons()
    }

    @objc private func windowDidBecomeKey() {
        window?.makeFirstResponder(self)
        let flags = NSEvent.modifierFlags.rawValue
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: 0, rawFlags: flags)
    }

    @objc private func windowDidChangeFullScreen() {
        window?.makeFirstResponder(self)
        needsDisplay = true
        handleDebouncedWindowResize()
    }

    // MARK: - Native Mouse / Pointer Events

    private func handleMouseEvent(_ event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let snap = FluxFramebuffer.shared.snapshot()
        let fbW = snap.width > 0 ? snap.width : 1024
        let fbH = snap.height > 0 ? snap.height : 768
        guard let map = FluxHIDPointer.mapPointToHID(viewPoint: loc, viewSize: bounds.size, fbWidth: fbW, fbHeight: fbH) else {
            return
        }
        let buttons = UInt8(NSEvent.pressedMouseButtons & 0x07)
        FluxHIDPointer.shared.updateState(x: map.hidX, y: map.hidY, buttons: buttons)
    }

    override func mouseEntered(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func mouseExited(with event: NSEvent) {
        if NSEvent.pressedMouseButtons == 0 {
            FluxHIDPointer.shared.resetButtons()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseEvent(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseEvent(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            // Trackpad smooth scrolling
            scrollAccumulator += event.scrollingDeltaY
            let threshold: CGFloat = 8.0 // points per HID wheel tick
            if abs(scrollAccumulator) >= threshold {
                let steps = Int(scrollAccumulator / threshold)
                scrollAccumulator -= CGFloat(steps) * threshold
                let clampedDelta = Int8(clamping: max(-5, min(5, steps)))
                if clampedDelta != 0 {
                    FluxHIDPointer.shared.updateWheel(delta: clampedDelta)
                }
            }
        } else {
            // Traditional mouse wheel
            let ticks = Int8(clamping: Int(round(event.deltaY)))
            if ticks != 0 {
                FluxHIDPointer.shared.updateWheel(delta: ticks)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let window = self.window, window.isKeyWindow, window.firstResponder === self else { return }

        // Route to USB HID Boot Keyboard
        FluxHIDKeyboard.shared.handleKeyDown(keyCode: event.keyCode, isRepeat: event.isARepeat)

        // Preserve temporary diagnostic UART forwarding
        let bytes: [UInt8]
        switch event.keyCode {
        case 36: bytes = [0x0D]                    // Return
        case 48: bytes = [0x09]                    // Tab
        case 51: bytes = [0x08]                    // Backspace
        case 53: bytes = [0x1B]                    // Escape
        case 123: bytes = Array("\u{1B}[D".utf8)  // Left
        case 124: bytes = Array("\u{1B}[C".utf8)  // Right
        case 125: bytes = Array("\u{1B}[B".utf8)  // Down
        case 126: bytes = Array("\u{1B}[A".utf8)  // Up
        case 109: bytes = Array("\u{1B}[21~".utf8) // F10
        default:
            guard let text = event.characters, !text.isEmpty else { return }
            bytes = Array(text.utf8)
        }
        FluxUART.injectDiagnosticInput(bytes)
    }

    override func keyUp(with event: NSEvent) {
        guard let window = self.window, window.isKeyWindow, window.firstResponder === self else { return }
        FluxHIDKeyboard.shared.handleKeyUp(keyCode: event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let window = self.window, window.isKeyWindow, window.firstResponder === self else { return }
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue)
    }
}
