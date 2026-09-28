import Foundation
import Hypervisor
import Darwin

/// FluxNVMe: High-performance NVMe 1.3 Controller implementing PCI Type 0 Header,
/// NVMe Admin Queue, and I/O Submission/Completion Queues with scatter-gather I/O
/// (preadv/pwritev), asynchronous host I/O queue, and fine-grained locking.
///
/// Spec reference: NVM Express Base Specification 1.3 / 1.4.
nonisolated final class FluxNVMe {

    struct DiskIdentity: Equatable {
        let inode: UInt64
        let size: Int64
        let blocks: Int64
        let first4KiBChecksum: UInt64
    }

    // ─── Controller Identity & Geometry ───────────────────────────

    let spiINTID: UInt32 = 50 // Routed to GSI 50 via ACPI _PRT Dev 1 INTA#
    let sectorSize: UInt64 = 512
    var targetSectors: UInt64 = 0
    var installerSectors: UInt64 = 0
    var numNamespaces: Int = 1

    // ─── PCI Configuration Space (Type 0) ─────────────────────────

    private var configSpace = [UInt8](repeating: 0, count: 256)
    var pciCommand: UInt16 = 0
    /// Logging-only notification used to time the bounded Windows PnP scan.
    var onPCICommandWrite: ((UInt16) -> Void)?
    var bar0Base: UInt64 = 0
    let bar0Size: UInt64 = 0x2000 // 8 KB
    private var bar0Sizing: Bool = false
    private var bar1Sizing: Bool = false
    /// Dedicated 4 KiB MSI-X aperture.  It is intentionally separate from
    /// BAR0, whose upper half is the NVMe doorbell aperture.
    var bar2Base: UInt64 = 0
    let bar2Size: UInt64 = 0x1000
    private var bar2Sizing: Bool = false

    // ─── PCI MSI-X (one vector in BAR2) ───────────────────────────

    // PCIe Capability v2 occupies the conventional 0x50...0x8B range.
    // Keep MSI-X outside that structure on a dword-aligned boundary.
    private static let msixCapabilityOffset = 0x90
    private static let msixTableOffset: UInt64 = 0x000
    private static let msixPBAOffset: UInt64 = 0x800

    private struct MSIXTableEntry {
        var addressLow: UInt32 = 0
        var addressHigh: UInt32 = 0
        var data: UInt32 = 0
        var vectorControl: UInt32 = 1 // start masked until the OS programs it

        var address: UInt64 {
            UInt64(addressLow) | (UInt64(addressHigh) << 32)
        }

        var masked: Bool { (vectorControl & 1) != 0 }
    }

    private struct MSIDelivery {
        let address: hv_ipa_t
        let intid: UInt32
    }

    private let msixLock = NSLock()
    /// PCI MSI-X Message Control; only Function Mask and MSI-X Enable are
    /// writable. Table Size is hardwired to zero (one vector).
    private var msixMessageControl: UInt16 = 0
    private var msixTableEntry = MSIXTableEntry()
    private var msixPendingBits: UInt64 = 0

    // ─── Guest RAM & Disk Backend ─────────────────────────────────

    private var guestRAMHost: UnsafeMutableRawPointer?
    private var guestRAMBase: UInt64 = 0
    private var guestRAMSize: Int = 0
    private var targetFD: Int32 = -1
    private var targetDiskPath = ""
    private var lastLoggedTargetIdentity: DiskIdentity?
    private var installerFD: Int32 = -1
    private var totalTargetBytesWritten: UInt64 = 0
    private var lastMilestoneMB: UInt64 = 0

    // ─── NVMe Controller Registers (BAR0) ─────────────────────────

    /// CAP: MQES=63, CQS=1, TO=4 (2s), DSTRD=0 (stride 4), CSS=1 (NVM)
    /// Lower 32: (4 << 24) | (1 << 16) | 0x003F = 0x0401003F
    /// Upper 32: (1 << 5) = 0x00000020
    private let regCAP: UInt64 = 0x0000_0020_0401_003F
    private let regVS: UInt32  = 0x00010300 // NVMe 1.3
    private var regINTMS: UInt32 = 0
    private let gicLineLock = NSLock()
    private var gicLineLevel: Bool = false
    private var interruptSequence: UInt64 = 0
    private var lastAppliedInterruptSequence: UInt64 = 0

    var interruptAsserted: Bool {
        gicLineLock.lock()
        defer { gicLineLock.unlock() }
        return gicLineLevel
    }

    var onInterruptPending: (() -> Void)?
    var onInterruptAssert: (() -> Void)? {
        get { onInterruptPending }
        set { onInterruptPending = newValue }
    }
    private var regCC: UInt32    = 0
    private var regCSTS: UInt32  = 0
    private var regAQA: UInt32   = 0
    private var regASQ: UInt64   = 0
    private var regACQ: UInt64   = 0

    // ─── Queue State (Admin & I/O Queues) ─────────────────────────

    private struct NVMeSQ {
        var base: UInt64 = 0
        var size: UInt16 = 0
        var head: UInt16 = 0
        var tail: UInt16 = 0
        var cqId: UInt16 = 0
    }

    private struct NVMeCQ {
        var base: UInt64 = 0
        var size: UInt16 = 0
        var head: UInt16 = 0
        var tail: UInt16 = 0
        var phase: UInt16 = 1
    }

    private var sqs: [UInt16: NVMeSQ] = [:]
    private var cqs: [UInt16: NVMeCQ] = [:]

    // ─── Concurrency & Optimization ───────────────────────────────

    private let lock = NSRecursiveLock()
    private let cqLock = NSLock()
    private let statsLock = NSLock()
    private(set) var controllerGeneration: UInt64 = 0
    let workerPool = FluxNVMeIOWorkerPool(workerCount: 4)

    private enum IOState: Equatable {
        case disabled
        case running
        case resetting
    }
    /// Separate from `lock` so reset can wait for admitted host I/O without
    /// holding the controller lock across preadv/pwritev/fsync.
    private let ioGate = NSCondition()
    private var ioState: IOState = .disabled
    private var admittedHostIO: UInt64 = 0

    private struct AsyncIORequest: @unchecked Sendable {
        let generation: UInt64
        let sqid: UInt16
        let cqId: UInt16
        let cid: UInt16
        let opc: UInt8
        let nsid: UInt32
        let fd: Int32
        let fileOffset: off_t
        let totalBytes: Int
        let iovs: [iovec]
    }

    static var verbose: Bool = ProcessInfo.processInfo.environment["FLUX_VERBOSE_NVME"] == "1"
    /// Read-only, rate-limited diagnostics for the installed-Windows legacy
    /// interrupt path.  This deliberately has no effect unless explicitly set.
    private static let traceTargetIRQ = ProcessInfo.processInfo.environment["FLUX_TRACE_TARGET_IRQ"] == "1"
    private struct TargetIRQTrace {
        var spi50AssertCount: UInt64 = 0
        var spi50DeassertCount: UInt64 = 0
        var spi50PendingSamples: UInt64 = 0
        var spi50ActiveSamples: UInt64 = 0
        var cq1TailAdvanceCount: UInt64 = 0
        var cq1HeadAdvanceCount: UInt64 = 0
        var cq1MaxUnread: UInt16 = 0
        var msixCapabilityReadCount: UInt64 = 0
        var msixEnableWriteCount: UInt64 = 0
        var lastSummaryNanos: UInt64 = 0
    }
    private let targetIRQTraceLock = NSLock()
    private var targetIRQTrace = TargetIRQTrace()

    /// Opt-in counters for the standalone NVMe/MSI-X validation harness.  They
    /// are never printed or updated on the normal Windows boot path.
    private struct ValidationStats {
        var sqCommands: UInt64 = 0
        var reads: UInt64 = 0
        var writes: UInt64 = 0
        var cqesPosted: UInt64 = 0
        var cqesConsumed: UInt64 = 0
        var msixSends: UInt64 = 0
        var msixFailures: UInt64 = 0
        var legacyAssertionsWhileMSIX: UInt64 = 0
        var staleDrops: UInt64 = 0
        var controllerResets: UInt64 = 0
        var queueDeletes: UInt64 = 0
        var outstanding: UInt64 = 0
        var maxOutstanding: UInt64 = 0
        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0
    }
    private var validationStats: ValidationStats?

    private struct IntegrityStats {
        var acceptedBeforeGate: UInt64 = 0
        var rejectedAfterGate: UInt64 = 0
        var hostIOStartedAfterReset: UInt64 = 0
        var staleCompletions: UInt64 = 0
        var generationMismatches: UInt64 = 0
    }
    private var integrityStats = IntegrityStats()

    private func validationUpdate(_ body: (inout ValidationStats) -> Void) {
        statsLock.lock()
        if validationStats != nil { body(&validationStats!) }
        statsLock.unlock()
    }

    private func beginResetGate() {
        ioGate.lock()
        ioState = .resetting
        while admittedHostIO != 0 {
            ioGate.wait()
        }
        ioGate.unlock()
    }

    private func finishResetGate(disabled: Bool = true) {
        ioGate.lock()
        ioState = disabled ? .disabled : .running
        ioGate.broadcast()
        ioGate.unlock()
    }

    private func enableIOGate() {
        ioGate.lock()
        ioState = .running
        ioGate.broadcast()
        ioGate.unlock()
    }

    private func canDispatchIO() -> Bool {
        ioGate.lock()
        let allowed = ioState == .running
        ioGate.unlock()
        return allowed
    }

    /// Atomically admits a worker to begin host I/O. Once reset changes the
    /// state to resetting, no later worker can pass this point.
    private func beginHostIO() -> Bool {
        ioGate.lock()
        guard ioState == .running else {
            integrityStats.rejectedAfterGate &+= 1
            ioGate.unlock()
            return false
        }
        admittedHostIO &+= 1
        integrityStats.acceptedBeforeGate &+= 1
        ioGate.unlock()
        return true
    }

    private func finishHostIO() {
        ioGate.lock()
        admittedHostIO -= 1
        if admittedHostIO == 0 { ioGate.broadcast() }
        ioGate.unlock()
    }

    // MARK: - Initialization

    init() {
        initPCIConfig()
    }

    private func initPCIConfig() {
        // Vendor ID: 0x8086 (Intel), Device ID: 0x0953 (Intel NVMe Controller)
        configSpace[0x00] = 0x86
        configSpace[0x01] = 0x80
        configSpace[0x02] = 0x53
        configSpace[0x03] = 0x09

        // Command: 0x0000, Status: 0x0010 (Capabilities List present)
        configSpace[0x04] = 0x00
        configSpace[0x05] = 0x00
        configSpace[0x06] = 0x10
        configSpace[0x07] = 0x00

        // Revision: 0x01, Class Code: 0x010802 (Mass Storage / NVM / NVMe)
        configSpace[0x08] = 0x01
        configSpace[0x09] = 0x02 // ProgIF = 0x02 (NVMe)
        configSpace[0x0A] = 0x08 // SubClass = 0x08 (Non-Volatile Memory)
        configSpace[0x0B] = 0x01 // BaseClass = 0x01 (Mass Storage)

        // Header Type: 0x00 (standard Type 0)
        configSpace[0x0E] = 0x00

        // Subsystem Vendor ID / Subsystem ID: 0x09538086
        configSpace[0x2C] = 0x86
        configSpace[0x2D] = 0x80
        configSpace[0x2E] = 0x53
        configSpace[0x2F] = 0x09

        // Capabilities Pointer: 0x40
        configSpace[0x34] = 0x40

        // Interrupt Pin: 0x01 (INTA#)
        configSpace[0x3D] = 0x01

        // ─── Power Management Capability (Offset 0x40) ────────────
        configSpace[0x40] = 0x01 // Cap ID = PM
        configSpace[0x41] = 0x50 // Next Cap = 0x50 (PCIe)
        configSpace[0x42] = 0x03 // PMC: PM Spec 1.2
        configSpace[0x43] = 0x00
        configSpace[0x44] = 0x00 // PMCSR: D0
        configSpace[0x45] = 0x00

        // ─── PCI Express Capability (Offset 0x50) ─────────────────
        configSpace[0x50] = 0x10 // Cap ID = PCIe
        configSpace[0x51] = 0x90 // Next Cap = 0x90 (MSI-X)
        configSpace[0x52] = 0x02 // PCIe Caps: Version 2, Endpoint
        configSpace[0x53] = 0x00
        configSpace[0x54] = 0x01 // DevCaps: Max Payload 256
        configSpace[0x55] = 0x00
        configSpace[0x56] = 0x00
        configSpace[0x57] = 0x00
        configSpace[0x5C] = 0x11 // LinkCaps: 2.5 GT/s, x1
        configSpace[0x5D] = 0x00
        configSpace[0x5E] = 0x01
        configSpace[0x5F] = 0x00
        configSpace[0x62] = 0x11 // LinkStatus: 2.5 GT/s, x1
        configSpace[0x63] = 0x10

        // ─── MSI-X Capability (Offset 0x90) ──────────────────────
        // One vector: Table Size field = 0.  BAR2 is a dedicated 4 KiB
        // memory BAR, with Table at +0 and PBA at +0x800.
        configSpace[0x90] = 0x11 // Cap ID = MSI-X
        configSpace[0x91] = 0x00 // End of capability chain
        configSpace[0x94] = 0x02 // Table BIR = BAR2, offset = 0
        configSpace[0x95] = 0x00
        configSpace[0x96] = 0x00
        configSpace[0x97] = 0x00
        configSpace[0x98] = 0x02 // PBA BIR = BAR2, offset = 0x800
        configSpace[0x99] = 0x08
        configSpace[0x9A] = 0x00
        configSpace[0x9B] = 0x00
    }

    // MARK: - Setup & Configuration

    func configure(
        guestRAM: UnsafeMutableRawPointer,
        guestBase: UInt64,
        guestSize: Int,
        targetDiskPath: String,
        installerDiskPath: String? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        self.guestRAMHost = guestRAM
        self.guestRAMBase = guestBase
        self.guestRAMSize = guestSize

        self.targetDiskPath = targetDiskPath
        targetFD = open(targetDiskPath, O_RDWR)
        guard targetFD >= 0 else {
            print("❌ FluxNVMe: Failed to open target disk at \(targetDiskPath)")
            return false
        }

        var st = stat()
        if fstat(targetFD, &st) == 0 {
            targetSectors = UInt64(st.st_size) / sectorSize
        } else {
            targetSectors = (64 * 1024 * 1024 * 1024) / sectorSize
        }

        if let instPath = installerDiskPath {
            installerFD = open(instPath, O_RDONLY)
            if installerFD >= 0 {
                var instSt = stat()
                if fstat(installerFD, &instSt) == 0 {
                    installerSectors = UInt64(instSt.st_size) / sectorSize
                }
                numNamespaces = 2
                print("📀 FluxNVMe: Configured Namespace 2 (Installer) sectors=\(installerSectors) (ReadOnly)")
            } else {
                print("⚠️ FluxNVMe: Could not open installer disk at \(instPath); single namespace mode")
                numNamespaces = 1
            }
        } else {
            numNamespaces = 1
        }

        print("💾 FluxNVMe: Configured Namespace 1 (Target) sectors=\(targetSectors) (Read/Write)")
        logTargetDiskIdentity("after NVMe configure/open")
        return true
    }

    /// Coarse reset-boundary fingerprinting only. This never modifies the disk.
    @discardableResult
    func logTargetDiskIdentity(_ point: String) -> DiskIdentity? {
        guard targetFD >= 0 else {
            print("💽 [Disk Identity] \(point): target fd unavailable")
            return nil
        }

        var st = stat()
        guard fstat(targetFD, &st) == 0 else {
            print("💽 [Disk Identity] \(point): fstat failed (errno \(errno))")
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: 4096)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            pread(targetFD, buffer.baseAddress, buffer.count, 0)
        }
        guard readCount == 4096 else {
            print("💽 [Disk Identity] \(point): first-4KiB read failed (result \(readCount), errno \(errno))")
            return nil
        }

        var checksum: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            checksum ^= UInt64(byte)
            checksum &*= 0x100000001b3
        }
        let identity = DiskIdentity(
            inode: UInt64(st.st_ino),
            size: Int64(st.st_size),
            blocks: Int64(st.st_blocks),
            first4KiBChecksum: checksum
        )
        print("💽 [Disk Identity] \(point): path=\(targetDiskPath) fd=\(targetFD) inode=\(identity.inode) size=\(identity.size) blocks=\(identity.blocks) first4KiB=0x\(String(identity.first4KiBChecksum, radix: 16))")

        if let prior = lastLoggedTargetIdentity {
            if prior.inode != identity.inode {
                print("🚨 [Disk Identity] inode changed across reset boundary")
            }
            if prior.blocks > 0 && identity.blocks == 0 {
                print("🚨 [Disk Identity] allocated blocks collapsed to zero across reset boundary")
            }
        }
        lastLoggedTargetIdentity = identity
        return identity
    }

    func cleanup() {
        // Wait for any in-flight host I/O operations to complete and shut down worker pool
        workerPool.shutdown()

        lock.lock()
        cqLock.lock()
        defer {
            cqLock.unlock()
            lock.unlock()
        }

        controllerGeneration &+= 1

        if targetFD >= 0 {
            fsync(targetFD)
            close(targetFD)
            targetFD = -1
        }
        if installerFD >= 0 {
            close(installerFD)
            installerFD = -1
        }
        resetGICLine()
        emitTargetIRQTraceSummary()
    }

    private func emitTargetIRQTraceSummary() {
        guard Self.traceTargetIRQ else { return }
        targetIRQTraceLock.lock()
        let trace = targetIRQTrace
        targetIRQTraceLock.unlock()
        print("[TARGET-IRQ SUMMARY] spi50 assert=\(trace.spi50AssertCount) deassert=\(trace.spi50DeassertCount) pendingSamples=\(trace.spi50PendingSamples) activeSamples=\(trace.spi50ActiveSamples) cq1Tail=\(trace.cq1TailAdvanceCount) cq1Head=\(trace.cq1HeadAdvanceCount) cq1MaxUnread=\(trace.cq1MaxUnread) msixCapReads=\(trace.msixCapabilityReadCount) msixEnableWrites=\(trace.msixEnableWriteCount) IAR50=UNAVAILABLE EOIR50=UNAVAILABLE")
    }

    /// Resets the NVMe controller state across a guest platform reboot.
    func reset() {
        logTargetDiskIdentity("immediately before workerPool.drain")
        // Close admission before draining. New doorbells can no longer create
        // host work, and queued jobs fail their admission check without I/O.
        beginResetGate()
        workerPool.drain()
        logTargetDiskIdentity("after workerPool.drain")

        lock.lock()
        cqLock.lock()
        defer {
            cqLock.unlock()
            lock.unlock()
        }

        controllerGeneration &+= 1

        regCC = 0
        regCSTS = 0
        regINTMS = 0
        regAQA = 0
        regASQ = 0
        regACQ = 0
        sqs.removeAll()
        cqs.removeAll()
        resetGICLine()
        if targetFD >= 0 {
            fsync(targetFD)
        }
        print("🔄 FluxNVMe: Controller reset for guest reboot (epoch \(controllerGeneration))")
        logTargetDiskIdentity("after NVMe reset")
        finishResetGate()
    }

    // MARK: - Host Pointer Translation

    private func hostPointer(forGuestAddress gpa: UInt64) -> UnsafeMutableRawPointer? {
        guard gpa >= guestRAMBase && gpa < (guestRAMBase + UInt64(guestRAMSize)) else {
            return nil
        }
        let offset = Int(gpa - guestRAMBase)
        return guestRAMHost?.advanced(by: offset)
    }

    // MARK: - MSI-X state and BAR2

    private var msixEnabled: Bool {
        msixLock.lock()
        defer { msixLock.unlock() }
        return (msixMessageControl & 0x8000) != 0
    }

    private func msixByteLocked(at offset: UInt64) -> UInt8 {
        let value: UInt32
        switch offset {
        case Self.msixTableOffset..<Self.msixTableOffset + 4:
            value = msixTableEntry.addressLow
        case Self.msixTableOffset + 4..<Self.msixTableOffset + 8:
            value = msixTableEntry.addressHigh
        case Self.msixTableOffset + 8..<Self.msixTableOffset + 12:
            value = msixTableEntry.data
        case Self.msixTableOffset + 12..<Self.msixTableOffset + 16:
            value = msixTableEntry.vectorControl
        case Self.msixPBAOffset..<Self.msixPBAOffset + 8:
            return UInt8((msixPendingBits >> ((offset - Self.msixPBAOffset) * 8)) & 0xFF)
        default:
            return 0
        }
        let shift = UInt32((offset & 3) * 8)
        return UInt8((value >> shift) & 0xFF)
    }

    private func readMSIXBAR(offset: UInt64, size: Int) -> UInt64 {
        msixLock.lock()
        defer { msixLock.unlock() }
        var result: UInt64 = 0
        for i in 0..<size {
            result |= UInt64(msixByteLocked(at: offset + UInt64(i))) << UInt64(i * 8)
        }
        return result
    }

    /// Returns a message only after clearing the PBA bit under the MSI-X lock.
    /// The actual GIC call is deliberately made after every device lock is out
    /// of scope.
    private func prepareMSIXDelivery(markPending: Bool) -> MSIDelivery? {
        msixLock.lock()
        defer { msixLock.unlock() }

        guard (msixMessageControl & 0x8000) != 0 else { return nil }
        if markPending {
            msixPendingBits |= 1
        }
        guard (msixMessageControl & 0x4000) == 0,
              !msixTableEntry.masked,
              (msixPendingBits & 1) != 0 else {
            return nil
        }

        let address = hv_ipa_t(msixTableEntry.address)
        let intid = msixTableEntry.data
        guard FluxGIC.validMSI(address: address, intid: intid) else {
            if Self.verbose {
                print("⚠️ FluxNVMe: rejected MSI-X message addr=0x\(String(address, radix: 16)) data=\(intid)")
            }
            return nil
        }
        msixPendingBits &= ~UInt64(1)
        return MSIDelivery(address: address, intid: intid)
    }

    private func sendMSIX(_ delivery: MSIDelivery?) {
        guard let delivery else { return }
        let result = hv_gic_send_msi(delivery.address, delivery.intid)
        validationUpdate {
            $0.msixSends += 1
            if result != HV_SUCCESS { $0.msixFailures += 1 }
        }
        if Self.verbose || result != HV_SUCCESS {
            print("⚡️ FluxNVMe: MSI-X addr=0x\(String(delivery.address, radix: 16)) data=\(delivery.intid) -> \(result)")
        }
        if result == HV_SUCCESS {
            onInterruptPending?()
        }
    }

    private func writeMSIXBAR(offset: UInt64, value: UInt64, size: Int) -> MSIDelivery? {
        msixLock.lock()
        for i in 0..<size {
            let byteOffset = offset + UInt64(i)
            let byte = UInt32((value >> UInt64(i * 8)) & 0xFF)
            let shift = UInt32((byteOffset & 3) * 8)
            switch byteOffset {
            case Self.msixTableOffset..<Self.msixTableOffset + 4:
                msixTableEntry.addressLow = (msixTableEntry.addressLow & ~(0xFF << shift)) | (byte << shift)
            case Self.msixTableOffset + 4..<Self.msixTableOffset + 8:
                msixTableEntry.addressHigh = (msixTableEntry.addressHigh & ~(0xFF << shift)) | (byte << shift)
            case Self.msixTableOffset + 8..<Self.msixTableOffset + 12:
                msixTableEntry.data = (msixTableEntry.data & ~(0xFF << shift)) | (byte << shift)
            case Self.msixTableOffset + 12..<Self.msixTableOffset + 16:
                msixTableEntry.vectorControl = (msixTableEntry.vectorControl & ~(0xFF << shift)) | (byte << shift)
            default:
                break // PBA is read-only
            }
        }
        if Self.verbose {
            print(
                "PCI_MSIX table0: addr=0x\(String(msixTableEntry.address, radix: 16)) " +
                "data=\(msixTableEntry.data) vectorMask=\(msixTableEntry.masked) " +
                "pba=0x\(String(msixPendingBits, radix: 16))"
            )
        }
        msixLock.unlock()
        return prepareMSIXDelivery(markPending: false)
    }

    private func writeMSIXControl(offset: UInt32, value: UInt64, size: Int) -> (becameEnabled: Bool, delivery: MSIDelivery?) {
        msixLock.lock()
        let wasEnabled = (msixMessageControl & 0x8000) != 0
        var control = msixMessageControl
        for i in 0..<size {
            let configOffset = Int(offset) + i
            guard configOffset == Self.msixCapabilityOffset + 2 || configOffset == Self.msixCapabilityOffset + 3 else { continue }
            let shift = UInt16((configOffset - (Self.msixCapabilityOffset + 2)) * 8)
            let byte = UInt16((value >> UInt64(i * 8)) & 0xFF)
            control = (control & ~(UInt16(0xFF) << shift)) | (byte << shift)
        }
        msixMessageControl = control & 0xC000
        let becameEnabled = !wasEnabled && (msixMessageControl & 0x8000) != 0
        if Self.verbose {
            print(
                "PCI_MSIX control: enable=\((msixMessageControl & 0x8000) != 0) " +
                "functionMask=\((msixMessageControl & 0x4000) != 0)"
            )
        }
        msixLock.unlock()
        return (becameEnabled, prepareMSIXDelivery(markPending: false))
    }

    private func isMSIXBARAddress(_ address: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard (pciCommand & 0x02) != 0, bar2Base != 0 else { return false }
        return address >= bar2Base && address < bar2Base + bar2Size
    }

    // MARK: - PCI Configuration Space Access

    func readPCIConfig(offset: UInt32, size: Int) -> UInt64 {
        guard offset < 0x100 else { return 0 }

        lock.lock()
        defer { lock.unlock() }

        let reg = offset
        var result: UInt64 = 0
        for i in 0..<size {
            let idx = Int(reg) + i
            result |= UInt64(pciConfigByte(at: idx)) << (i * 8)
        }
        if Self.verbose && reg != 0x04 && reg != 0x06 {
            print("PCI_CFG RD [NVMe]: reg=0x\(String(reg, radix: 16)) size=\(size) -> 0x\(String(result, radix: 16))")
        }
        if reg == 0x34 || reg == 0x40 || reg == 0x44 || reg == 0x50 || reg == 0x90 {
            if reg == 0x90 {
                targetIRQTraceLock.lock(); targetIRQTrace.msixCapabilityReadCount &+= 1; targetIRQTraceLock.unlock()
            }
            tracePCI("read", offset: reg, value: result)
        }
        return result
    }

    private func pciConfigByte(at offset: Int) -> UInt8 {
        guard offset >= 0 && offset < 0x100 else { return 0 }

        switch offset {
        case 0x10...0x13:
            let value: UInt32 = bar0Sizing
                ? (0xFFFF_E000 | 0x04) // 64-bit, non-prefetchable memory BAR
                : (UInt32(bar0Base & 0xFFFF_FFFF) | 0x04)
            return UInt8((value >> UInt32((offset - 0x10) * 8)) & 0xFF)
        case 0x14...0x17:
            let value: UInt32 = bar1Sizing ? 0xFFFF_FFFF : UInt32(bar0Base >> 32)
            return UInt8((value >> UInt32((offset - 0x14) * 8)) & 0xFF)
        case 0x18...0x1B:
            let value: UInt32 = bar2Sizing ? 0xFFFF_F000 : UInt32(bar2Base & 0xFFFF_FFFF)
            return UInt8((value >> UInt32((offset - 0x18) * 8)) & 0xFF)
        case Self.msixCapabilityOffset + 2...Self.msixCapabilityOffset + 3:
            msixLock.lock()
            let value = msixMessageControl
            msixLock.unlock()
            return UInt8((value >> UInt16((offset - (Self.msixCapabilityOffset + 2)) * 8)) & 0xFF)
        case 0x1C...0x27, 0x30...0x33:
            return 0
        default:
            return configSpace[offset]
        }
    }

    func writePCIConfig(offset: UInt32, value: UInt64, size: Int) {
        guard offset < 0x100 else { return }

        let msixControlStart = UInt32(Self.msixCapabilityOffset + 2)
        let msixControlEnd = msixControlStart + 2
        if offset < msixControlEnd && offset + UInt32(size) > msixControlStart {
            let update = writeMSIXControl(offset: offset, value: value, size: size)
            if Self.traceTargetIRQ {
                targetIRQTraceLock.lock()
                if update.becameEnabled { targetIRQTrace.msixEnableWriteCount &+= 1 }
                targetIRQTraceLock.unlock()
                tracePCI("write-msix-control", offset: offset, value: value)
            }
            if update.becameEnabled {
                // A level-triggered fallback must never remain asserted after
                // the function enters message-signalled operation.
                resetGICLine()
            }
            sendMSIX(update.delivery)
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let reg = offset

        if Self.verbose {
            print("PCI_CFG WR [NVMe]: reg=0x\(String(reg, radix: 16)) size=\(size) val=0x\(String(value, radix: 16))")
        }
        if reg == 0x04 || reg == 0x44 || reg == 0x40 || reg == 0x50 || reg == 0x90 {
            tracePCI("write", offset: reg, value: value)
        }

        if reg == 0x10 && size == 8 {
            let low32 = UInt32(value & 0xFFFF_FFFF)
            let high32 = UInt32((value >> 32) & 0xFFFF_FFFF)
            bar0Sizing = (low32 == 0xFFFF_FFFF)
            bar1Sizing = (high32 == 0xFFFF_FFFF)
            if !bar0Sizing && !bar1Sizing {
                bar0Base = (UInt64(high32) << 32) | UInt64(low32 & 0xFFFF_E000)
                print("📍 FluxNVMe: 64-bit BAR0 set to 0x\(String(bar0Base, radix: 16))")
            }
            return
        }

        if reg >= 0x10 && reg < 0x14 {
            let byteCount = min(size, Int(0x14 - reg))
            if reg == 0x10 && byteCount == 4 && UInt32(value & 0xFFFF_FFFF) == 0xFFFF_FFFF {
                bar0Sizing = true
            } else {
                bar0Sizing = false
                var current = UInt32(bar0Base & 0xFFFF_FFFF) | 0x04
                for i in 0..<byteCount {
                    let shift = UInt32((Int(reg) - 0x10 + i) * 8)
                    let byte = UInt32((value >> (i * 8)) & 0xFF)
                    current = (current & ~(0xFF << shift)) | (byte << shift)
                }
                bar0Base = (bar0Base & 0xFFFF_FFFF_0000_0000) | UInt64(current & 0xFFFF_E000)
                if Self.verbose {
                    print("📍 FluxNVMe: BAR0 set to 0x\(String(bar0Base, radix: 16))")
                }
            }
            return
        }

        if reg >= 0x14 && reg < 0x18 {
            let byteCount = min(size, Int(0x18 - reg))
            if reg == 0x14 && byteCount == 4 && UInt32(value & 0xFFFF_FFFF) == 0xFFFF_FFFF {
                bar1Sizing = true
            } else {
                bar1Sizing = false
                var current = UInt32(bar0Base >> 32)
                for i in 0..<byteCount {
                    let shift = UInt32((Int(reg) - 0x14 + i) * 8)
                    let byte = UInt32((value >> (i * 8)) & 0xFF)
                    current = (current & ~(0xFF << shift)) | (byte << shift)
                }
                bar0Base = (bar0Base & 0x0000_0000_FFFF_FFFF) | (UInt64(current) << 32)
                if Self.verbose {
                    print("📍 FluxNVMe: BAR0 high set to 0x\(String(bar0Base, radix: 16))")
                }
            }
            return
        }

        if reg >= 0x18 && reg < 0x1C {
            let byteCount = min(size, Int(0x1C - reg))
            if reg == 0x18 && byteCount == 4 && UInt32(value & 0xFFFF_FFFF) == 0xFFFF_FFFF {
                bar2Sizing = true
            } else {
                bar2Sizing = false
                var current = UInt32(bar2Base & 0xFFFF_FFFF)
                for i in 0..<byteCount {
                    let shift = UInt32((Int(reg) - 0x18 + i) * 8)
                    let byte = UInt32((value >> (i * 8)) & 0xFF)
                    current = (current & ~(0xFF << shift)) | (byte << shift)
                }
                bar2Base = UInt64(current & 0xFFFF_F000)
                if Self.verbose {
                    print("📍 FluxNVMe: MSI-X BAR2 set to 0x\(String(bar2Base, radix: 16))")
                }
            }
            return
        }

        if reg >= 0x1C && reg < 0x28 { return }
        if reg >= 0x30 && reg < 0x34 { return }

        if reg >= 0x04 && reg < 0x06 {
            let byteCount = min(size, Int(0x06 - reg))
            for i in 0..<byteCount {
                configSpace[Int(reg) + i] = UInt8((value >> (i * 8)) & 0xFF)
            }
            pciCommand = UInt16(configSpace[0x04]) | (UInt16(configSpace[0x05]) << 8)
            tracePCI("command", offset: reg, value: UInt64(pciCommand))
            if Self.verbose {
                print("⚙️ FluxNVMe: PCI Command = 0x\(String(pciCommand, radix: 16)) (MSE=\((pciCommand >> 1) & 1), BME=\((pciCommand >> 2) & 1))")
            }
            onPCICommandWrite?(pciCommand)
            return
        }

        if reg == 0x3C {
            configSpace[0x3C] = UInt8(value & 0xFF)
            return
        }

        if reg == 0x44 && size >= 2 {
            let requested = UInt16(value & 0xFFFF)
            let requestedState = UInt8(requested & 0x3)
            let oldState = configSpace[0x44] & 0x3
            let newState: UInt8 = (requestedState == 3) ? 3 : 0

            configSpace[0x44] = newState
            configSpace[0x45] = 0
            tracePCI("pmcsr", offset: reg, value: UInt64(newState), old: UInt64(oldState))

            if Self.verbose {
                print("⚡ FluxNVMe: PCI power D\(oldState) -> D\(newState) (PMCSR write=0x\(String(requested, radix: 16)))")
            }

            if newState == 3 && oldState != 3 {
                controllerGeneration &+= 1
                workerPool.drain()
                cqLock.lock()
                regCC = 0
                regCSTS = 0
                regINTMS = 0
                regAQA = 0
                regASQ = 0
                regACQ = 0
                sqs.removeAll()
                cqs.removeAll()
                resetGICLine()
                if targetFD >= 0 {
                    fsync(targetFD)
                }
                cqLock.unlock()
                if Self.verbose {
                    print("🛑 FluxNVMe: Controller reset for PCI D3hot (epoch \(controllerGeneration))")
                }
            }
            return
        }

        for i in 0..<size {
            let idx = Int(reg) + i
            if idx < configSpace.count {
                configSpace[idx] = UInt8((value >> (i * 8)) & 0xFF)
            }
        }
    }

    // MARK: - MMIO Address Check

    func containsMMIO(_ gpa: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bar0Base != 0 && (pciCommand & 0x02) != 0 else {
            return bar2Base != 0 && (pciCommand & 0x02) != 0 &&
                gpa >= bar2Base && gpa < (bar2Base + bar2Size)
        }
        return (gpa >= bar0Base && gpa < (bar0Base + bar0Size)) ||
            (bar2Base != 0 && gpa >= bar2Base && gpa < (bar2Base + bar2Size))
    }

    // MARK: - MMIO Register Read/Write

    private func mmioName(_ offset: UInt64) -> String {
        switch offset {
        case 0x00: return "CAP.LO"
        case 0x04: return "CAP.HI"
        case 0x08: return "VS"
        case 0x0C: return "INTMS"
        case 0x10: return "INTMC"
        case 0x14: return "CC"
        case 0x1C: return "CSTS"
        case 0x24: return "AQA"
        case 0x28: return "ASQ.LO"
        case 0x2C: return "ASQ.HI"
        case 0x30: return "ACQ.LO"
        case 0x34: return "ACQ.HI"
        default:
            if offset >= 0x1000 {
                let d = offset - 0x1000
                let qid = d / 8
                return (d % 8) >= 4 ? "CQ\(qid).HEAD" : "SQ\(qid).TAIL"
            }
            return "UNKNOWN"
        }
    }

    func readMMIO(address: UInt64, size: Int) -> UInt64 {
        if isMSIXBARAddress(address) {
            return readMSIXBAR(offset: address - bar2Base, size: size)
        }
        lock.lock()
        defer { lock.unlock() }

        let offset = address - bar0Base

        if Self.verbose {
            print("🔵 NVME_MMIO RD \(mmioName(offset)) off=0x\(String(offset, radix: 16)) size=\(size) CC=0x\(String(regCC, radix: 16)) CSTS=0x\(String(regCSTS, radix: 16))")
        }

        switch offset {
        case 0x00: return size == 8 ? regCAP : (regCAP & 0xFFFF_FFFF)
        case 0x04: return (regCAP >> 32) & 0xFFFF_FFFF
        case 0x08: return UInt64(regVS)
        case 0x0C: return UInt64(regINTMS)
        case 0x10: return UInt64(regINTMS)
        case 0x14: return UInt64(regCC)
        case 0x1C: return UInt64(regCSTS)
        case 0x24: return UInt64(regAQA)
        case 0x28: return size == 8 ? regASQ : (regASQ & 0xFFFF_FFFF)
        case 0x2C: return (regASQ >> 32) & 0xFFFF_FFFF
        case 0x30: return size == 8 ? regACQ : (regACQ & 0xFFFF_FFFF)
        case 0x34: return (regACQ >> 32) & 0xFFFF_FFFF
        default:
            if Self.verbose {
                print("⚠️ FluxNVMe: Unhandled read @ offset 0x\(String(offset, radix: 16)) size=\(size)")
            }
            return 0
        }
    }

    func writeMMIO(address: UInt64, value: UInt64, size: Int) {
        if isMSIXBARAddress(address) {
            let delivery = writeMSIXBAR(offset: address - bar2Base, value: value, size: size)
            sendMSIX(delivery)
            return
        }
        lock.lock()
        defer { lock.unlock() }

        let offset = address - bar0Base

        if Self.verbose {
            print("🟠 NVME_MMIO WR \(mmioName(offset)) off=0x\(String(offset, radix: 16)) val=0x\(String(value, radix: 16)) size=\(size)")
        }

        switch offset {
        case 0x0C: // INTMS
            cqLock.lock()
            regINTMS |= UInt32(value & 0xFFFF_FFFF)
            let (targetLine, shouldWake, seq) = evaluateInterruptStateLocked(isNewCompletion: false)
            cqLock.unlock()
            updateGICLine(targetLine, sequence: seq)
            if shouldWake {
                onInterruptPending?()
            }

        case 0x10: // INTMC
            cqLock.lock()
            regINTMS &= ~UInt32(value & 0xFFFF_FFFF)
            let (targetLine, shouldWake, seq) = evaluateInterruptStateLocked(isNewCompletion: true)
            cqLock.unlock()
            updateGICLine(targetLine, sequence: seq)
            if shouldWake {
                onInterruptPending?()
            }

        case 0x14: // CC
            let oldCC = regCC
            regCC = UInt32(value & 0xFFFF_FFFF)
            let enabled = (regCC & 1) == 1
            let oldEnabled = (oldCC & 1) == 1

            if enabled && !oldEnabled {
                let asqSize = UInt16(regAQA & 0xFFF) + 1
                let acqSize = UInt16((regAQA >> 16) & 0xFFF) + 1
                sqs.removeAll()
                cqLock.lock()
                cqs.removeAll()
                sqs[0] = NVMeSQ(base: regASQ, size: asqSize, head: 0, tail: 0, cqId: 0)
                cqs[0] = NVMeCQ(base: regACQ, size: acqSize, head: 0, tail: 0, phase: 1)
                cqLock.unlock()
                regCSTS |= 1 // RDY = 1
                enableIOGate()
                print("🚀 FluxNVMe: Controller Enabled (ASQ=0x\(String(regASQ, radix: 16)) size=\(asqSize), ACQ=0x\(String(regACQ, radix: 16)) size=\(acqSize))")
            } else if !enabled && oldEnabled {
                controllerGeneration &+= 1
                workerPool.drain()
                cqLock.lock()
                sqs.removeAll()
                cqs.removeAll()
                regCSTS &= ~1
                regCSTS &= ~0x0C
                resetGICLine()
                if targetFD >= 0 {
                    fsync(targetFD)
                }
                cqLock.unlock()
                print("🛑 FluxNVMe: Controller Disabled (epoch \(controllerGeneration))")
            }

            let shn = (regCC >> 14) & 3
            if shn != 0 {
                regCSTS = (regCSTS & ~0x0C) | (2 << 2) // SHST = 2
            }

        case 0x24:
            regAQA = UInt32(value & 0xFFFF_FFFF)

        case 0x28:
            if size == 8 {
                regASQ = value
            } else {
                regASQ = (regASQ & 0xFFFF_FFFF_0000_0000) | UInt64(value & 0xFFFF_FFFF)
            }

        case 0x2C:
            regASQ = (regASQ & 0x0000_0000_FFFF_FFFF) | (UInt64(value & 0xFFFF_FFFF) << 32)

        case 0x30:
            if size == 8 {
                regACQ = value
            } else {
                regACQ = (regACQ & 0xFFFF_FFFF_0000_0000) | UInt64(value & 0xFFFF_FFFF)
            }

        case 0x34:
            regACQ = (regACQ & 0x0000_0000_FFFF_FFFF) | (UInt64(value & 0xFFFF_FFFF) << 32)

        default:
            if offset >= 0x1000 {
                let dbOffset = offset - 0x1000
                let qid = UInt16(dbOffset / 8)
                let isCQ = (dbOffset % 8) >= 4

                if isCQ {
                    cqLock.lock()
                    cqs[qid]?.head = UInt16(value & 0xFFFF)
                    validationUpdate { $0.cqesConsumed += 1 }
                    let (targetLine, shouldWake, seq) = evaluateInterruptStateLocked(isNewCompletion: false)
                    cqLock.unlock()
                    if qid == 1 { traceQueue1("cq-head") }
                    updateGICLine(targetLine, sequence: seq)
                    if shouldWake {
                        onInterruptPending?()
                    }
                } else {
                    sqs[qid]?.tail = UInt16(value & 0xFFFF)
                    if qid == 1 { traceQueue1("sq-tail") }
                    if qid == 0 {
                        processAdminQueueLocked()
                    } else {
                        dispatchIOQueueLocked(sqid: qid)
                    }
                }
            } else if Self.verbose {
                print("⚠️ FluxNVMe: Unhandled write @ offset 0x\(String(offset, radix: 16)) val=0x\(String(value, radix: 16)) size=\(size)")
            }
        }
    }

    // MARK: - Admin Queue Processing

    private func processAdminQueueLocked() {
        guard var sq = sqs[0], sq.size > 0 && sq.base != 0 else { return }

        while sq.head != sq.tail {
            let sqeAddr = sq.base + UInt64(sq.head) * 64
            guard let sqePtr = hostPointer(forGuestAddress: sqeAddr) else {
                print("❌ FluxNVMe: Invalid ASQ host address @ 0x\(String(sqeAddr, radix: 16))")
                break
            }

            let opc = sqePtr.load(fromByteOffset: 0, as: UInt8.self)
            let cid = sqePtr.load(fromByteOffset: 2, as: UInt16.self)
            let nsid = sqePtr.load(fromByteOffset: 4, as: UInt32.self)
            let prp1 = sqePtr.load(fromByteOffset: 24, as: UInt64.self)
            let prp2 = sqePtr.load(fromByteOffset: 32, as: UInt64.self)
            let cdw10 = sqePtr.load(fromByteOffset: 40, as: UInt32.self)
            let cdw11 = sqePtr.load(fromByteOffset: 44, as: UInt32.self)

            sq.head = (sq.head + 1) % sq.size
            sqs[0] = sq

            executeAdminCommandLocked(opc: opc, cid: cid, nsid: nsid, prp1: prp1, prp2: prp2, cdw10: cdw10, cdw11: cdw11)
        }
    }

    private func executeAdminCommandLocked(
        opc: UInt8,
        cid: UInt16,
        nsid: UInt32,
        prp1: UInt64,
        prp2: UInt64,
        cdw10: UInt32,
        cdw11: UInt32
    ) {
        switch opc {
        case 0x06: // Identify
            let cns = cdw10 & 0xFF
            if cns == 0x01 {
                handleIdentifyControllerLocked(cid: cid, prp1: prp1)
            } else if cns == 0x00 {
                handleIdentifyNamespaceLocked(cid: cid, nsid: nsid, prp1: prp1)
            } else if cns == 0x02 {
                handleActiveNamespaceListLocked(cid: cid, startNSID: nsid, prp1: prp1)
            } else if cns == 0x03 {
                handleNamespaceIDDescriptorListLocked(cid: cid, nsid: nsid, prp1: prp1)
            } else {
                if let host = hostPointer(forGuestAddress: prp1) {
                    memset(host, 0, 4096)
                }
                postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)
            }

        case 0x05: // Create I/O CQ
            let qid = UInt16(cdw10 & 0xFFFF)
            let qsize = UInt16((cdw10 >> 16) & 0xFFFF) + 1
            cqLock.lock()
            cqs[qid] = NVMeCQ(base: prp1, size: qsize, head: 0, tail: 0, phase: 1)
            cqLock.unlock()
            if Self.verbose {
                print("📋 FluxNVMe: Created I/O CQ (QID=\(qid), size=\(qsize), Base=0x\(String(prp1, radix: 16)))")
            }
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)

        case 0x01: // Create I/O SQ
            let qid = UInt16(cdw10 & 0xFFFF)
            let qsize = UInt16((cdw10 >> 16) & 0xFFFF) + 1
            let cqId = UInt16((cdw11 >> 16) & 0xFFFF)
            sqs[qid] = NVMeSQ(base: prp1, size: qsize, head: 0, tail: 0, cqId: cqId)
            if Self.verbose {
                print("📋 FluxNVMe: Created I/O SQ (QID=\(qid), size=\(qsize), CQID=\(cqId), Base=0x\(String(prp1, radix: 16)))")
            }
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)

        case 0x00: // Delete I/O CQ
            let qid = UInt16(cdw10 & 0xFFFF)
            workerPool.drain()
            cqLock.lock()
            cqs.removeValue(forKey: qid)
            cqLock.unlock()
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)

        case 0x04: // Delete I/O SQ
            let qid = UInt16(cdw10 & 0xFFFF)
            workerPool.drain()
            sqs.removeValue(forKey: qid)
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)

        case 0x09: // Set Features
            let fid = cdw10 & 0xFF
            var dw0: UInt32 = 0
            if fid == 0x07 {
                // Return 1 I/O SQ and 1 I/O CQ (0-based: 0 means 1 queue).
                // Under pin-based legacy INTx, a single consolidated queue prevents
                // multi-queue ISR starvation and eliminate DPC watchdog violations.
                dw0 = (0 << 16) | 0
            }
            postAdminCompletionLocked(cid: cid, dw0: dw0, status: 0)

        case 0x0A: // Get Features
            let fid = cdw10 & 0xFF
            var dw0: UInt32 = 0
            if fid == 0x07 {
                dw0 = (0 << 16) | 0
            }
            postAdminCompletionLocked(cid: cid, dw0: dw0, status: 0)

        case 0x02: // Get Log Page
            if let host = hostPointer(forGuestAddress: prp1) {
                let numDwords = ((cdw10 >> 16) & 0xFFF) + 1
                memset(host, 0, Int(numDwords * 4))
            }
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)

        case 0x08: // Abort
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)

        case 0x0C: // Asynchronous Event Request
            break

        default:
            if Self.verbose {
                print("⚠️ FluxNVMe: Unhandled Admin Opcode 0x\(String(opc, radix: 16)) CID=\(cid)")
            }
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)
        }
    }

    private func handleIdentifyControllerLocked(cid: UInt16, prp1: UInt64) {
        guard let host = hostPointer(forGuestAddress: prp1) else {
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0x0002)
            return
        }

        memset(host, 0, 4096)
        host.storeBytes(of: UInt16(0x8086).littleEndian, toByteOffset: 0, as: UInt16.self)
        host.storeBytes(of: UInt16(0x8086).littleEndian, toByteOffset: 2, as: UInt16.self)

        writeASCII("FLUXNVME00000001    ", to: host.advanced(by: 4), count: 20)
        writeASCII("Flux Virtual NVMe Disk                 ", to: host.advanced(by: 24), count: 40)
        writeASCII("1.0     ", to: host.advanced(by: 64), count: 8)

        host.storeBytes(of: UInt8(6), toByteOffset: 77, as: UInt8.self) // MDTS = 256 KB
        host.storeBytes(of: UInt16(1).littleEndian, toByteOffset: 78, as: UInt16.self)
        host.storeBytes(of: UInt32(0x00010300).littleEndian, toByteOffset: 80, as: UInt32.self)

        host.storeBytes(of: UInt8(4), toByteOffset: 258, as: UInt8.self)
        host.storeBytes(of: UInt8(3), toByteOffset: 259, as: UInt8.self)
        host.storeBytes(of: UInt8(63), toByteOffset: 262, as: UInt8.self)
        host.storeBytes(of: UInt8(0), toByteOffset: 263, as: UInt8.self)

        host.storeBytes(of: UInt8(0x66), toByteOffset: 512, as: UInt8.self)
        host.storeBytes(of: UInt8(0x44), toByteOffset: 513, as: UInt8.self)
        host.storeBytes(of: UInt32(numNamespaces).littleEndian, toByteOffset: 516, as: UInt32.self)
        host.storeBytes(of: UInt16(0x000E).littleEndian, toByteOffset: 520, as: UInt16.self)
        host.storeBytes(of: UInt8(1), toByteOffset: 525, as: UInt8.self) // VWC = 1
        host.storeBytes(of: UInt16(0x03E8).littleEndian, toByteOffset: 2048, as: UInt16.self)

        postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)
    }

    private func handleIdentifyNamespaceLocked(cid: UInt16, nsid: UInt32, prp1: UInt64) {
        guard let host = hostPointer(forGuestAddress: prp1) else {
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0x0002)
            return
        }

        memset(host, 0, 4096)
        let sectors: UInt64
        if nsid == 1 {
            sectors = targetSectors
        } else if nsid == 2 && installerFD >= 0 {
            sectors = installerSectors
        } else {
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0x200B)
            return
        }

        host.storeBytes(of: sectors.littleEndian, toByteOffset: 0, as: UInt64.self)
        host.storeBytes(of: sectors.littleEndian, toByteOffset: 8, as: UInt64.self)
        host.storeBytes(of: sectors.littleEndian, toByteOffset: 16, as: UInt64.self)
        host.storeBytes(of: UInt8(0), toByteOffset: 25, as: UInt8.self)
        host.storeBytes(of: UInt8(0), toByteOffset: 26, as: UInt8.self)

        host.storeBytes(of: UInt64(0x464C555800000000 | UInt64(nsid)).bigEndian, toByteOffset: 104, as: UInt64.self)
        host.storeBytes(of: UInt64(nsid).bigEndian, toByteOffset: 112, as: UInt64.self)
        host.storeBytes(of: UInt64(0x5452000000000000 | UInt64(nsid)).bigEndian, toByteOffset: 120, as: UInt64.self)

        host.storeBytes(of: UInt16(0).littleEndian, toByteOffset: 128, as: UInt16.self)
        host.storeBytes(of: UInt8(9), toByteOffset: 130, as: UInt8.self) // 512 bytes
        host.storeBytes(of: UInt8(0), toByteOffset: 131, as: UInt8.self)

        postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)
    }

    private func handleActiveNamespaceListLocked(cid: UInt16, startNSID: UInt32, prp1: UInt64) {
        guard let host = hostPointer(forGuestAddress: prp1) else {
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0x0002)
            return
        }
        memset(host, 0, 4096)
        var offset = 0
        for id: UInt32 in 1...UInt32(numNamespaces) {
            if id > startNSID && offset + 4 <= 4096 {
                host.storeBytes(of: id.littleEndian, toByteOffset: offset, as: UInt32.self)
                offset += 4
            }
        }
        postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)
    }

    private func handleNamespaceIDDescriptorListLocked(cid: UInt16, nsid: UInt32, prp1: UInt64) {
        guard let host = hostPointer(forGuestAddress: prp1) else {
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0x0002)
            return
        }
        memset(host, 0, 4096)

        guard nsid == 1 || (nsid == 2 && installerFD >= 0) else {
            postAdminCompletionLocked(cid: cid, dw0: 0, status: 0x200B)
            return
        }

        host.storeBytes(of: UInt8(0x02), toByteOffset: 0, as: UInt8.self)
        host.storeBytes(of: UInt8(16), toByteOffset: 1, as: UInt8.self)
        host.storeBytes(of: UInt16(0), toByteOffset: 2, as: UInt16.self)
        host.storeBytes(of: UInt64(0x464C555800000000 | UInt64(nsid)).bigEndian, toByteOffset: 4, as: UInt64.self)
        host.storeBytes(of: UInt64(nsid).bigEndian, toByteOffset: 12, as: UInt64.self)

        host.storeBytes(of: UInt8(0x01), toByteOffset: 20, as: UInt8.self)
        host.storeBytes(of: UInt8(8), toByteOffset: 21, as: UInt8.self)
        host.storeBytes(of: UInt16(0), toByteOffset: 22, as: UInt16.self)
        host.storeBytes(of: UInt64(0x5452000000000000 | UInt64(nsid)).bigEndian, toByteOffset: 24, as: UInt64.self)

        postAdminCompletionLocked(cid: cid, dw0: 0, status: 0)
    }

    private func writeASCII(_ str: String, to ptr: UnsafeMutableRawPointer, count: Int) {
        let utf8 = [UInt8](str.utf8)
        for i in 0..<count {
            let byte = i < utf8.count ? utf8[i] : 0x20
            ptr.storeBytes(of: byte, toByteOffset: i, as: UInt8.self)
        }
    }

    private func postAdminCompletionLocked(cid: UInt16, dw0: UInt32, status: UInt16) {
        completeIORequest(generation: controllerGeneration, sqid: 0, cqId: 0, cid: cid, dw0: dw0, status: status)
    }

    private var hasPendingCompletionsLocked: Bool {
        for cq in cqs.values {
            if cq.head != cq.tail {
                return true
            }
        }
        return false
    }

    // MARK: - Interrupt Management

    private func evaluateInterruptStateLocked(isNewCompletion: Bool = false) -> (targetLevel: Bool, shouldWake: Bool, sequence: UInt64) {
        // MSI-X owns notification while enabled.  Keep the legacy level line
        // low even when Windows changes NVMe INTMS/INTMC or CQ heads.
        if msixEnabled {
            interruptSequence &+= 1
            return (false, false, interruptSequence)
        }
        let masked = (regINTMS & 1) != 0
        let hasPending = hasPendingCompletionsLocked
        let targetLevel = hasPending && !masked
        let shouldWake = targetLevel && isNewCompletion
        interruptSequence &+= 1
        return (targetLevel, shouldWake, interruptSequence)
    }

    private func updateGICLine(_ targetLevel: Bool, sequence: UInt64) {
        gicLineLock.lock()
        defer { gicLineLock.unlock() }

        guard sequence >= lastAppliedInterruptSequence else { return }
        lastAppliedInterruptSequence = sequence

        if gicLineLevel != targetLevel {
            if targetLevel && msixEnabled {
                validationUpdate { $0.legacyAssertionsWhileMSIX += 1 }
            }
            let res = hv_gic_set_spi(spiINTID, targetLevel)
            if res != HV_SUCCESS && Self.verbose {
                print("⚠️ FluxNVMe: hv_gic_set_spi(\(spiINTID), \(targetLevel)) failed: \(res)")
            }
            gicLineLevel = targetLevel
            traceSPI50Transition(asserted: targetLevel, result: res, assertedState: targetLevel)
        }
    }

    private func resetGICLine() {
        gicLineLock.lock()
        defer { gicLineLock.unlock() }
        if gicLineLevel {
            let res = hv_gic_set_spi(spiINTID, false)
            traceSPI50Transition(asserted: false, result: res, assertedState: false)
            if res != HV_SUCCESS && Self.verbose {
                print("⚠️ FluxNVMe: hv_gic_set_spi(\(spiINTID), false) failed: \(res)")
            }
            gicLineLevel = false
        }
        lastAppliedInterruptSequence = interruptSequence
    }

    private func tracePCI(_ operation: String, offset: UInt32, value: UInt64, old: UInt64? = nil) {
        guard Self.traceTargetIRQ else { return }
        let oldText = old.map { " old=0x\(String($0, radix: 16))" } ?? ""
        print("[TARGET-IRQ PCI t=\(DispatchTime.now().uptimeNanoseconds)] \(operation) off=0x\(String(offset, radix: 16))\(oldText) value=0x\(String(value, radix: 16))")
    }

    private func traceSPI50Transition(asserted: Bool, result: hv_return_t, assertedState: Bool) {
        guard Self.traceTargetIRQ else { return }
        var pending: UInt64 = 0
        var active: UInt64 = 0
        let pendingResult = hv_gic_get_distributor_reg(HV_GIC_DISTRIBUTOR_REG_GICD_ISPENDR1, &pending)
        let activeResult = hv_gic_get_distributor_reg(HV_GIC_DISTRIBUTOR_REG_GICD_ISACTIVER1, &active)
        let bit = UInt64(1) << UInt64(spiINTID - 32)
        let isPending = pendingResult == HV_SUCCESS && (pending & bit) != 0
        let isActive = activeResult == HV_SUCCESS && (active & bit) != 0
        targetIRQTraceLock.lock()
        if asserted { targetIRQTrace.spi50AssertCount &+= 1 } else { targetIRQTrace.spi50DeassertCount &+= 1 }
        if isPending { targetIRQTrace.spi50PendingSamples &+= 1 }
        if isActive { targetIRQTrace.spi50ActiveSamples &+= 1 }
        targetIRQTraceLock.unlock()
        print("[TARGET-IRQ SPI50 t=\(DispatchTime.now().uptimeNanoseconds)] set=\(asserted) result=\(result) assertedState=\(assertedState) INTMS=0x\(String(regINTMS, radix: 16)) pending=\(isPending) active=\(isActive)")
    }

    private func traceQueue1(_ reason: String) {
        guard Self.traceTargetIRQ else { return }
        // Caller already serializes NVMe queue mutation with the controller lock.
        cqLock.lock()
        let sq = sqs[1]
        let cq = cqs[1]
        let unread: UInt16
        if let cq { unread = cq.tail >= cq.head ? cq.tail - cq.head : cq.size - cq.head + cq.tail } else { unread = 0 }
        targetIRQTraceLock.lock()
        if reason == "cq-tail" { targetIRQTrace.cq1TailAdvanceCount &+= 1 }
        if reason == "cq-head" { targetIRQTrace.cq1HeadAdvanceCount &+= 1 }
        targetIRQTrace.cq1MaxUnread = max(targetIRQTrace.cq1MaxUnread, unread)
        targetIRQTraceLock.unlock()
        print("[TARGET-IRQ Q1 t=\(DispatchTime.now().uptimeNanoseconds)] \(reason) sq=\(sq?.head ?? 0)/\(sq?.tail ?? 0) cq=\(cq?.head ?? 0)/\(cq?.tail ?? 0) phase=\(cq?.phase ?? 0) unread=\(unread) asserted=\(interruptAsserted) INTMS=0x\(String(regINTMS, radix: 16))")
        cqLock.unlock()
    }

    // MARK: - I/O Queue Processing with Asynchronous Scatter-Gather Queue

    private func dispatchIOQueueLocked(sqid: UInt16) {
        guard canDispatchIO() else { return }
        guard var sq = sqs[sqid], sq.size > 0 && sq.base != 0 else { return }

        while sq.head != sq.tail {
            let sqeAddr = sq.base + UInt64(sq.head) * 64
            guard let sqePtr = hostPointer(forGuestAddress: sqeAddr) else {
                print("❌ FluxNVMe: Invalid I/O SQ host address @ 0x\(String(sqeAddr, radix: 16))")
                break
            }

            let opc = sqePtr.load(fromByteOffset: 0, as: UInt8.self)
            let cid = sqePtr.load(fromByteOffset: 2, as: UInt16.self)
            let nsid = sqePtr.load(fromByteOffset: 4, as: UInt32.self)
            let prp1 = sqePtr.load(fromByteOffset: 24, as: UInt64.self)
            let prp2 = sqePtr.load(fromByteOffset: 32, as: UInt64.self)
            let slba = sqePtr.load(fromByteOffset: 40, as: UInt64.self)
            let nlb = UInt32(sqePtr.load(fromByteOffset: 48, as: UInt16.self)) + 1 // 0-based

            sq.head = (sq.head + 1) % sq.size
            sqs[sqid] = sq

            validationUpdate {
                $0.sqCommands += 1
                if opc == 0x02 { $0.reads += 1 }
                if opc == 0x01 { $0.writes += 1 }
                $0.outstanding += 1
                $0.maxOutstanding = max($0.maxOutstanding, $0.outstanding)
            }

            guard nsid == 1 || (nsid == 2 && installerFD >= 0) else {
                completeIORequest(generation: controllerGeneration, sqid: sqid, cqId: sq.cqId, cid: cid, dw0: 0, status: 0x200B)
                continue
            }

            let range: (offset: off_t, length: Int)
            if opc == 0x01 || opc == 0x02 || opc == 0x08 {
                guard let validRange = validatedDataRange(nsid: nsid, slba: slba, blockCount: UInt64(nlb)) else {
                    completeIORequest(generation: controllerGeneration, sqid: sqid, cqId: sq.cqId, cid: cid, dw0: 0, status: 0x0080)
                    continue
                }
                range = validRange
            } else {
                range = (offset: 0, length: 0)
            }
            let fd = (opc == 0x02) ? ((nsid == 1) ? targetFD : installerFD) : targetFD
            let totalBytes = range.length
            let fileOffset = range.offset
            let chunks = resolvePRP(prp1: prp1, prp2: prp2, totalBytes: totalBytes)
            let iovs = buildIOVecs(from: chunks)

            let req = AsyncIORequest(
                generation: controllerGeneration,
                sqid: sqid,
                cqId: sq.cqId,
                cid: cid,
                opc: opc,
                nsid: nsid,
                fd: fd,
                fileOffset: fileOffset,
                totalBytes: totalBytes,
                iovs: iovs
            )

            let isBarrier = (opc == 0x00) // FLUSH executes as a barrier to ensure write ordering
            workerPool.submit(isBarrier: isBarrier) { [weak self] in
                guard let self else { return }
                self.executeAsyncHostIO(req)
            }
        }
    }

    /// Validates an NVMe data-command LBA range before byte arithmetic. The
    /// subtraction form avoids overflow in `slba + blockCount`.
    private func validatedDataRange(nsid: UInt32, slba: UInt64, blockCount: UInt64) -> (offset: off_t, length: Int)? {
        let namespaceBlocks: UInt64
        switch nsid {
        case 1:
            namespaceBlocks = targetSectors
        case 2 where installerFD >= 0:
            namespaceBlocks = installerSectors
        default:
            return nil
        }
        guard slba < namespaceBlocks,
              blockCount <= namespaceBlocks - slba else {
            return nil
        }
        let (byteOffset, offsetOverflow) = slba.multipliedReportingOverflow(by: sectorSize)
        let (byteLength, lengthOverflow) = blockCount.multipliedReportingOverflow(by: sectorSize)
        guard !offsetOverflow, !lengthOverflow,
              byteOffset <= UInt64(Int64.max),
              byteLength <= UInt64(Int.max) else {
            return nil
        }
        return (off_t(byteOffset), Int(byteLength))
    }

    private func executeAsyncHostIO(_ req: AsyncIORequest) {
        guard beginHostIO() else {
            validationUpdate { $0.outstanding = $0.outstanding > 0 ? $0.outstanding - 1 : 0 }
            return
        }
        defer { finishHostIO() }

        // Reset safety: discard completions from stale controller generations
        guard self.controllerGeneration == req.generation else {
            ioGate.lock()
            integrityStats.generationMismatches &+= 1
            integrityStats.staleCompletions &+= 1
            ioGate.unlock()
            validationUpdate {
                $0.staleDrops += 1
                $0.outstanding = $0.outstanding > 0 ? $0.outstanding - 1 : 0
            }
            return
        }

        switch req.opc {
        case 0x02: // Read
            if req.fd >= 0 && !req.iovs.isEmpty {
                var localIovs = req.iovs
                let bytesRead = preadv(req.fd, &localIovs, Int32(localIovs.count), req.fileOffset)
                if bytesRead < req.totalBytes {
                    var offset = max(0, bytesRead)
                    for iov in localIovs {
                        if offset >= iov.iov_len {
                            offset -= iov.iov_len
                        } else {
                            let clearLen = iov.iov_len - offset
                            memset(iov.iov_base.advanced(by: offset), 0, clearLen)
                            offset = 0
                        }
                    }
                }
            }
            validationUpdate { $0.readBytes += UInt64(req.totalBytes) }
            completeIORequest(generation: req.generation, sqid: req.sqid, cqId: req.cqId, cid: req.cid, dw0: 0, status: 0)

        case 0x01: // Write
            if req.nsid == 2 {
                // Read-only namespace: silently discard
                completeIORequest(generation: req.generation, sqid: req.sqid, cqId: req.cqId, cid: req.cid, dw0: 0, status: 0)
                return
            }
            validationUpdate { $0.writeBytes += UInt64(req.totalBytes) }

            if req.fd >= 0 && !req.iovs.isEmpty {
                var localIovs = req.iovs
                _ = pwritev(req.fd, &localIovs, Int32(localIovs.count), req.fileOffset)
            }

            statsLock.lock()
            if totalTargetBytesWritten == 0 {
                print("💾 FluxNVMe: FIRST WRITE to NSID 1 target disk (SLBA=\(req.fileOffset / off_t(sectorSize)))")
            }
            totalTargetBytesWritten += UInt64(req.totalBytes)
            let writtenMB = totalTargetBytesWritten / (1024 * 1024)
            if writtenMB >= lastMilestoneMB + 512 {
                lastMilestoneMB = writtenMB
                print("💾 FluxNVMe: NSID 1 target disk write progress: \(writtenMB) MB (\(totalTargetBytesWritten / sectorSize) sectors)")
            }
            statsLock.unlock()

            completeIORequest(generation: req.generation, sqid: req.sqid, cqId: req.cqId, cid: req.cid, dw0: 0, status: 0)

        case 0x00: // Flush
            if req.nsid == 1 && req.fd >= 0 {
                fsync(req.fd)
            }
            completeIORequest(generation: req.generation, sqid: req.sqid, cqId: req.cqId, cid: req.cid, dw0: 0, status: 0)

        case 0x08: // Write Zeroes
            if req.nsid == 2 {
                completeIORequest(generation: req.generation, sqid: req.sqid, cqId: req.cqId, cid: req.cid, dw0: 0, status: 0)
                return
            }
            if req.fd >= 0 {
                let zeroBuf = [UInt8](repeating: 0, count: min(req.totalBytes, 64 * 1024))
                var curOffset = req.fileOffset
                var remaining = req.totalBytes
                while remaining > 0 {
                    let writeLen = min(remaining, zeroBuf.count)
                    _ = pwrite(req.fd, zeroBuf, writeLen, curOffset)
                    curOffset += off_t(writeLen)
                    remaining -= writeLen
                }
            }
            completeIORequest(generation: req.generation, sqid: req.sqid, cqId: req.cqId, cid: req.cid, dw0: 0, status: 0)

        case 0x09: // Dataset Management (TRIM)
            completeIORequest(generation: req.generation, sqid: req.sqid, cqId: req.cqId, cid: req.cid, dw0: 0, status: (req.nsid == 2) ? 0x2120 : 0)

        default:
            if Self.verbose {
                print("⚠️ FluxNVMe: Unhandled I/O Opcode 0x\(String(req.opc, radix: 16)) CID=\(req.cid)")
            }
            completeIORequest(generation: req.generation, sqid: req.sqid, cqId: req.cqId, cid: req.cid, dw0: 0, status: 0)
        }
    }

    private func completeIORequest(
        generation: UInt64,
        sqid: UInt16,
        cqId: UInt16,
        cid: UInt16,
        dw0: UInt32,
        status: UInt16
    ) {
        // Discard completions if controller was reset or disabled in the meantime
        guard generation == self.controllerGeneration else { return }

        var targetLine = false
        var shouldWake = false
        var seq: UInt64 = 0
        var msiDelivery: MSIDelivery?

        lock.lock()
        guard generation == self.controllerGeneration else {
            lock.unlock()
            return
        }
        guard let sq = sqs[sqid] else {
            lock.unlock()
            return
        }
        let currentSqHead = sq.head

        cqLock.lock()
        guard generation == self.controllerGeneration,
              var cq = cqs[cqId], cq.size > 0 && cq.base != 0 else {
            cqLock.unlock()
            lock.unlock()
            return
        }

        let cqeAddr = cq.base + UInt64(cq.tail) * 16
        guard let cqePtr = hostPointer(forGuestAddress: cqeAddr) else {
            cqLock.unlock()
            lock.unlock()
            return
        }

        let phase = cq.phase & 1
        let cqeStatus = (status << 1) | phase

        cqePtr.storeBytes(of: dw0.littleEndian, toByteOffset: 0, as: UInt32.self)
        cqePtr.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 4, as: UInt32.self)
        cqePtr.storeBytes(of: currentSqHead.littleEndian, toByteOffset: 8, as: UInt16.self) // SQ Head (SQHD)
        cqePtr.storeBytes(of: sqid.littleEndian, toByteOffset: 10, as: UInt16.self)
        cqePtr.storeBytes(of: cid.littleEndian, toByteOffset: 12, as: UInt16.self)
        cqePtr.storeBytes(of: cqeStatus.littleEndian, toByteOffset: 14, as: UInt16.self)

        cq.tail = (cq.tail + 1) % cq.size
        if cq.tail == 0 {
            cq.phase ^= 1
        }
        cqs[cqId] = cq
        validationUpdate {
            $0.cqesPosted += 1
            $0.outstanding = $0.outstanding > 0 ? $0.outstanding - 1 : 0
        }

        if msixEnabled {
            // MSI-X is edge/message based.  Never retain the legacy INTx
            // level while it is enabled; a masked vector records PBA[0].
            msiDelivery = prepareMSIXDelivery(markPending: true)
        } else {
            let result = evaluateInterruptStateLocked(isNewCompletion: true)
            targetLine = result.targetLevel
            shouldWake = result.shouldWake
            seq = result.sequence
        }

        cqLock.unlock()
        lock.unlock()

        if cqId == 1 { traceQueue1("cq-tail") }

        if msixEnabled {
            resetGICLine()
            sendMSIX(msiDelivery)
        } else {
            updateGICLine(targetLine, sequence: seq)
            if shouldWake {
                onInterruptPending?()
            }
        }
    }

    private func resolvePRP(prp1: UInt64, prp2: UInt64, totalBytes: Int) -> [(address: UInt64, length: Int)] {
        var result: [(address: UInt64, length: Int)] = []
        guard totalBytes > 0 else { return result }

        let pageSize: UInt64 = 4096
        let pageOffset = prp1 & (pageSize - 1)
        let firstChunk = min(Int(pageSize - pageOffset), totalBytes)
        result.append((prp1, firstChunk))
        var remaining = totalBytes - firstChunk

        if remaining == 0 {
            return result
        }

        if remaining <= Int(pageSize) {
            result.append((prp2, remaining))
            return result
        }

        // PRP2 is a PRP List pointer
        var listGPA = prp2
        while remaining > 0 {
            guard let listHost = hostPointer(forGuestAddress: listGPA) else {
                print("❌ FluxNVMe: Invalid PRP list GPA 0x\(String(listGPA, radix: 16))")
                break
            }
            let entries = listHost.bindMemory(to: UInt64.self, capacity: 512)
            var advancedList = false
            for i in 0..<512 {
                if remaining == 0 { break }
                let entryGPA = UInt64(littleEndian: entries[i])
                if (i == 511) && (remaining > Int(pageSize)) {
                    listGPA = entryGPA
                    advancedList = true
                    break
                }
                let chunk = min(Int(pageSize), remaining)
                result.append((entryGPA, chunk))
                remaining -= chunk
            }
            if !advancedList {
                break
            }
        }
        return result
    }

    private func buildIOVecs(from chunks: [(address: UInt64, length: Int)]) -> [iovec] {
        var iovs: [iovec] = []
        iovs.reserveCapacity(chunks.count)
        for chunk in chunks {
            guard let ptr = hostPointer(forGuestAddress: chunk.address) else { continue }
            if let last = iovs.last,
               let lastBase = last.iov_base,
               lastBase.advanced(by: last.iov_len) == ptr {
                iovs[iovs.count - 1].iov_len += chunk.length
            } else {
                iovs.append(iovec(iov_base: ptr, iov_len: chunk.length))
            }
        }
        return iovs
    }

    private func postIOCompletionLocked(sqid: UInt16, cid: UInt16, dw0: UInt32, status: UInt16) {
        guard let sq = sqs[sqid], var cq = cqs[sq.cqId], cq.size > 0 && cq.base != 0 else { return }

        let cqeAddr = cq.base + UInt64(cq.tail) * 16
        guard let cqePtr = hostPointer(forGuestAddress: cqeAddr) else { return }

        let phase = cq.phase & 1
        let cqeStatus = (status << 1) | phase

        cqePtr.storeBytes(of: dw0.littleEndian, toByteOffset: 0, as: UInt32.self)
        cqePtr.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 4, as: UInt32.self)
        cqePtr.storeBytes(of: sq.head.littleEndian, toByteOffset: 8, as: UInt16.self)
        cqePtr.storeBytes(of: sqid.littleEndian, toByteOffset: 10, as: UInt16.self)
        cqePtr.storeBytes(of: cid.littleEndian, toByteOffset: 12, as: UInt16.self)
        cqePtr.storeBytes(of: cqeStatus.littleEndian, toByteOffset: 14, as: UInt16.self)

        cq.tail = (cq.tail + 1) % cq.size
        if cq.tail == 0 {
            cq.phase ^= 1
        }
        cqs[sq.cqId] = cq
    }

    // MARK: - Storage-integrity validation

    /// Disposable-harness validation of the admission gate and common range
    /// checker. Requests use the same AsyncIORequest worker path as SQ I/O.
    func runStorageIntegrityValidation() -> Bool {
        guard let data = guestRAMHost?.advanced(by: 0x0030_0000), targetFD >= 0 else {
            print("❌ [Storage Integrity] guest RAM or target FD unavailable")
            return false
        }
        memset(data, 0x3C, 4096)

        let validRanges = [
            validatedDataRange(nsid: 1, slba: 0, blockCount: 1),
            validatedDataRange(nsid: 1, slba: targetSectors - 1, blockCount: 1),
            validatedDataRange(nsid: 1, slba: targetSectors - 4, blockCount: 4)
        ].allSatisfy { $0 != nil }
        let invalidRanges = [
            validatedDataRange(nsid: 1, slba: targetSectors, blockCount: 1),
            validatedDataRange(nsid: 1, slba: targetSectors - 1, blockCount: 2),
            validatedDataRange(nsid: 1, slba: targetSectors - 1, blockCount: UInt64(UInt16.max) + 1),
            validatedDataRange(nsid: 1, slba: targetSectors - 1, blockCount: 2) // Write Zeroes uses this same validator.
        ].allSatisfy { $0 == nil }
        guard validRanges, invalidRanges else {
            print("❌ [Storage Integrity] namespace bounds validation failed")
            return false
        }

        ioGate.lock()
        integrityStats = IntegrityStats()
        ioGate.unlock()

        let sentinels = [UInt64(0), targetSectors / 2 * sectorSize, (targetSectors - 8) * sectorSize]
        let before = sentinels.compactMap { checksumTarget(offset: off_t($0)) }
        guard before.count == sentinels.count else { return false }

        let group = DispatchGroup()
        for resetNumber in 0..<100 {
            enableIOGate()
            // Deliberately exceed the four-worker pool so queued requests must
            // encounter the reset gate rather than all starting immediately.
            for requestNumber in 0..<128 {
                let isRead = ((resetNumber + requestNumber) & 1) == 0
                let request = AsyncIORequest(
                    generation: controllerGeneration,
                    sqid: 1,
                    cqId: 1,
                    cid: UInt16(requestNumber),
                    opc: isRead ? 0x02 : 0x01,
                    nsid: 1,
                    fd: targetFD,
                    fileOffset: off_t(0x0010_0000 + ((resetNumber * 128 + requestNumber) % 128) * 4096),
                    totalBytes: 4096,
                    iovs: [iovec(iov_base: data, iov_len: 4096)]
                )
                group.enter()
                workerPool.submit { [weak self] in
                    self?.executeAsyncHostIO(request)
                    group.leave()
                }
            }
            reset()
        }
        group.wait()
        workerPool.drain()

        let after = sentinels.compactMap { checksumTarget(offset: off_t($0)) }
        ioGate.lock()
        let stats = integrityStats
        ioGate.unlock()
        let checksumStable = before == after

        // NSID2 writes must remain no-ops even if an installer namespace is present.
        let nsid2Before = checksumTarget(offset: off_t(0x0020_0000))
        let nsid2Request = AsyncIORequest(generation: controllerGeneration, sqid: 1, cqId: 1, cid: 0,
                                          opc: 0x01, nsid: 2, fd: targetFD,
                                          fileOffset: off_t(0x0020_0000), totalBytes: 4096,
                                          iovs: [iovec(iov_base: data, iov_len: 4096)])
        enableIOGate()
        executeAsyncHostIO(nsid2Request)
        let nsid2Protected = nsid2Before == checksumTarget(offset: off_t(0x0020_0000))

        print("[Storage Integrity] accepted before gate: \(stats.acceptedBeforeGate)")
        print("[Storage Integrity] rejected after reset gate: \(stats.rejectedAfterGate)")
        print("[Storage Integrity] host I/O started after reset: \(stats.hostIOStartedAfterReset)")
        print("[Storage Integrity] stale completions: \(stats.staleCompletions), generation mismatches: \(stats.generationMismatches)")
        print("[Storage Integrity] sentinel checksum stable: \(checksumStable)")
        print("[Storage Integrity] bounds valid=\(validRanges) invalid=\(invalidRanges) NSID2-protected=\(nsid2Protected)")
        return stats.hostIOStartedAfterReset == 0 && stats.staleCompletions == 0 &&
               stats.generationMismatches == 0 && checksumStable && nsid2Protected
    }

    private func checksumTarget(offset: off_t) -> UInt64? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = bytes.withUnsafeMutableBytes { pread(targetFD, $0.baseAddress, $0.count, offset) }
        guard count == bytes.count else { return nil }
        return bytes.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }

    // MARK: - Validation & Synthetic Benchmark

    /// Validates that Admin and I/O command completions report the correct, advancing SQHD values.
    func runInitializationValidation() -> Bool {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("⚡️ [NVMe Validation] Validating SQHD Queue Progression...")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        if bar0Base == 0 {
            bar0Base = 0x3EFF8000
            pciCommand = 0x07
        }

        let asqGPA = guestRAMBase + 0x000E_0000
        let acqGPA = guestRAMBase + 0x000F_0000
        let sq1GPA = guestRAMBase + 0x0010_0000
        let cq1GPA = guestRAMBase + 0x0011_0000
        let dataGPA = guestRAMBase + 0x0020_0000

        guard let asqHost = hostPointer(forGuestAddress: asqGPA),
              let acqHost = hostPointer(forGuestAddress: acqGPA),
              let sq1Host = hostPointer(forGuestAddress: sq1GPA),
              let cq1Host = hostPointer(forGuestAddress: cq1GPA),
              let _ = hostPointer(forGuestAddress: dataGPA) else {
            print("❌ Validation failed: Could not map guest memory pointers")
            return false
        }

        memset(asqHost, 0, 4096)
        memset(acqHost, 0, 4096)
        memset(sq1Host, 0, 4096)
        memset(cq1Host, 0, 4096)

        // Enable controller with Admin Queues (size 64)
        writeMMIO(address: bar0Base + 0x24, value: 0x003F_003F, size: 4) // AQA = 64/64
        writeMMIO(address: bar0Base + 0x28, value: asqGPA, size: 8)
        writeMMIO(address: bar0Base + 0x30, value: acqGPA, size: 8)
        writeMMIO(address: bar0Base + 0x14, value: 0x00460001, size: 4) // CC.EN = 1

        let asqePtr = asqHost.bindMemory(to: UInt32.self, capacity: 64 * 16)
        let acqePtr = acqHost.bindMemory(to: UInt32.self, capacity: 64 * 4)

        var adminSQHeadProgression: [UInt16] = []
        var adminCQSQHDValues: [UInt16] = []

        func submitAdminCommand(slot: Int, opc: UInt8, cid: UInt16, cdw10: UInt32, cdw11: UInt32, prp1: UInt64) -> (sqhd: UInt16, status: UInt16) {
            let base = slot * 16
            asqePtr[base + 0] = UInt32(opc) | (UInt32(cid) << 16)
            asqePtr[base + 1] = 0 // NSID
            asqePtr[base + 2] = 0
            asqePtr[base + 3] = 0
            asqePtr[base + 4] = 0
            asqePtr[base + 5] = 0
            asqePtr[base + 6] = UInt32(prp1 & 0xFFFF_FFFF)
            asqePtr[base + 7] = UInt32(prp1 >> 32)
            asqePtr[base + 8] = 0
            asqePtr[base + 9] = 0
            asqePtr[base + 10] = cdw10
            asqePtr[base + 11] = cdw11
            asqePtr[base + 12] = 0
            asqePtr[base + 13] = 0
            asqePtr[base + 14] = 0
            asqePtr[base + 15] = 0

            writeMMIO(address: bar0Base + 0x1000, value: UInt64(slot + 1), size: 4)

            let cqBase = slot * 4
            let dw2 = acqePtr[cqBase + 2]
            let dw3 = acqePtr[cqBase + 3]
            let sqhd = UInt16(dw2 & 0xFFFF)
            let status = UInt16((dw3 >> 17) & 0x7FFF)

            lock.lock()
            let head = sqs[0]?.head ?? 0
            lock.unlock()
            adminSQHeadProgression.append(head)
            adminCQSQHDValues.append(sqhd)

            writeMMIO(address: bar0Base + 0x1004, value: UInt64(slot + 1), size: 4)

            return (sqhd, status)
        }

        let (idSqhd, _) = submitAdminCommand(slot: 0, opc: 0x06, cid: 1, cdw10: 0x01, cdw11: 0, prp1: dataGPA)
        let (sfSqhd, _) = submitAdminCommand(slot: 1, opc: 0x09, cid: 2, cdw10: 0x07, cdw11: 0, prp1: 0)
        let (cqSqhd, _) = submitAdminCommand(slot: 2, opc: 0x05, cid: 3, cdw10: (63 << 16) | 1, cdw11: 1, prp1: cq1GPA)
        let (sqSqhd, _) = submitAdminCommand(slot: 3, opc: 0x01, cid: 4, cdw10: (63 << 16) | 1, cdw11: (1 << 16) | 1, prp1: sq1GPA)

        print("Admin SQ head progression: \(adminSQHeadProgression)")
        print("Admin CQ SQHD values:      \(adminCQSQHDValues)")
        print("Identify Controller completion SQHD: \(idSqhd)")
        print("Set Features completion SQHD:        \(sfSqhd)")
        print("Create CQ completion SQHD:           \(cqSqhd)")
        print("Create SQ completion SQHD:           \(sqSqhd)")

        let notPermanentlyZero = adminCQSQHDValues.allSatisfy { $0 > 0 }
        let monotonic = idSqhd == 1 && sfSqhd == 2 && cqSqhd == 3 && sqSqhd == 4

        print("Confirm SQHD is not permanently zero: \(notPermanentlyZero ? "CONFIRMED (all > 0)" : "FAILED")")
        print("Confirm SQHD matches SQ head progression: \(monotonic ? "CONFIRMED (1, 2, 3, 4)" : "FAILED")")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        reset()

        let sqhdPassed = notPermanentlyZero && monotonic
        guard sqhdPassed else { return false }

        return runInterruptWakeupValidation()
    }

    /// Validates that posting new CQEs while SPI50 is already level-high triggers vCPU wakeups.
    func runInterruptWakeupValidation() -> Bool {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("⚡️ [NVMe Validation] Validating Interrupt Wakeup Semantics...")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        if bar0Base == 0 {
            bar0Base = 0x3EFF8000
            pciCommand = 0x07
        }

        let asqGPA = guestRAMBase + 0x000E_0000
        let acqGPA = guestRAMBase + 0x000F_0000
        let dataGPA = guestRAMBase + 0x0020_0000

        guard let asqHost = hostPointer(forGuestAddress: asqGPA),
              let acqHost = hostPointer(forGuestAddress: acqGPA),
              let _ = hostPointer(forGuestAddress: dataGPA) else {
            print("❌ Wakeup validation failed: Could not map guest memory pointers")
            return false
        }

        memset(asqHost, 0, 4096)
        memset(acqHost, 0, 4096)

        // Reset controller to start fresh
        reset()

        var wakeCount = 0
        onInterruptPending = {
            wakeCount += 1
        }

        // Enable controller with Admin Queues (size 64)
        writeMMIO(address: bar0Base + 0x24, value: 0x003F_003F, size: 4) // AQA = 64/64
        writeMMIO(address: bar0Base + 0x28, value: asqGPA, size: 8)
        writeMMIO(address: bar0Base + 0x30, value: acqGPA, size: 8)
        writeMMIO(address: bar0Base + 0x14, value: 0x00460001, size: 4) // CC.EN = 1

        let asqePtr = asqHost.bindMemory(to: UInt32.self, capacity: 64 * 16)

        func writeAdminSQE(slot: Int, opc: UInt8, cid: UInt16, cdw10: UInt32, cdw11: UInt32, prp1: UInt64) {
            let base = slot * 16
            asqePtr[base + 0] = UInt32(opc) | (UInt32(cid) << 16)
            asqePtr[base + 1] = 0
            asqePtr[base + 2] = 0
            asqePtr[base + 3] = 0
            asqePtr[base + 4] = 0
            asqePtr[base + 5] = 0
            asqePtr[base + 6] = UInt32(prp1 & 0xFFFF_FFFF)
            asqePtr[base + 7] = UInt32(prp1 >> 32)
            asqePtr[base + 8] = 0
            asqePtr[base + 9] = 0
            asqePtr[base + 10] = cdw10
            asqePtr[base + 11] = cdw11
            asqePtr[base + 12] = 0
            asqePtr[base + 13] = 0
            asqePtr[base + 14] = 0
            asqePtr[base + 15] = 0
        }

        // Step 1: Initial state check
        let initialAsserted = interruptAsserted
        print("Initial interruptAsserted: \(initialAsserted) (expected: false)")

        // Step 2: Post CQE A (command 1: Identify Controller)
        writeAdminSQE(slot: 0, opc: 0x06, cid: 1, cdw10: 0x01, cdw11: 0, prp1: dataGPA)
        writeMMIO(address: bar0Base + 0x1000, value: 1, size: 4) // SQ0 tail = 1

        let assertedAfterA = interruptAsserted
        let wakeAfterA = wakeCount
        print("After CQE A -> interruptAsserted: \(assertedAfterA) (expected: true), wakeCount: \(wakeAfterA) (expected: 1)")

        // Step 3: Post CQE B while CQE A is still unread (CQ0 head is still 0!)
        // interruptAsserted is ALREADY true
        let assertedBeforeB = interruptAsserted
        writeAdminSQE(slot: 1, opc: 0x09, cid: 2, cdw10: 0x07, cdw11: 0, prp1: 0) // Set Features
        writeMMIO(address: bar0Base + 0x1000, value: 2, size: 4) // SQ0 tail = 2

        let assertedAfterB = interruptAsserted
        let wakeAfterB = wakeCount
        print("After CQE B -> interruptAsserted before: \(assertedBeforeB) (expected: true), after: \(assertedAfterB) (expected: true), wakeCount: \(wakeAfterB) (expected: 2)")

        // Step 4: Consume CQE A (advance CQ0 head to 1, leaving CQE B unread)
        writeMMIO(address: bar0Base + 0x1004, value: 1, size: 4) // CQ0 head = 1
        let assertedAfterConsumeA = interruptAsserted
        print("After consuming CQE A (CQ head=1, tail=2) -> interruptAsserted: \(assertedAfterConsumeA) (expected: true, unread CQE B remains)")

        // Step 5: Consume CQE B (advance CQ0 head to 2, draining all completions)
        writeMMIO(address: bar0Base + 0x1004, value: 2, size: 4) // CQ0 head = 2
        let assertedAfterConsumeB = interruptAsserted
        print("After consuming CQE B (CQ head=2, tail=2) -> interruptAsserted: \(assertedAfterConsumeB) (expected: false, all drained)")

        let pass = !initialAsserted &&
                   assertedAfterA && wakeAfterA == 1 &&
                   assertedBeforeB && assertedAfterB && wakeAfterB == 2 &&
                   assertedAfterConsumeA && !assertedAfterConsumeB

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("⚡️ [NVMe Validation] Result: \(pass ? "PASSED ✅" : "FAILED ❌")")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        reset()
        return pass
    }

    /// Runs a synthetic disk benchmark directly through the virtual NVMe controller path.
    /// Measures sequential WRITE and sequential READ through the full virtual stack.
    func runBenchmark(targetMB: Int = 100) -> (writeMBs: Double, readMBs: Double) {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("⚡️ [NVMe Benchmark] Running \(targetMB) MB through virtual NVMe path...")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // The standalone validator uses the exact PCI MSI-X programming path
        // that Windows uses, but its backing file is supplied separately by
        // FluxVM and is never the Windows target disk.
        bar0Base = 0x3EFF8000
        bar2Base = 0x3EFFA000
        pciCommand = 0x07 // MSE | BME
        guard let msiFrame = FluxGIC.msiFrame else {
            print("❌ Benchmark failed: GIC MSI frame is unavailable")
            return (0, 0)
        }
        writeMMIO(address: bar2Base + 0x0, value: UInt64(msiFrame.setSPINSRAddress), size: 8)
        writeMMIO(address: bar2Base + 0x8, value: UInt64(msiFrame.spiBase), size: 4)
        writeMMIO(address: bar2Base + 0xC, value: 0, size: 4) // vector 0 unmasked
        writePCIConfig(offset: UInt32(Self.msixCapabilityOffset + 2), value: 0x8000, size: 2)
        guard msixEnabled else {
            print("❌ Benchmark failed: could not enable MSI-X")
            return (0, 0)
        }

        statsLock.lock()
        validationStats = ValidationStats()
        statsLock.unlock()

        let sq1GPA: UInt64 = guestRAMBase + 0x0010_0000
        let cq1GPA: UInt64 = guestRAMBase + 0x0011_0000
        let dataGPA: UInt64 = guestRAMBase + 0x0020_0000
        let prpListGPA: UInt64 = guestRAMBase + 0x0018_0000

        guard let sq1Host = hostPointer(forGuestAddress: sq1GPA),
              let _ = hostPointer(forGuestAddress: cq1GPA),
              let dataHost = hostPointer(forGuestAddress: dataGPA),
              let prpListHost = hostPointer(forGuestAddress: prpListGPA) else {
            print("❌ Benchmark failed: Could not map guest memory pointers")
            return (0, 0)
        }

        // Initialize Admin Queue & enable controller if needed
        let asqGPA = guestRAMBase + 0x000E_0000
        let acqGPA = guestRAMBase + 0x000F_0000
        writeMMIO(address: bar0Base + 0x24, value: 0x003F_003F, size: 4) // AQA = 64/64
        writeMMIO(address: bar0Base + 0x28, value: asqGPA, size: 8)
        writeMMIO(address: bar0Base + 0x30, value: acqGPA, size: 8)
        writeMMIO(address: bar0Base + 0x14, value: 0x00460001, size: 4) // CC.EN = 1

        // Setup PRP list for 128 KB (32 pages: page 0 is prp1, pages 1..31 in prp2 list)
        let prpEntries = prpListHost.bindMemory(to: UInt64.self, capacity: 64)
        for i in 0..<32 {
            prpEntries[i] = (dataGPA + UInt64((i + 1) * 4096)).littleEndian
        }
        memset(dataHost, 0xAA, 128 * 1024)

        // Create CQ1 and SQ1
        lock.lock()
        cqs[1] = NVMeCQ(base: cq1GPA, size: 64, head: 0, tail: 0, phase: 1)
        sqs[1] = NVMeSQ(base: sq1GPA, size: 64, head: 0, tail: 0, cqId: 1)
        lock.unlock()

        let sqePtr = sq1Host.bindMemory(to: UInt32.self, capacity: 64 * 16)

        let totalChunks = (targetMB * 1024 * 1024) / (128 * 1024)
        let chunkSectors: UInt32 = 256 // 128 KB / 512

        // ── 1. Sequential WRITE Benchmark ──
        let startWrite = DispatchTime.now()
        for i in 0..<totalChunks {
            let cid = UInt16(i & 0x3F)
            let slot = Int(cid)

            // Fill SQE (64 bytes = 16 dwords)
            let baseOff = slot * 16
            sqePtr[baseOff + 0] = UInt32(0x01) | (UInt32(cid) << 16) // opcode 0x01 (write), CID
            sqePtr[baseOff + 1] = 1 // NSID = 1
            sqePtr[baseOff + 2] = 0
            sqePtr[baseOff + 3] = 0
            sqePtr[baseOff + 4] = 0
            sqePtr[baseOff + 5] = 0
            sqePtr[baseOff + 6] = UInt32(dataGPA & 0xFFFF_FFFF) // PRP1 low
            sqePtr[baseOff + 7] = UInt32(dataGPA >> 32)        // PRP1 high
            sqePtr[baseOff + 8] = UInt32(prpListGPA & 0xFFFF_FFFF) // PRP2 low
            sqePtr[baseOff + 9] = UInt32(prpListGPA >> 32)        // PRP2 high
            let slba = UInt64(i) * UInt64(chunkSectors)
            sqePtr[baseOff + 10] = UInt32(slba & 0xFFFF_FFFF)  // SLBA low
            sqePtr[baseOff + 11] = UInt32(slba >> 32)          // SLBA high
            sqePtr[baseOff + 12] = chunkSectors - 1            // NLB = 255 (256 sectors)
            sqePtr[baseOff + 13] = 0
            sqePtr[baseOff + 14] = 0
            sqePtr[baseOff + 15] = 0

            let newTail = UInt64((slot + 1) % 64)
            writeMMIO(address: bar0Base + 0x1000 + 8 * 1, value: newTail, size: 4)

            // Wait for completion on CQ1
            var completed = false
            while !completed {
                cqLock.lock()
                if let cq = cqs[1], cq.head != cq.tail {
                    completed = true
                }
                cqLock.unlock()
                if !completed {
                    usleep(10)
                }
            }
            // Acknowledge CQ1 completion
            let newHead = UInt64((slot + 1) % 64)
            writeMMIO(address: bar0Base + 0x1000 + 8 * 1 + 4, value: newHead, size: 4)
        }
        let endWrite = DispatchTime.now()
        let writeNanos = endWrite.uptimeNanoseconds - startWrite.uptimeNanoseconds
        let writeSecs = Double(writeNanos) / 1_000_000_000.0
        let writeMBs = Double(targetMB) / writeSecs

        // Flush
        if targetFD >= 0 {
            fsync(targetFD)
        }

        // ── 2. Sequential READ Benchmark ──
        let startRead = DispatchTime.now()
        for i in 0..<totalChunks {
            let cid = UInt16(i & 0x3F)
            let slot = Int(cid)

            let baseOff = slot * 16
            sqePtr[baseOff + 0] = UInt32(0x02) | (UInt32(cid) << 16) // opcode 0x02 (read)
            sqePtr[baseOff + 1] = 1 // NSID = 1
            sqePtr[baseOff + 2] = 0
            sqePtr[baseOff + 3] = 0
            sqePtr[baseOff + 4] = 0
            sqePtr[baseOff + 5] = 0
            sqePtr[baseOff + 6] = UInt32(dataGPA & 0xFFFF_FFFF)
            sqePtr[baseOff + 7] = UInt32(dataGPA >> 32)
            sqePtr[baseOff + 8] = UInt32(prpListGPA & 0xFFFF_FFFF)
            sqePtr[baseOff + 9] = UInt32(prpListGPA >> 32)
            let slba = UInt64(i) * UInt64(chunkSectors)
            sqePtr[baseOff + 10] = UInt32(slba & 0xFFFF_FFFF)
            sqePtr[baseOff + 11] = UInt32(slba >> 32)
            sqePtr[baseOff + 12] = chunkSectors - 1
            sqePtr[baseOff + 13] = 0
            sqePtr[baseOff + 14] = 0
            sqePtr[baseOff + 15] = 0

            let newTail = UInt64((slot + 1) % 64)
            writeMMIO(address: bar0Base + 0x1000 + 8 * 1, value: newTail, size: 4)

            var completed = false
            while !completed {
                cqLock.lock()
                if let cq = cqs[1], cq.head != cq.tail {
                    completed = true
                }
                cqLock.unlock()
                if !completed {
                    usleep(10)
                }
            }
            let newHead = UInt64((slot + 1) % 64)
            writeMMIO(address: bar0Base + 0x1000 + 8 * 1 + 4, value: newHead, size: 4)
        }
        let endRead = DispatchTime.now()
        let readNanos = endRead.uptimeNanoseconds - startRead.uptimeNanoseconds
        let readSecs = Double(readNanos) / 1_000_000_000.0
        let readMBs = Double(targetMB) / readSecs

        let writeCmdsPerSec = Double(totalChunks) / writeSecs
        let readCmdsPerSec = Double(totalChunks) / readSecs
        let avgReqSizeKB = 128
        let hostSyscallsPerReq = 1

        print("📊 [NVMe Benchmark Results]")
        print("   Sequential WRITE: \(String(format: "%.1f", writeMBs)) MB/s (\(targetMB) MB in \(String(format: "%.2f", writeSecs))s)")
        print("   Sequential READ:  \(String(format: "%.1f", readMBs)) MB/s (\(targetMB) MB in \(String(format: "%.2f", readSecs))s)")
        print("   Commands / sec:   WRITE \(String(format: "%.0f", writeCmdsPerSec)) IOPS | READ \(String(format: "%.0f", readCmdsPerSec)) IOPS")
        print("   Avg Request Size: \(avgReqSizeKB) KB")
        print("   Host Syscalls:    \(hostSyscallsPerReq) per request (preadv/pwritev coalesced, 0 fsync on regular writes)")
        print("   fsync Penalty:    NONE (fsync only on NVMe Flush 0x00 or controller shutdown)")

        statsLock.lock()
        let stats = validationStats
        validationStats = nil
        statsLock.unlock()
        if let stats {
            print("📊 [NVMe MSI-X Validation Counters]")
            print("   SQ commands: \(stats.sqCommands) | reads: \(stats.reads) | writes: \(stats.writes)")
            print("   CQEs posted/consumed: \(stats.cqesPosted)/\(stats.cqesConsumed)")
            print("   MSI-X sends/failures: \(stats.msixSends)/\(stats.msixFailures)")
            print("   Outstanding max/final: \(stats.maxOutstanding)/\(stats.outstanding)")
            print("   Read bytes: \(stats.readBytes) | Write bytes: \(stats.writeBytes)")
            print("   Legacy SPI50 while MSI-X: \(stats.legacyAssertionsWhileMSIX)")
            print("   Stale drops: \(stats.staleDrops) | controller resets: \(stats.controllerResets) | queue deletes: \(stats.queueDeletes)")
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // Clean up benchmark queues and reset controller back to initial state
        cqLock.lock()
        cqs.removeValue(forKey: 1)
        cqLock.unlock()

        lock.lock()
        sqs.removeValue(forKey: 1)
        lock.unlock()

        reset()

        return (writeMBs, readMBs)
    }
}

