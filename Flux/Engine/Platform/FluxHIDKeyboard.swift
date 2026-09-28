import Foundation
import AppKit

/// Thread-safe USB HID Boot Keyboard state and report generator.
/// Bridges macOS hardware keyCodes and NSEvent modifiers to 8-byte HID Boot Keyboard reports.
nonisolated final class FluxHIDKeyboard: @unchecked Sendable {

    static let shared = FluxHIDKeyboard()

    private let lock = NSLock()
    private var pressedKeys: [UInt8] = []  // Up to 6 simultaneous HID usage codes
    private var modifiers: UInt8 = 0       // 8 modifier bits
    private var reportQueue: [[UInt8]] = [] // Enqueued 8-byte reports waiting for EP3 transfer

    private init() {}

    // MARK: - KeyCode -> HID Usage Mapping

    /// Maps macOS hardware keyCodes to USB HID Boot Keyboard usages.
    static func hidUsage(for keyCode: UInt16) -> UInt8? {
        switch keyCode {
        // Letters A-Z
        case 0x00: return 0x04 // A
        case 0x0B: return 0x05 // B
        case 0x08: return 0x06 // C
        case 0x02: return 0x07 // D
        case 0x0E: return 0x08 // E
        case 0x03: return 0x09 // F
        case 0x05: return 0x0A // G
        case 0x04: return 0x0B // H
        case 0x22: return 0x0C // I
        case 0x26: return 0x0D // J
        case 0x28: return 0x0E // K
        case 0x25: return 0x0F // L
        case 0x2E: return 0x10 // M
        case 0x2D: return 0x11 // N
        case 0x1F: return 0x12 // O
        case 0x23: return 0x13 // P
        case 0x0C: return 0x14 // Q
        case 0x0F: return 0x15 // R
        case 0x01: return 0x16 // S
        case 0x11: return 0x17 // T
        case 0x20: return 0x18 // U
        case 0x09: return 0x19 // V
        case 0x0D: return 0x1A // W
        case 0x07: return 0x1B // X
        case 0x10: return 0x1C // Y
        case 0x06: return 0x1D // Z

        // Digits 1-9, 0
        case 0x12: return 0x1E // 1
        case 0x13: return 0x1F // 2
        case 0x14: return 0x20 // 3
        case 0x15: return 0x21 // 4
        case 0x17: return 0x22 // 5
        case 0x16: return 0x23 // 6
        case 0x1A: return 0x24 // 7
        case 0x1C: return 0x25 // 8
        case 0x19: return 0x26 // 9
        case 0x1D: return 0x27 // 0

        // Whitespace, Control & Punctuation
        case 0x31: return 0x2C // Spacebar
        case 0x24: return 0x28 // Return / Enter
        case 0x33: return 0x2A // Delete / Backspace
        case 0x30: return 0x2B // Tab
        case 0x35: return 0x29 // Escape
        case 0x1B: return 0x2D // - / _
        case 0x18: return 0x2E // = / +
        case 0x21: return 0x2F // [ / {
        case 0x1E: return 0x30 // ] / }
        case 0x2A: return 0x31 // \ / |
        case 0x29: return 0x33 // ; / :
        case 0x27: return 0x34 // ' / "
        case 0x32: return 0x35 // ` / ~
        case 0x2B: return 0x36 // , / <
        case 0x2F: return 0x37 // . / >
        case 0x2C: return 0x38 // / / ?

        // Navigation Arrows & Keys
        case 0x7C: return 0x4F // Right Arrow
        case 0x7B: return 0x50 // Left Arrow
        case 0x7D: return 0x51 // Down Arrow
        case 0x7E: return 0x52 // Up Arrow
        case 0x74: return 0x4B // Page Up
        case 0x79: return 0x4E // Page Down
        case 0x73: return 0x4A // Home
        case 0x77: return 0x4D // End

        default: return nil
        }
    }

    // MARK: - Event Ingestion

    func handleKeyDown(keyCode: UInt16, isRepeat: Bool) {
        var enqueued = false
        var reportBytes: [UInt8] = []
        var hidUsage: UInt8?

        lock.lock()
        if let usage = Self.hidUsage(for: keyCode) {
            hidUsage = usage
            if !pressedKeys.contains(usage) {
                if pressedKeys.count < 6 {
                    pressedKeys.append(usage)
                }
                reportBytes = enqueueCurrentReportLocked()
                enqueued = true
            } else if isRepeat {
                reportBytes = enqueueCurrentReportLocked()
                enqueued = true
            }
        }
        lock.unlock()

        if enqueued, let usage = hidUsage {
            print("⌨️ [HID-KEYBOARD] keyDown keyCode=\(keyCode) HID=0x\(String(format: "%02x", usage)) repeat=\(isRepeat) report=[\(reportBytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            FluxXHCI.notifyKeyboardEvent()
        }
    }

    func handleKeyUp(keyCode: UInt16) {
        var enqueued = false
        var reportBytes: [UInt8] = []
        var hidUsage: UInt8?

        lock.lock()
        if let usage = Self.hidUsage(for: keyCode) {
            hidUsage = usage
            if let idx = pressedKeys.firstIndex(of: usage) {
                pressedKeys.remove(at: idx)
                reportBytes = enqueueCurrentReportLocked()
                enqueued = true
            }
        }
        lock.unlock()

        if enqueued, let usage = hidUsage {
            print("⌨️ [HID-KEYBOARD] keyUp keyCode=\(keyCode) HID=0x\(String(format: "%02x", usage)) report=[\(reportBytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            FluxXHCI.notifyKeyboardEvent()
        }
    }

    func handleFlagsChanged(keyCode: UInt16, rawFlags: UInt) {
        var enqueued = false
        var reportBytes: [UInt8] = []
        var oldM: UInt8 = 0
        var newM: UInt8 = 0

        lock.lock()
        // Standard Carbon/Cocoa device-dependent modifier bit masks:
        // NX_DEVICELCTLKEYMASK   = 0x0001
        // NX_DEVICELSHIFTKEYMASK = 0x0002
        // NX_DEVICERSHIFTKEYMASK = 0x0004
        // NX_DEVICELCMDKEYMASK   = 0x0008
        // NX_DEVICERCMDKEYMASK   = 0x0010
        // NX_DEVICELALTKEYMASK   = 0x0020
        // NX_DEVICERALTKEYMASK   = 0x0040
        // NX_DEVICERCTLKEYMASK   = 0x2000
        var mods: UInt8 = 0
        if (rawFlags & 0x0001) != 0 { mods |= (1 << 0) } // Left Control
        if (rawFlags & 0x0002) != 0 { mods |= (1 << 1) } // Left Shift
        if (rawFlags & 0x0020) != 0 { mods |= (1 << 2) } // Left Alt/Option
        if (rawFlags & 0x0008) != 0 { mods |= (1 << 3) } // Left GUI/Command
        if (rawFlags & 0x2000) != 0 { mods |= (1 << 4) } // Right Control
        if (rawFlags & 0x0004) != 0 { mods |= (1 << 5) } // Right Shift
        if (rawFlags & 0x0040) != 0 { mods |= (1 << 6) } // Right Alt/Option
        if (rawFlags & 0x0010) != 0 { mods |= (1 << 7) } // Right GUI/Command

        // Device-independent fallback if hardware bits are missing (e.g. synthetic test events)
        if (rawFlags & 0x20000) != 0 && (mods & 0x22) == 0 { // Shift
            if keyCode == 60 { mods |= (1 << 5) } else { mods |= (1 << 1) }
        }
        if (rawFlags & 0x40000) != 0 && (mods & 0x11) == 0 { // Control
            if keyCode == 62 { mods |= (1 << 4) } else { mods |= (1 << 0) }
        }
        if (rawFlags & 0x80000) != 0 && (mods & 0x44) == 0 { // Option/Alt
            if keyCode == 61 { mods |= (1 << 6) } else { mods |= (1 << 2) }
        }
        if (rawFlags & 0x100000) != 0 && (mods & 0x88) == 0 { // Command/GUI
            if keyCode == 54 { mods |= (1 << 7) } else { mods |= (1 << 3) }
        }

        if mods != modifiers {
            oldM = modifiers
            newM = mods
            modifiers = mods
            reportBytes = enqueueCurrentReportLocked()
            enqueued = true
        }
        lock.unlock()

        if enqueued {
            print("⌨️ [HID-KEYBOARD] flagsChanged keyCode=\(keyCode) rawFlags=0x\(String(rawFlags, radix: 16)) mods=0x\(String(format: "%02x", oldM))->0x\(String(format: "%02x", newM)) report=[\(reportBytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            FluxXHCI.notifyKeyboardEvent()
        }
    }

    /// Resets all internal pressed keys and modifiers to zero.
    /// If keys or modifiers were held, immediately queues an all-zero release report.
    func resetState() {
        var enqueued = false
        var reportBytes: [UInt8] = []

        lock.lock()
        let hadKeys = !pressedKeys.isEmpty || modifiers != 0
        pressedKeys.removeAll()
        modifiers = 0
        if hadKeys {
            reportBytes = enqueueCurrentReportLocked()
            enqueued = true
        }
        lock.unlock()

        if enqueued {
            print("⌨️ [HID-KEYBOARD] resetState: safety release report queued [\(reportBytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            FluxXHCI.notifyKeyboardEvent()
        }
    }

    // MARK: - Queue Inspection & Consumption

    func peekReport() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return reportQueue.first
    }

    func popReport() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard !reportQueue.isEmpty else { return nil }
        return reportQueue.removeFirst()
    }

    var queueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reportQueue.count
    }

    /// Test-only synchronization for automated HID delivery. A report leaves this
    /// queue only after EP3 has copied it to the guest transfer buffer and posted
    /// the transfer completion; this never changes report creation or ordering.
    func waitUntilQueueDrained(timeout: TimeInterval, pollInterval: TimeInterval = 0.25) -> Bool {
        let started = Date()
        var lastPending = -1
        print("[FAST-PROBE] QUEUE_DRAIN_START")

        while Date().timeIntervalSince(started) < timeout {
            let pending = queueCount
            if pending != lastPending {
                print("[FAST-PROBE] QUEUE_PENDING=\(pending)")
                lastPending = pending
            }
            if pending == 0 {
                print("[FAST-PROBE] QUEUE_DRAIN_PASS elapsed=\(String(format: "%.3f", Date().timeIntervalSince(started)))")
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        print("[FAST-PROBE] QUEUE_DRAIN_TIMEOUT remaining=\(queueCount)")
        return false
    }

    private func enqueueCurrentReportLocked() -> [UInt8] {
        var report: [UInt8] = [modifiers, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        for i in 0..<min(pressedKeys.count, 6) {
            report[2 + i] = pressedKeys[i]
        }
        reportQueue.append(report)
        return report
    }

    // MARK: - Automated Live Test Runner

    private var testStarted = false

    func notifyEP3Armed() {
        guard ProcessInfo.processInfo.environment["FLUX_TEST_HID_KEYBOARD"] == "1" else { return }
        lock.lock()
        if testStarted {
            lock.unlock()
            return
        }
        testStarted = true
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.runLiveValidationTest()
        }
    }

    /// Types an ASCII string by simulating key presses and shift modifier.
    func typeString(_ str: String, charDelay: TimeInterval = 0.05) {
        let charMap: [Character: (keyCode: UInt16, shift: Bool)] = [
            "a": (0x00, false), "b": (0x0B, false), "c": (0x08, false), "d": (0x02, false),
            "e": (0x0E, false), "f": (0x03, false), "g": (0x05, false), "h": (0x04, false),
            "i": (0x22, false), "j": (0x26, false), "k": (0x28, false), "l": (0x25, false),
            "m": (0x2E, false), "n": (0x2D, false), "o": (0x1F, false), "p": (0x23, false),
            "q": (0x0C, false), "r": (0x0F, false), "s": (0x01, false), "t": (0x11, false),
            "u": (0x20, false), "v": (0x09, false), "w": (0x0D, false), "x": (0x07, false),
            "y": (0x10, false), "z": (0x06, false),
            "A": (0x00, true), "B": (0x0B, true), "C": (0x08, true), "D": (0x02, true),
            "E": (0x0E, true), "F": (0x03, true), "G": (0x05, true), "H": (0x04, true),
            "I": (0x22, true), "J": (0x26, true), "K": (0x28, true), "L": (0x25, true),
            "M": (0x2E, true), "N": (0x2D, true), "O": (0x1F, true), "P": (0x23, true),
            "Q": (0x0C, true), "R": (0x0F, true), "S": (0x01, true), "T": (0x11, true),
            "U": (0x20, true), "V": (0x09, true), "W": (0x0D, true), "X": (0x07, true),
            "Y": (0x10, true), "Z": (0x06, true),
            "1": (0x12, false), "2": (0x13, false), "3": (0x14, false), "4": (0x15, false),
            "5": (0x17, false), "6": (0x16, false), "7": (0x1A, false), "8": (0x1C, false),
            "9": (0x19, false), "0": (0x1D, false),
            "!": (0x12, true), "@": (0x13, true), "#": (0x14, true), "$": (0x15, true),
            "%": (0x17, true), "^": (0x16, true), "&": (0x1A, true), "*": (0x1C, true),
            "(": (0x19, true), ")": (0x1D, true),
            " ": (0x31, false), "-": (0x1B, false), "_": (0x1B, true),
            "=": (0x18, false), "+": (0x18, true),
            "[": (0x21, false), "{": (0x21, true),
            "]": (0x1E, false), "}": (0x1E, true),
            "\\": (0x2A, false), "|": (0x2A, true),
            ";": (0x29, false), ":": (0x29, true),
            "'": (0x27, false), "\"": (0x27, true),
            ",": (0x2B, false), "<": (0x2B, true),
            ".": (0x2F, false), ">": (0x2F, true),
            "/": (0x2C, false), "?": (0x2C, true),
            "`": (0x32, false), "~": (0x32, true),
            "\n": (0x24, false), "\t": (0x30, false)
        ]

        var shiftHeld = false
        for ch in str {
            guard let entry = charMap[ch] else { continue }
            if entry.shift && !shiftHeld {
                handleFlagsChanged(keyCode: 56, rawFlags: 0x0002 | 0x20000)
                Thread.sleep(forTimeInterval: 0.03)
                shiftHeld = true
            } else if !entry.shift && shiftHeld {
                handleFlagsChanged(keyCode: 56, rawFlags: 0)
                Thread.sleep(forTimeInterval: 0.03)
                shiftHeld = false
            }
            handleKeyDown(keyCode: entry.keyCode, isRepeat: false)
            Thread.sleep(forTimeInterval: charDelay)
            handleKeyUp(keyCode: entry.keyCode)
            Thread.sleep(forTimeInterval: charDelay)
        }
        if shiftHeld {
            handleFlagsChanged(keyCode: 56, rawFlags: 0)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    /// Opens Windows Run dialog (Win+R), types command, and presses Enter.
    /// - Parameter charDelay: Per-character delay in seconds (default 0.05s). Use 0.005s for fast typing of long payloads.
    func sendWinR(command: String, charDelay: TimeInterval = 0.05) {
        // Press Win+R
        handleFlagsChanged(keyCode: 55, rawFlags: 0x0008 | 0x100000) // Command / Win
        Thread.sleep(forTimeInterval: 0.1)
        handleKeyDown(keyCode: 0x0F, isRepeat: false) // R
        Thread.sleep(forTimeInterval: 0.1)
        handleKeyUp(keyCode: 0x0F)
        Thread.sleep(forTimeInterval: 0.1)
        handleFlagsChanged(keyCode: 55, rawFlags: 0) // Release Win
        Thread.sleep(forTimeInterval: 4.0) // wait for Run dialog to fully open and focus

        // Erase any previous command or leaked hotkey character by sending Backspace repeatedly
        for _ in 0..<50 {
            handleKeyDown(keyCode: 0x33, isRepeat: false) // Backspace
            Thread.sleep(forTimeInterval: 0.008)
            handleKeyUp(keyCode: 0x33)
            Thread.sleep(forTimeInterval: 0.008)
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Type command
        typeString(command, charDelay: charDelay)
        Thread.sleep(forTimeInterval: 0.8)

        // Press Enter
        handleKeyDown(keyCode: 0x24, isRepeat: false) // Enter
        Thread.sleep(forTimeInterval: 0.15)
        handleKeyUp(keyCode: 0x24)
    }

    /// Test-only Win+R submission that preserves the normal command text,
    /// typing delay, and single-Enter sequence while allowing a framebuffer
    /// capture after text entry and before that Enter is sent.
    func sendWinRForProbeEvidence(
        command: String,
        charDelay: TimeInterval,
        beforeEnter: () -> Void
    ) {
        handleFlagsChanged(keyCode: 55, rawFlags: 0x0008 | 0x100000)
        Thread.sleep(forTimeInterval: 0.1)
        handleKeyDown(keyCode: 0x0F, isRepeat: false)
        Thread.sleep(forTimeInterval: 0.1)
        handleKeyUp(keyCode: 0x0F)
        Thread.sleep(forTimeInterval: 0.1)
        handleFlagsChanged(keyCode: 55, rawFlags: 0)
        Thread.sleep(forTimeInterval: 4.0)

        for _ in 0..<50 {
            handleKeyDown(keyCode: 0x33, isRepeat: false)
            Thread.sleep(forTimeInterval: 0.008)
            handleKeyUp(keyCode: 0x33)
            Thread.sleep(forTimeInterval: 0.008)
        }
        Thread.sleep(forTimeInterval: 0.3)

        typeString(command, charDelay: charDelay)
        Thread.sleep(forTimeInterval: 2.0)
        beforeEnter()

        handleKeyDown(keyCode: 0x24, isRepeat: false)
        Thread.sleep(forTimeInterval: 0.15)
        handleKeyUp(keyCode: 0x24)
    }

    private func runLiveValidationTest() {
        print("🧪 [HID-TEST] ==================================================")
        print("🧪 [HID-TEST] Starting automated live keyboard validation test")
        print("🧪 [HID-TEST] Target keys: A, B, 1, Space, Enter, Backspace, Left Shift + A")
        print("🧪 [HID-TEST] ==================================================")

        // Press Left GUI (Windows Key) to open the Windows 11 Start Menu / Search box
        print("🧪 [HID-TEST] Pressing Left GUI (Windows Key) to open Start Menu / Search...")
        self.handleFlagsChanged(keyCode: 55, rawFlags: 0x0008 | 0x100000)
        Thread.sleep(forTimeInterval: 0.15)
        self.handleFlagsChanged(keyCode: 55, rawFlags: 0)
        Thread.sleep(forTimeInterval: 1.5)

        let testCases: [(name: String, action: () -> Void)] = [
            ("A", {
                self.handleKeyDown(keyCode: 0, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 0)
            }),
            ("B", {
                self.handleKeyDown(keyCode: 11, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 11)
            }),
            ("1", {
                self.handleKeyDown(keyCode: 18, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 18)
            }),
            ("Space", {
                self.handleKeyDown(keyCode: 49, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 49)
            }),
            ("Enter", {
                self.handleKeyDown(keyCode: 36, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 36)
            }),
            ("Backspace", {
                self.handleKeyDown(keyCode: 51, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 51)
            }),
            ("Left Shift + A", {
                self.handleFlagsChanged(keyCode: 56, rawFlags: 0x0002 | 0x20000)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyDown(keyCode: 0, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 0)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleFlagsChanged(keyCode: 56, rawFlags: 0)
            })
        ]

        for tc in testCases {
            print("🧪 [HID-TEST] Testing key: \(tc.name)")
            tc.action()
            Thread.sleep(forTimeInterval: 0.5)
        }

        Thread.sleep(forTimeInterval: 1.0)
        FluxVM.captureCurrentScreenshot()
        print("🧪 [HID-TEST] Automated live keyboard validation test complete!")
    }
}
