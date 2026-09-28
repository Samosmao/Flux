import Foundation

nonisolated final class FluxRTC {

    static let baseAddress: UInt64 = 0x09010000
    static let regionSize: UInt64 = 0x1000

    private let dr: UInt64   = 0x000
    private let mr: UInt64   = 0x004
    private let lr: UInt64   = 0x008
    private let cr: UInt64   = 0x00C
    private let imsc: UInt64 = 0x010
    private let ris: UInt64  = 0x014
    private let mis: UInt64  = 0x018
    private let icr: UInt64  = 0x01C

    static var verbose = ProcessInfo.processInfo.environment["FLUX_VERBOSE_RTC"] == "1"

    private let lock = NSLock()
    private var match: UInt32 = 0
    private var control: UInt32 = 1
    private var interruptMask: UInt32 = 0

    private var loadBaseSeconds: UInt64?
    private var loadHostTime: TimeInterval?

    func contains(_ address: UInt64) -> Bool {
        address >= Self.baseAddress &&
        address < Self.baseAddress + Self.regionSize
    }

    private func currentSeconds() -> UInt32 {

        if let loadBaseSeconds,
           let loadHostTime {

            let elapsed =
                Date().timeIntervalSince1970 -
                loadHostTime

            return UInt32(
                truncatingIfNeeded:
                    loadBaseSeconds +
                    UInt64(elapsed)
            )
        }

        return UInt32(Date().timeIntervalSince1970)
    }

    func read(
        address: UInt64,
        size: Int
    ) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }

        guard contains(address),
              size == 1 ||
              size == 2 ||
              size == 4 else {
            return nil
        }

        let offset =
            address - Self.baseAddress

        if Self.verbose {
            print(
                "PL031 READ offset=0x" +
                String(offset, radix: 16) +
                " size=\(size)"
            )
        }

        switch offset {

        case dr:
            return UInt64(currentSeconds())

        case mr:
            return UInt64(match)

        case lr:
            return 0

        case cr:
            return UInt64(control)

        case imsc:
            return UInt64(interruptMask)

        case ris:
            return 0

        case mis:
            return 0

        case icr:
            return 0

        // Peripheral ID registers
        case 0xFE0:
            return 0x31

        case 0xFE4:
            return 0x10

        case 0xFE8:
            return 0x14

        case 0xFEC:
            return 0x00

        // PrimeCell ID registers
        case 0xFF0:
            return 0x0D

        case 0xFF4:
            return 0xF0

        case 0xFF8:
            return 0x05

        case 0xFFC:
            return 0xB1

        default:
            print(
                "⚠️ PL031 unknown read @ offset 0x" +
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

        guard contains(address),
              size == 1 ||
              size == 2 ||
              size == 4 else {
            return false
        }

        let offset =
            address - Self.baseAddress

        let value32 =
            UInt32(truncatingIfNeeded: value)

        switch offset {

        case mr:
            match = value32
            return true

        case lr:
            loadBaseSeconds =
                UInt64(value32)

            loadHostTime =
                Date().timeIntervalSince1970

            return true

        case cr:
            control = value32
            return true

        case imsc:
            interruptMask = value32
            return true

        case icr:
            return true

        default:
            print(
                "⚠️ PL031 unknown write @ offset 0x" +
                String(offset, radix: 16) +
                " value=0x" +
                String(value, radix: 16)
            )
            return true
        }
    }
}
