import Foundation
import Hypervisor
import Darwin

/// Full VirtIO MMIO (v2) block device with virtqueue processing
/// and a raw disk-image backend.
///
/// Spec reference: VirtIO 1.2 §2, §4.2 (MMIO), §5.2 (Block).
nonisolated final class FluxVirtIOBlock {

    // ─── MMIO transport ──────────────────────────────────────

    let base: UInt64
    let size: UInt64
    let spiINTID: UInt32
    let name: String
    let readOnly: Bool
    let deviceID: UInt32

    init(
        base: UInt64 = 0x0A000000,
        size: UInt64 = 0x200,
        spiINTID: UInt32 = 48,
        name: String = "disk0",
        readOnly: Bool = false,
        deviceID: UInt32 = 2
    ) {
        self.base = base
        self.size = size
        self.spiINTID = spiINTID
        self.name = name
        self.readOnly = readOnly
        self.deviceID = deviceID
    }

    // ─── Device identity ─────────────────────────────────────

    private let magic: UInt32     = 0x74726976   // "virt"
    private let version: UInt32   = 2            // modern MMIO
    private let vendorID: UInt32  = 0x554D4551   // "QEMU" (EDK2 checks this)

    // ─── Feature bits ────────────────────────────────────────

    /// Word 0:
    /// Bit 0 = VIRTIO_BLK_F_SIZE_MAX  (0x01)
    /// Bit 1 = VIRTIO_BLK_F_SEG_MAX   (0x02)
    /// Bit 5 = VIRTIO_BLK_F_RO        (0x20)
    /// Bit 6 = VIRTIO_BLK_F_BLK_SIZE  (0x40)
    /// Bit 9 = VIRTIO_BLK_F_FLUSH     (0x200)
    private var deviceFeaturesWord0: UInt32 {
        var feat: UInt32 = (1 << 0) | (1 << 1) | (1 << 6) | (1 << 9)
        if readOnly {
            feat |= (1 << 5)
        }
        return feat
    }
    /// Word 1:
    /// Bit 0 = VIRTIO_F_VERSION_1 (bit 32 overall)
    private let deviceFeaturesWord1: UInt32 = 1

    private var deviceFeaturesSel: UInt32 = 0
    private var driverFeaturesSel: UInt32 = 0
    private var driverFeaturesWord0: UInt32 = 0
    private var driverFeaturesWord1: UInt32 = 0

    // ─── Device status ───────────────────────────────────────

    private var status: UInt32 = 0

    // ─── Queue state (single queue, index 0) ─────────────────

    private let queueNumMax: UInt32 = 256

    private var queueSel: UInt32    = 0
    private var queueNum: UInt32    = 0
    private var queueReady: UInt32  = 0
    private var lastAvailIdx: UInt16 = 0

    private var queueDescLow: UInt32  = 0
    private var queueDescHigh: UInt32 = 0
    private var queueDriverLow: UInt32  = 0
    private var queueDriverHigh: UInt32 = 0
    private var queueDeviceLow: UInt32  = 0
    private var queueDeviceHigh: UInt32 = 0

    // ─── Interrupt status ────────────────────────────────────

    private var interruptStatus: UInt32 = 0

    // ─── Disk backend & Config Space ─────────────────────────

    private var diskFD: Int32 = -1
    private var diskSectors: UInt64 = 0
    private let sectorSize: UInt64 = 512

    /// Device-specific configuration space (0x100..0x1FF)
    private var configBytes = [UInt8](repeating: 0, count: 0x100)

    /// Guest RAM host pointer and geometry (set by `configure`).
    private var guestRAMHost: UnsafeMutableRawPointer?
    private var guestRAMBase: UInt64 = 0
    private var guestRAMSize: Int = 0

    // ─── Verbose logging ─────────────────────────────────────

    static var verbose = false

    // MARK: - Setup

    /// Configure the block device with guest memory mapping and disk path.
    /// Must be called before the VM run loop.
    func configure(
        guestRAM: UnsafeMutableRawPointer,
        guestBase: UInt64,
        guestSize: Int,
        diskPath: String
    ) -> Bool {

        guestRAMHost = guestRAM
        guestRAMBase = guestBase
        guestRAMSize = guestSize

        if readOnly {
            diskFD = open(diskPath, O_RDONLY)
        } else {
            diskFD = open(diskPath, O_RDWR)
            if diskFD < 0 {
                // Try read-only fallback.
                diskFD = open(diskPath, O_RDONLY)
            }
        }

        guard diskFD >= 0 else {
            print("❌ VirtIO-BLK[\(name)]: cannot open disk: \(diskPath)")
            return false
        }

        let fileSize = lseek(diskFD, 0, SEEK_END)
        _ = lseek(diskFD, 0, SEEK_SET)

        guard fileSize > 0 else {
            print("❌ VirtIO-BLK[\(name)]: disk size is 0")
            close(diskFD)
            diskFD = -1
            return false
        }

        diskSectors = UInt64(fileSize) / sectorSize
        updateConfigSpace()

        print("✅ VirtIO-BLK[\(name)] disk attached (\(readOnly ? "RO" : "RW"))")
        print("   Path: \(diskPath)")
        print("   Size: \(fileSize) bytes (\(diskSectors) sectors)")

        return true
    }

    private func updateConfigSpace() {
        // capacity (u64 at offset 0)
        let sec = diskSectors.littleEndian
        withUnsafeBytes(of: sec) { bytes in
            for (i, b) in bytes.enumerated() {
                configBytes[i] = b
            }
        }
        // size_max (u32 at offset 8)
        let sizeMax: UInt32 = (1024 * 1024).littleEndian
        withUnsafeBytes(of: sizeMax) { bytes in
            for (i, b) in bytes.enumerated() {
                configBytes[8 + i] = b
            }
        }
        // seg_max (u32 at offset 12)
        let segMax: UInt32 = UInt32(128).littleEndian
        withUnsafeBytes(of: segMax) { bytes in
            for (i, b) in bytes.enumerated() {
                configBytes[12 + i] = b
            }
        }
        // blk_size (u32 at offset 20)
        let blkSize: UInt32 = UInt32(512).littleEndian
        withUnsafeBytes(of: blkSize) { bytes in
            for (i, b) in bytes.enumerated() {
                configBytes[20 + i] = b
            }
        }
    }

    func cleanup() {
        if diskFD >= 0 {
            close(diskFD)
            diskFD = -1
        }
    }

    // MARK: - MMIO address check

    func contains(_ address: UInt64) -> Bool {
        address >= base && address < base + size
    }

    // MARK: - MMIO read

    func read(address: UInt64, size: Int) -> UInt64? {
        let off = address - base

        if Self.verbose {
            print("VirtIO-BLK[\(name)] READ  off=0x\(String(off, radix: 16)) size=\(size)")
        }

        // ─── Config space (virtio_blk_config) ─────────
        if off >= 0x100 && off < 0x200 {
            let cfgOff = Int(off - 0x100)
            var val: UInt64 = 0
            for i in 0..<min(size, 8) {
                if cfgOff + i < configBytes.count {
                    val |= UInt64(configBytes[cfgOff + i]) << (i * 8)
                }
            }
            return val
        }

        switch off {

        // ─── Identity ─────────────────────────────────
        case 0x000: return UInt64(magic)
        case 0x004: return UInt64(version)
        case 0x008: return UInt64(deviceID)
        case 0x00C: return UInt64(vendorID)

        // ─── Features ─────────────────────────────────
        case 0x010:
            return UInt64(
                deviceFeaturesSel == 0
                    ? deviceFeaturesWord0
                    : (deviceFeaturesSel == 1
                       ? deviceFeaturesWord1
                       : 0)
            )

        // ─── Queue ────────────────────────────────────
        case 0x034:
            return queueSel == 0 ? UInt64(queueNumMax) : 0

        case 0x044:
            return UInt64(queueReady)

        // ─── Interrupt ───────────────────────────────
        case 0x060:
            return UInt64(interruptStatus)

        // ─── Status ───────────────────────────────────
        case 0x070:
            return UInt64(status)

        // Optional fields that UEFI may probe — return 0
        case 0x0FC:
            // ConfigGeneration
            return 0

        default:
            return 0
        }
    }

    // MARK: - MMIO write

    func write(address: UInt64, value: UInt64, size: Int) -> Bool {
        let off = address - base
        let v = UInt32(truncatingIfNeeded: value)

        if Self.verbose {
            print("VirtIO-BLK[\(name)] WRITE off=0x\(String(off, radix: 16)) value=0x\(String(v, radix: 16))")
        }

        // ─── Config space write ───────────────────────
        if off >= 0x100 && off < 0x200 {
            let cfgOff = Int(off - 0x100)
            for i in 0..<min(size, 8) {
                if cfgOff + i < configBytes.count {
                    configBytes[cfgOff + i] = UInt8(truncatingIfNeeded: value >> (i * 8))
                }
            }
            return true
        }

        switch off {

        // ─── Features ─────────────────────────────────
        case 0x014:
            deviceFeaturesSel = v

        case 0x020:
            if driverFeaturesSel == 0 {
                driverFeaturesWord0 = v
            } else if driverFeaturesSel == 1 {
                driverFeaturesWord1 = v
            }

        case 0x024:
            driverFeaturesSel = v

        // ─── Queue ────────────────────────────────────
        case 0x030:
            queueSel = v

        case 0x038:
            queueNum = v

        case 0x044:
            queueReady = v

        case 0x080:
            queueDescLow = v

        case 0x084:
            queueDescHigh = v

        case 0x090:
            queueDriverLow = v

        case 0x094:
            queueDriverHigh = v

        case 0x0A0:
            queueDeviceLow = v

        case 0x0A4:
            queueDeviceHigh = v

        // ─── Queue notify ─────────────────────────────
        case 0x050:
            // Guest wrote to QueueNotify — process the virtqueue.
            processQueue()

        // ─── Interrupt ACK ────────────────────────────
        case 0x064:
            interruptStatus &= ~v

            // De-assert SPI when guest has acknowledged all bits.
            if interruptStatus == 0 {
                let result = hv_gic_set_spi(spiINTID, false)
                if result != HV_SUCCESS && Self.verbose {
                    print("⚠️ VirtIO-BLK[\(name)]: hv_gic_set_spi deassert failed: \(result)")
                }
            }

        // ─── Status ───────────────────────────────────
        case 0x070:
            status = v

            // Writing 0 → full device reset.
            if v == 0 {
                resetDevice()
            }

        default:
            break
        }

        return true
    }

    // MARK: - Device reset

    private func resetDevice() {
        deviceFeaturesSel = 0
        driverFeaturesSel = 0
        driverFeaturesWord0 = 0
        driverFeaturesWord1 = 0
        queueSel = 0
        queueNum = 0
        queueReady = 0
        lastAvailIdx = 0
        queueDescLow = 0
        queueDescHigh = 0
        queueDriverLow = 0
        queueDriverHigh = 0
        queueDeviceLow = 0
        queueDeviceHigh = 0
        interruptStatus = 0
        status = 0

        if Self.verbose {
            print("VirtIO-BLK: device reset")
        }
    }

    // MARK: - Virtqueue processing

    /// Split virtqueue descriptor.
    private struct VirtqDesc {
        let addr: UInt64
        let len: UInt32
        let flags: UInt16
        let next: UInt16
    }

    private func processQueue() {
        guard queueReady == 1 else { return }
        guard diskFD >= 0 else { return }
        guard queueNum > 0 else { return }

        let descAddr = UInt64(queueDescHigh) << 32 | UInt64(queueDescLow)
        let driverAddr = UInt64(queueDriverHigh) << 32 | UInt64(queueDriverLow)
        let deviceAddr = UInt64(queueDeviceHigh) << 32 | UInt64(queueDeviceLow)

        guard let descHost = guestToHost(descAddr),
              let driverHost = guestToHost(driverAddr),
              let deviceHost = guestToHost(deviceAddr) else {
            print("❌ VirtIO-BLK: virtqueue address outside guest RAM")
            return
        }

        // ─── Avail ring ──────────────────────────────────
        //
        //   struct virtq_avail {
        //     le16 flags;       // +0
        //     le16 idx;         // +2
        //     le16 ring[];      // +4
        //   };

        let availFlags = driverHost.load(fromByteOffset: 0, as: UInt16.self)
        let availIdx = driverHost.load(fromByteOffset: 2, as: UInt16.self)
        _ = availFlags  // suppress unused

        // ─── Used ring ───────────────────────────────────
        //
        //   struct virtq_used {
        //     le16 flags;       // +0
        //     le16 idx;         // +2
        //     struct virtq_used_elem ring[]; // +4
        //   };
        //   struct virtq_used_elem {
        //     le32 id;          // +0
        //     le32 len;         // +4
        //   };

        // Process all available descriptors.
        var processed = false

        while lastAvailIdx != availIdx {
            let ringOffset = 4 + Int(lastAvailIdx % UInt16(queueNum)) * 2
            let headIdx = driverHost.load(fromByteOffset: ringOffset, as: UInt16.self)

            let totalWritten = processChain(
                descHost: descHost,
                headIdx: Int(headIdx)
            )

            // Write used ring entry.
            let usedElemOffset = 4 + Int(lastAvailIdx % UInt16(queueNum)) * 8
            deviceHost.storeBytes(of: UInt32(headIdx), toByteOffset: usedElemOffset, as: UInt32.self)
            deviceHost.storeBytes(of: totalWritten, toByteOffset: usedElemOffset + 4, as: UInt32.self)

            lastAvailIdx &+= 1
            processed = true
        }

        // Update used idx.
        if processed {
            deviceHost.storeBytes(of: lastAvailIdx, toByteOffset: 2, as: UInt16.self)

            // Raise interrupt: USED_BUFFER_NOTIFICATION (bit 0).
            interruptStatus |= 1

            let result = hv_gic_set_spi(spiINTID, true)
            if result != HV_SUCCESS {
                print("❌ VirtIO-BLK[\(name)]: hv_gic_set_spi assert failed: \(result)")
            }
        }
    }

    /// Process a single descriptor chain.  Returns total bytes written to
    /// device-readable buffers.
    private func processChain(
        descHost: UnsafeMutableRawPointer,
        headIdx: Int
    ) -> UInt32 {

        // Walk the descriptor chain and collect:
        //   1. The request header (virtio_blk_req: type + reserved + sector)
        //   2. Data buffer(s)
        //   3. Status byte buffer (1 byte, device-writable)

        var idx = headIdx
        var phase = 0   // 0 = header, 1 = data, 2 = status
        var totalWritten: UInt32 = 0

        var reqType: UInt32 = 0
        var reqSector: UInt64 = 0

        // Collect data segments.
        var dataSegments: [(ptr: UnsafeMutableRawPointer, len: Int, writable: Bool)] = []
        var statusPtr: UnsafeMutablePointer<UInt8>?

        for _ in 0..<Int(queueNum) {
            let desc = readDesc(descHost: descHost, index: idx)

            let isDeviceWritable = (desc.flags & 0x2) != 0  // VIRTQ_DESC_F_WRITE
            let hasNext = (desc.flags & 0x1) != 0           // VIRTQ_DESC_F_NEXT

            guard let bufHost = guestToHost(desc.addr) else {
                print("❌ VirtIO-BLK: desc addr outside guest RAM")
                break
            }

            if phase == 0 {
                // Header: struct virtio_blk_req { type: u32, reserved: u32, sector: u64 }
                reqType = bufHost.load(fromByteOffset: 0, as: UInt32.self)
                reqSector = bufHost.load(fromByteOffset: 8, as: UInt64.self)
                phase = 1

            } else if !isDeviceWritable && phase == 1 {
                // Data segment for WRITE (host reads from guest buffer).
                dataSegments.append((bufHost, Int(desc.len), false))

            } else if isDeviceWritable && desc.len == 1 {
                // Status byte (last descriptor).
                statusPtr = bufHost.assumingMemoryBound(to: UInt8.self)
                phase = 2

            } else if isDeviceWritable {
                // Data segment for READ (host writes into guest buffer).
                dataSegments.append((bufHost, Int(desc.len), true))
            }

            if !hasNext { break }
            idx = Int(desc.next)
        }

        // Execute the request.
        var statusByte: UInt8 = 0   // VIRTIO_BLK_S_OK
        let cleanReqType = reqType & ~0x80000000

        switch cleanReqType {

        case 0: // VIRTIO_BLK_T_IN (read)
            let offset = off_t(reqSector * sectorSize)
            _ = lseek(diskFD, offset, SEEK_SET)

            for seg in dataSegments {
                let bytesRead = Darwin.read(diskFD, seg.ptr, seg.len)
                if bytesRead < 0 {
                    statusByte = 1  // VIRTIO_BLK_S_IOERR
                    break
                }
                if bytesRead < seg.len {
                    // Zero out remainder of sector/buffer if reading past EOF or sparse area
                    let readCount = max(0, bytesRead)
                    memset(seg.ptr + readCount, 0, seg.len - readCount)
                }
                totalWritten += UInt32(seg.len)
            }

        case 1: // VIRTIO_BLK_T_OUT (write)
            if readOnly {
                statusByte = 1  // VIRTIO_BLK_S_IOERR
                break
            }
            let offset = off_t(reqSector * sectorSize)
            _ = lseek(diskFD, offset, SEEK_SET)

            for seg in dataSegments {
                let bytesWritten = Darwin.write(diskFD, seg.ptr, seg.len)
                if bytesWritten < 0 {
                    statusByte = 1  // VIRTIO_BLK_S_IOERR
                    break
                }
            }

        case 4: // VIRTIO_BLK_T_FLUSH
            if diskFD >= 0 {
                fsync(diskFD)
            }

        case 8: // VIRTIO_BLK_T_GET_ID
            // Return an ASCII device ID string.
            if let seg = dataSegments.first {
                let id = "flux-\(name)"
                let idBytes = Array(id.utf8)
                let copyLen = min(idBytes.count, seg.len)
                memcpy(seg.ptr, idBytes, copyLen)
                if copyLen < seg.len {
                    memset(seg.ptr + copyLen, 0, seg.len - copyLen)
                }
                totalWritten += UInt32(seg.len)
            }

        default:
            statusByte = 2  // VIRTIO_BLK_S_UNSUPP
        }

        // Write status byte.
        statusPtr?.pointee = statusByte
        totalWritten += 1

        print("VirtIO-BLK[\(name)]: req type=\(cleanReqType) sector=\(reqSector) status=\(statusByte)")

        return totalWritten
    }

    // MARK: - Helpers

    private func readDesc(
        descHost: UnsafeMutableRawPointer,
        index: Int
    ) -> VirtqDesc {
        // Each descriptor is 16 bytes.
        let base = descHost + index * 16
        return VirtqDesc(
            addr: base.load(fromByteOffset: 0, as: UInt64.self),
            len:  base.load(fromByteOffset: 8, as: UInt32.self),
            flags: base.load(fromByteOffset: 12, as: UInt16.self),
            next:  base.load(fromByteOffset: 14, as: UInt16.self)
        )
    }

    /// Convert a guest IPA to a host pointer, or `nil` if out of range.
    private func guestToHost(_ gpa: UInt64) -> UnsafeMutableRawPointer? {
        guard let host = guestRAMHost else { return nil }

        guard gpa >= guestRAMBase,
              gpa < guestRAMBase + UInt64(guestRAMSize) else {
            return nil
        }

        let offset = Int(gpa - guestRAMBase)
        return host + offset
    }
}
