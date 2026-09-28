import Foundation

/// FluxPCIe: Minimal PCIe ECAM Host Bridge for ARM64.
///
/// Decodes MMIO configuration space in 0x3F000000 ..< 0x40000000 (Bus 0..15).
/// Device 0: Host Bridge (060000h)
/// Device 1: NVMe Controller (010802h)
/// Device 2: xHCI Controller (0C0330h)
nonisolated final class FluxPCIe {

    let base: UInt64
    let size: UInt64
    let ioBase: UInt64 = 0x3EFF0000
    let ioSize: UInt64 = 0x00010000 // 64 KB
    let nvme: FluxNVMe
    let xhci: FluxXHCI

    init(
        base: UInt64 = 0x3F000000,
        size: UInt64 = 0x01000000,
        nvme: FluxNVMe,
        xhci: FluxXHCI
    ) {
        self.base = base
        self.size = size
        self.nvme = nvme
        self.xhci = xhci
    }

    func containsConfig(_ gpa: UInt64) -> Bool {
        gpa >= base && gpa < (base + size)
    }

    func containsIO(_ gpa: UInt64) -> Bool {
        gpa >= ioBase && gpa < (ioBase + ioSize)
    }

    func readIO(address: UInt64, size: Int) -> UInt64 {
        return 0
    }

    func writeIO(address: UInt64, value: UInt64, size: Int) {
        // Ignored
    }

    func readConfig(address: UInt64, size: Int) -> UInt64 {
        let offset = address - base
        let bus = (offset >> 20) & 0xFF
        let device = (offset >> 15) & 0x1F
        let function = (offset >> 12) & 0x07
        let reg = UInt32(offset & 0xFFF)

        // Bus 0 Dev 1 Func 0: NVMe Controller
        if bus == 0 && device == 1 && function == 0 {
            return nvme.readPCIConfig(offset: reg, size: size)
        }

        if bus == 0 && device == 2 && function == 0 {
            return xhci.readPCIConfig(offset: reg, size: size)
        }

        // Bus 0 Dev 0 Func 0: Host Bridge
        if bus == 0 && device == 0 && function == 0 {
            return readHostBridge(offset: reg, size: size)
        }

        // Unpopulated slot
        return size == 1 ? 0xFF : (size == 2 ? 0xFFFF : 0xFFFF_FFFF)
    }

    func writeConfig(address: UInt64, value: UInt64, size: Int) {
        let offset = address - base
        let bus = (offset >> 20) & 0xFF
        let device = (offset >> 15) & 0x1F
        let function = (offset >> 12) & 0x07
        let reg = UInt32(offset & 0xFFF)

        // Bus 0 Dev 1 Func 0: NVMe Controller
        if bus == 0 && device == 1 && function == 0 {
            nvme.writePCIConfig(offset: reg, value: value, size: size)
        } else if bus == 0 && device == 2 && function == 0 {
            xhci.writePCIConfig(offset: reg, value: value, size: size)
        }
    }

    private func readHostBridge(offset: UInt32, size: Int) -> UInt64 {
        let reg = offset & 0xFF
        var config = [UInt8](repeating: 0, count: 64)
        // VID: 0x1B36, DID: 0x0008 (Red Hat PCIe Host Bridge)
        config[0x00] = 0x36
        config[0x01] = 0x1B
        config[0x02] = 0x08
        config[0x03] = 0x00
        // Class Code: 0x060000 (Bridge / Host Bridge)
        config[0x08] = 0x00
        config[0x09] = 0x00
        config[0x0A] = 0x00
        config[0x0B] = 0x06
        // Header Type: 0x00
        config[0x0E] = 0x00

        var result: UInt64 = 0
        for i in 0..<size {
            let idx = Int(reg) + i
            if idx < config.count {
                result |= UInt64(config[idx]) << (i * 8)
            }
        }
        return result
    }
}
