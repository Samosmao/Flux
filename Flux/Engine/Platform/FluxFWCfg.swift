import Foundation

nonisolated final class FluxFWCfg {

    static let baseAddress: UInt64 = 0x09020000
    static let regionSize: UInt64 = 0x18

    static let ramfbSelector: UInt16 = 0x0023
    static let ramfbConfigSize: UInt32 = 28

    private let dataOffset: UInt64 = 0x00
    private let selectorOffset: UInt64 = 0x08
    private let dmaOffset: UInt64 = 0x10

    weak var memory: FluxMemory?

    private let lock = NSLock()
    private var selector: UInt16 = 0
    private var dataIndex: Int = 0
    private var ramfbWriteBuffer = [UInt8]()

    private lazy var fileDirectoryData: [UInt8] = {
        let files: [(name: String, selector: UInt16, size: UInt32)] = [
            ("etc/table-loader", 0x0020, UInt32(FluxACPI.shared.loaderBlob.count)),
            ("etc/acpi/rsdp", 0x0021, UInt32(FluxACPI.shared.rsdpBlob.count)),
            ("etc/acpi/tables", 0x0022, UInt32(FluxACPI.shared.tablesBlob.count)),
            ("etc/ramfb", Self.ramfbSelector, Self.ramfbConfigSize),
        ]

        var data = [UInt8]()
        // Header: uint32_t count (big-endian)
        let count = UInt32(files.count).bigEndian
        withUnsafeBytes(of: count) { data.append(contentsOf: $0) }

        for file in files {
            // struct fw_cfg_file {
            //     uint32_t size; (big-endian)
            //     uint16_t select; (big-endian)
            //     uint16_t reserved; (2 bytes zero)
            //     char name[56];
            // };
            let sBE = file.size.bigEndian
            withUnsafeBytes(of: sBE) { data.append(contentsOf: $0) }

            let selBE = file.selector.bigEndian
            withUnsafeBytes(of: selBE) { data.append(contentsOf: $0) }

            data.append(contentsOf: [0x00, 0x00])

            var nameBuf = [UInt8](repeating: 0, count: 56)
            let nameBytes = [UInt8](file.name.utf8.prefix(55))
            nameBuf.replaceSubrange(0..<nameBytes.count, with: nameBytes)
            data.append(contentsOf: nameBuf)
        }

        return data
    }()

    func contains(_ address: UInt64) -> Bool {
        address >= Self.baseAddress &&
        address < Self.baseAddress + Self.regionSize
    }

    private func item(for selector: UInt16) -> [UInt8] {

        switch selector {

        // FW_CFG_SIGNATURE
        case 0x0000:
            return Array("QEMU".utf8)

        // FW_CFG_ID
        //
        // Bit 0 = traditional interface
        // Bit 1 = DMA interface
        //
        // We intentionally advertise NO DMA yet.
        case 0x0001:
            return [
                0x01, 0x00, 0x00, 0x00
            ]

        // FW_CFG_FILE_DIR
        case 0x0019:
            return fileDirectoryData

        // etc/table-loader
        case 0x0020:
            return FluxACPI.shared.loaderBlob

        // etc/acpi/rsdp
        case 0x0021:
            return FluxACPI.shared.rsdpBlob

        // etc/acpi/tables
        case 0x0022:
            return FluxACPI.shared.tablesBlob

        // etc/ramfb
        case Self.ramfbSelector:
            return [UInt8](repeating: 0, count: Int(Self.ramfbConfigSize))

        default:
            // Unknown/unimplemented item.
            return []
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

        switch offset {

        case selectorOffset:

            guard size == 2 else {
                print(
                    "❌ fw_cfg selector write size: \(size)"
                )
                return false
            }

            // fw_cfg MMIO selector is big-endian.
            let raw = UInt16(truncatingIfNeeded: value)
            selector = raw.byteSwapped
            dataIndex = 0

            if selector == Self.ramfbSelector {
                ramfbWriteBuffer.removeAll(keepingCapacity: true)
            }

            print(
                "fw_cfg selector -> 0x" +
                String(selector, radix: 16)
            )

            return true

        case dataOffset:
            if selector == Self.ramfbSelector {
                for i in 0..<size {
                    let byte = UInt8((value >> (i * 8)) & 0xFF)
                    ramfbWriteBuffer.append(byte)
                }
                if ramfbWriteBuffer.count >= Int(Self.ramfbConfigSize) {
                    applyRamfbConfig()
                }
            }
            return true

        case dmaOffset:
            handleDMA(value: value, size: size)
            return true

        default:
            print(
                "❌ fw_cfg unknown write offset 0x" +
                String(offset, radix: 16)
            )
            return false
        }
    }

    private func applyRamfbConfig() {
        guard ramfbWriteBuffer.count >= Int(Self.ramfbConfigSize) else { return }

        let rawAddr = ramfbWriteBuffer[0..<8].withUnsafeBytes { $0.load(as: UInt64.self) }
        let rawFourcc = ramfbWriteBuffer[8..<12].withUnsafeBytes { $0.load(as: UInt32.self) }
        let rawFlags = ramfbWriteBuffer[12..<16].withUnsafeBytes { $0.load(as: UInt32.self) }
        let rawWidth = ramfbWriteBuffer[16..<20].withUnsafeBytes { $0.load(as: UInt32.self) }
        let rawHeight = ramfbWriteBuffer[20..<24].withUnsafeBytes { $0.load(as: UInt32.self) }
        let rawStride = ramfbWriteBuffer[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }

        let addr = UInt64(bigEndian: rawAddr)
        let fourcc = UInt32(bigEndian: rawFourcc)
        let flags = UInt32(bigEndian: rawFlags)
        let width = UInt32(bigEndian: rawWidth)
        let height = UInt32(bigEndian: rawHeight)
        let stride = UInt32(bigEndian: rawStride)

        print("🖥️ [FluxFWCfg] RAMFB Config received:")
        print("   Address: 0x\(String(addr, radix: 16))")
        print("   FourCC:  0x\(String(fourcc, radix: 16))")
        print("   Flags:   0x\(String(flags, radix: 16))")
        print("   Width:   \(width)")
        print("   Height:  \(height)")
        print("   Stride:  \(stride)")

        guard let memory = memory else {
            print("❌ [FluxFWCfg] Memory reference not set in FluxFWCfg")
            return
        }

        guard let hostPtr = memory.hostPointer(forGuestAddress: addr) else {
            print("❌ [FluxFWCfg] RAMFB address 0x\(String(addr, radix: 16)) is out of guest RAM bounds")
            return
        }

        FluxFramebuffer.shared.configure(
            guestAddress: addr,
            fourcc: fourcc,
            flags: flags,
            width: width,
            height: height,
            stride: stride,
            hostPointer: hostPtr
        )
    }

    private func handleDMA(value: UInt64, size: Int) {
        guard let memory = memory else { return }

        // EDK2 writes big-endian 64-bit address: MmioWrite64(..., SwapBytes64((UINT64)&Access))
        let dmaAddr = value.byteSwapped
        guard let hostPtr = memory.hostPointer(forGuestAddress: dmaAddr) else {
            return
        }

        // FwCfgDmaAccess struct:
        //   uint32_t control; (offset 0, big-endian)
        //   uint32_t length;  (offset 4, big-endian)
        //   uint64_t address; (offset 8, big-endian)
        let ctrlRaw = hostPtr.load(fromByteOffset: 0, as: UInt32.self)
        let lenRaw = hostPtr.load(fromByteOffset: 4, as: UInt32.self)
        let addrRaw = hostPtr.load(fromByteOffset: 8, as: UInt64.self)

        let control = UInt32(bigEndian: ctrlRaw)
        let length = UInt32(bigEndian: lenRaw)
        let bufferGuestAddr = UInt64(bigEndian: addrRaw)

        let isWrite = (control & 0x10) != 0
        let isSelect = (control & 0x08) != 0

        if isSelect {
            selector = UInt16(control >> 16)
            dataIndex = 0
            if selector == Self.ramfbSelector {
                ramfbWriteBuffer.removeAll(keepingCapacity: true)
            }
        }

        if isWrite && selector == Self.ramfbSelector,
           let srcHostPtr = memory.hostPointer(forGuestAddress: bufferGuestAddr) {
            let bytes = UnsafeRawBufferPointer(start: srcHostPtr, count: Int(length))
            ramfbWriteBuffer.append(contentsOf: bytes)
            if ramfbWriteBuffer.count >= Int(Self.ramfbConfigSize) {
                applyRamfbConfig()
            }
        }

        // Mark DMA access finished by clearing control field to 0
        hostPtr.storeBytes(of: UInt32(0), toByteOffset: 0, as: UInt32.self)
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

        switch offset {

        case dataOffset:

            guard size == 1 ||
                  size == 2 ||
                  size == 4 ||
                  size == 8 else {

                print(
                    "❌ fw_cfg data read size: \(size)"
                )
                return nil
            }

            let bytes = item(for: selector)

            var result: UInt64 = 0

            // String-preserving data semantics:
            // byte at lower guest address becomes low byte
            // of an AArch64 little-endian load.
            for i in 0..<size {

                let index = dataIndex + i

                let byte: UInt8 =
                    index < bytes.count
                    ? bytes[index]
                    : 0

                result |=
                    UInt64(byte) << UInt64(i * 8)
            }

            dataIndex += size

            return result

        case dmaOffset:
            // DMA not implemented / advertised.
            return 0

        case selectorOffset:
            // Selector is write-only by spec.
            return 0

        default:
            return nil
        }
    }
}