/// Dedicated NVMe I/O worker pool for asynchronous host storage execution.
nonisolated final class FluxNVMeIOWorkerPool: @unchecked Sendable {
    let workerCount: Int
    private let queue: DispatchQueue
    private let semaphore: DispatchSemaphore
    private let poolLock = NSLock()
    private var isShuttingDown = false

    init(workerCount: Int = 4) {
        self.workerCount = workerCount
        self.queue = DispatchQueue(
            label: "com.flux.nvme.io-pool",
            qos: .userInteractive,
            attributes: .concurrent
        )
        self.semaphore = DispatchSemaphore(value: workerCount)
    }

    func submit(isBarrier: Bool = false, work: @escaping @Sendable () -> Void) {
        poolLock.lock()
        guard !isShuttingDown else {
            poolLock.unlock()
            return
        }
        poolLock.unlock()

        if isBarrier {
            queue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                self.poolLock.lock()
                let shutdown = self.isShuttingDown
                self.poolLock.unlock()
                guard !shutdown else { return }
                work()
            }
        } else {
            queue.async { [weak self] in
                guard let self else { return }
                self.semaphore.wait()
                defer { self.semaphore.signal() }

                self.poolLock.lock()
                let shutdown = self.isShuttingDown
                self.poolLock.unlock()
                guard !shutdown else { return }

                work()
            }
        }
    }

    /// Flushes all pending I/O operations and blocks until current jobs are done.
    func drain() {
        queue.sync(flags: .barrier) {}
    }

    func shutdown() {
        poolLock.lock()
        isShuttingDown = true
        poolLock.unlock()
        drain()
    }
}
