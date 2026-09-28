import Foundation

nonisolated final class FluxUART {

    static let baseAddress: UInt64 = 0x09000000
    static let regionSize: UInt64 = 0x1000

    // Temporary diagnostic-only host input route.  It targets the existing
    // PL011 console and is intentionally separate from xHCI/HID emulation.
    private static let diagnosticLock = NSLock()
    private static weak var diagnosticUART: FluxUART?

    // PL011 register offsets
    private let dr: UInt64    = 0x000
    private let rsrEcr: UInt64 = 0x004
    private let fr: UInt64    = 0x018
    private let ibrd: UInt64  = 0x024
    private let fbrd: UInt64  = 0x028
    private let lcrh: UInt64  = 0x02C
    private let cr: UInt64    = 0x030
    private let ifls: UInt64  = 0x034
    private let imsc: UInt64  = 0x038
    private let ris: UInt64   = 0x03C
    private let mis: UInt64   = 0x040
    private let icr: UInt64   = 0x044
    private let dmacr: UInt64 = 0x048

    // PL011 identification registers
    private let periphID0: UInt64 = 0xFE0
    private let periphID1: UInt64 = 0xFE4
    private let periphID2: UInt64 = 0xFE8
    private let periphID3: UInt64 = 0xFEC

    private let pcellID0: UInt64 = 0xFF0
    private let pcellID1: UInt64 = 0xFF4
    private let pcellID2: UInt64 = 0xFF8
    private let pcellID3: UInt64 = 0xFFC

    private var control: UInt32 = 0
    private var integerBaud: UInt32 = 0
    private var fractionalBaud: UInt32 = 0
    private var lineControl: UInt32 = 0
    private var fifoLevel: UInt32 = 0
    private var interruptMask: UInt32 = 0
    private var dmaControl: UInt32 = 0
    private var receiveFIFO: [UInt8] = []
    private let lock = NSLock()

    private(set) var output = ""

    init() {
        Self.diagnosticLock.lock()
        Self.diagnosticUART = self
        Self.diagnosticLock.unlock()
    }

    deinit {
        Self.diagnosticLock.lock()
        if Self.diagnosticUART === self { Self.diagnosticUART = nil }
        Self.diagnosticLock.unlock()
    }

    /// Feeds the existing serial console only while the Flux display has focus.
    /// This deliberately provides no USB/xHCI behavior and no disk automation.
    static func injectDiagnosticInput(_ bytes: [UInt8]) {
        diagnosticLock.lock()
        let uart = diagnosticUART
        diagnosticLock.unlock()
        uart?.enqueueDiagnosticInput(bytes)
    }

    /// Test-only acknowledgement observer.  The Windows continuation probe writes
    /// a unique marker to COM1 only after its associated guest file operation is
    /// complete.  This polls the existing UART output; it does not alter UART,
    /// HID, or guest input behavior.
    static func waitForDiagnosticOutput(
        _ marker: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1
    ) -> Bool {
        let started = Date()
        print("[FAST-PROBE] GUEST_ACK_WAIT marker=\(marker)")

        while Date().timeIntervalSince(started) < timeout {
            diagnosticLock.lock()
            let uart = diagnosticUART
            diagnosticLock.unlock()

            if let uart, uart.containsOutput(marker) {
                print("[FAST-PROBE] GUEST_ACK_PASS marker=\(marker) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(started)))")
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        print("[FAST-PROBE] GUEST_ACK_TIMEOUT marker=\(marker)")
        return false
    }

    private func enqueueDiagnosticInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        receiveFIFO.append(contentsOf: bytes.prefix(max(0, 256 - receiveFIFO.count)))
        lock.unlock()
        print("[PL011-DIAGNOSTIC] queued \(bytes.count) host input byte(s)")
    }

    private func containsOutput(_ marker: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return output.contains(marker)
    }

    func contains(_ address: UInt64) -> Bool {
        address >= Self.baseAddress &&
        address < Self.baseAddress + Self.regionSize
    }

    func read(
        address: UInt64,
        size: Int
    ) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }

        guard contains(address) else {
            return nil
        }

        let offset = address - Self.baseAddress

        guard size == 4 else {
            print(
                "⚠️ PL011 unsupported read size \(size) @ 0x" +
                String(offset, radix: 16)
            )
            return 0
        }

        switch offset {

        case dr:
            return UInt64(receiveFIFO.isEmpty ? 0 : receiveFIFO.removeFirst())

        case fr:
            // TXFE = 1: transmit FIFO empty
            // RXFE reflects the temporary diagnostic receive FIFO.
            //
            // BUSY = 0
            // TXFF = 0
            return receiveFIFO.isEmpty ? 0x90 : 0x80

        case rsrEcr:
            // RSR: no receive errors pending.
            return 0

        case ibrd:
            return UInt64(integerBaud)

        case fbrd:
            return UInt64(fractionalBaud)

        case lcrh:
            return UInt64(lineControl)

        case cr:
            return UInt64(control)

        case ifls:
            return UInt64(fifoLevel)

        case imsc:
            return UInt64(interruptMask)

        case ris:
            return 0

        case mis:
            return 0

        case dmacr:
            return UInt64(dmaControl)

        // ARM PL011 ID values
        case periphID0:
            return 0x11

        case periphID1:
            return 0x10

        case periphID2:
            return 0x14

        case periphID3:
            return 0x00

        case pcellID0:
            return 0x0D

        case pcellID1:
            return 0xF0

        case pcellID2:
            return 0x05

        case pcellID3:
            return 0xB1

        default:
            print(
                "⚠️ PL011 unknown read @ offset 0x" +
                String(offset, radix: 16)
            )
            return 0
        }
    }

    func write(
        address: UInt64,
        value: UInt64,
        size: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard contains(address) else {
            return false
        }

        let offset = address - Self.baseAddress
        let value32 = UInt32(truncatingIfNeeded: value)

        switch offset {

        case dr:
            let byte = UInt8(value32 & 0xFF)

            if let scalar = UnicodeScalar(Int(byte)) {
                let character = Character(scalar)

                output.append(character)
                print(character, terminator: "")
                fflush(stdout)
            }

            return true

        case rsrEcr:
            // ECR: any write clears receive error status.
            return true

        case ibrd:
            guard size == 4 else { return false }
            integerBaud = value32
            return true

        case fbrd:
            guard size == 4 else { return false }
            fractionalBaud = value32
            return true

        case lcrh:
            guard size == 4 else { return false }
            lineControl = value32
            return true

        case cr:
            guard size == 4 else { return false }
            control = value32
            return true

        case ifls:
            guard size == 4 else { return false }
            fifoLevel = value32
            return true

        case imsc:
            guard size == 4 else { return false }
            interruptMask = value32
            return true

        case icr:
            // No pending UART interrupts yet.
            return true

        case dmacr:
            guard size == 4 else { return false }
            dmaControl = value32
            return true

        default:
            print(
                "⚠️ PL011 unknown write @ offset 0x" +
                String(offset, radix: 16) +
                " value=0x" +
                String(value, radix: 16)
            )

            // During bring-up, tolerate unknown registers.
            return true
        }
    }
}
