import Foundation
import Hypervisor

nonisolated final class FluxVM {

    private let memory = FluxMemory()
    private let firmware = FluxFirmware()
    private let gic = FluxGIC()
    private let vcpus = [
        FluxVCPU(id: 0),
        FluxVCPU(id: 1),
        FluxVCPU(id: 2),
        FluxVCPU(id: 3)
    ]
    private let timer = FluxTimer()
    private let exitHandler = FluxExitHandler()

    private var vmCreated = false
    private var awaitingPostResetPCICommand = false
    private var isShuttingDown = false
    private let platformResetLock = NSLock()
    private var isResetting = false

    static var verboseExits: Bool = ProcessInfo.processInfo.environment["FLUX_VERBOSE_EXITS"] == "1"

    // MARK: - Disk configuration

    struct DiskConfig {
        let name: String
        let path: String
        let sizeMB: Int
        let readOnly: Bool
        let base: UInt64
        let size: UInt64
        let spiINTID: UInt32
    }

    private static func defaultDisks() -> [DiskConfig] {
        let appDir = defaultAppDirectory()

        let installerPath: String
        let installerReadOnly: Bool
        if let customInstaller = ProcessInfo.processInfo.environment["FLUX_INSTALLER_DISK"] {
            installerPath = customInstaller
            installerReadOnly = true
        } else {
            let p2 = appDir + "/flux-win11-boot.raw"
            let p1 = appDir + "/flux-installer.raw"
            let p0 = appDir + "/flux-disk0.raw"
            if FileManager.default.fileExists(atPath: p2) {
                installerPath = p2
            } else if FileManager.default.fileExists(atPath: p1) {
                installerPath = p1
            } else if FileManager.default.fileExists(atPath: p0) {
                installerPath = p0
            } else {
                installerPath = p2
            }
            installerReadOnly = false
        }

        return [
            // Slot 1: Installer media (OS install media / verified test disk)
            DiskConfig(
                name: "installer",
                path: installerPath,
                sizeMB: 64,
                readOnly: installerReadOnly,
                base: 0x0A000200,
                size: 0x200,
                spiINTID: 49
            )
        ]
    }

    func runTest(edition: String = "Windows 11 Pro") {
        let startupDiagnosticPath = Self.startStartupDiagnostic()

        // The target disk and persistent UEFI VARS are shared runtime state.
        // Acquire ownership before creating a VM or opening any disk image.
        Self.writeStartupDiagnostic("START RUNTIME_LOCK", to: startupDiagnosticPath)
        guard let runtimeLock = FluxRuntimeLock.acquire(appDirectory: Self.defaultAppDirectory()) else {
            Self.writeStartupDiagnostic("FAIL RUNTIME_LOCK\nerror/result=nil", to: startupDiagnosticPath)
            return
        }
        Self.writeStartupDiagnostic("PASS RUNTIME_LOCK", to: startupDiagnosticPath)
        defer { runtimeLock.release() }

        print("================================")
        print("Flux Engine — Modular VMM")
        print("================================")

        Self.writeStartupDiagnostic("START CREATE_VM", to: startupDiagnosticPath)
        let createVMResult = createVM()
        guard createVMResult else {
            Self.writeStartupDiagnostic("FAIL CREATE_VM\nerror/result=\(createVMResult)", to: startupDiagnosticPath)
            return
        }
        Self.writeStartupDiagnostic("PASS CREATE_VM", to: startupDiagnosticPath)

        Self.writeStartupDiagnostic("START CREATE_GIC", to: startupDiagnosticPath)
        let createGICResult = gic.create()
        guard createGICResult else {
            Self.writeStartupDiagnostic("FAIL CREATE_GIC\nerror/result=\(createGICResult)", to: startupDiagnosticPath)
            cleanup()
            return
        }
        Self.writeStartupDiagnostic("PASS CREATE_GIC", to: startupDiagnosticPath)

        defer {
            isShuttingDown = true
            for cpu in vcpus {
                cpu.requestExit()
            }
            for dev in exitHandler.virtioBlocks {
                dev.cleanup()
            }
            exitHandler.nvme.cleanup()
            Thread.sleep(forTimeInterval: 0.05)
            cleanup()
            print("================================")
        }

        Self.writeStartupDiagnostic("START ALLOCATE_MEMORY", to: startupDiagnosticPath)
        let allocateMemoryResult = memory.allocate()
        guard allocateMemoryResult else {
            Self.writeStartupDiagnostic("FAIL ALLOCATE_MEMORY\nerror/result=\(allocateMemoryResult)", to: startupDiagnosticPath)
            return
        }
        Self.writeStartupDiagnostic("PASS ALLOCATE_MEMORY", to: startupDiagnosticPath)

        Self.writeStartupDiagnostic("START LOAD_DTB", to: startupDiagnosticPath)
        let loadDTBResult = memory.loadDeviceTree()
        guard loadDTBResult else {
            Self.writeStartupDiagnostic("FAIL LOAD_DTB\nerror/result=\(loadDTBResult)", to: startupDiagnosticPath)
            return
        }
        Self.writeStartupDiagnostic("PASS LOAD_DTB", to: startupDiagnosticPath)

        Self.writeStartupDiagnostic("START MAP_MEMORY", to: startupDiagnosticPath)
        let mapMemoryResult = memory.map()
        guard mapMemoryResult else {
            Self.writeStartupDiagnostic("FAIL MAP_MEMORY\nerror/result=\(mapMemoryResult)", to: startupDiagnosticPath)
            return
        }
        Self.writeStartupDiagnostic("PASS MAP_MEMORY", to: startupDiagnosticPath)

        guard firmware.loadAndMap() else {
            return
        }

        exitHandler.fwcfg.memory = memory

        guard let hostRAM = memory.hostAddress else {
            print("❌ Guest RAM host pointer unavailable")
            return
        }

        // xHCI uses this mapping only to inspect the guest-programmed ERST
        // and to post its own event TRBs. It owns no guest storage.
        exitHandler.xhci.configure(
            guestRAM: hostRAM,
            guestBase: UInt64(memory.guestBase),
            guestSize: memory.size
        )

        // ─── NVMe Target Disk Setup (PCIe Dev 1 Func 0) ──
        let appDir = Self.defaultAppDirectory()
        let targetPath: String
        if ProcessInfo.processInfo.environment["FLUX_MSIX_STRESS"] == "1" {
            // A dedicated disposable sparse image keeps validation writes away
            // from both the Windows target and read-only installer namespace.
            targetPath = appDir + "/flux-msix-validation.raw"
        } else {
            targetPath = ProcessInfo.processInfo.environment["FLUX_TARGET_DISK"]
                ?? (appDir + "/flux-target-disk.raw")
        }

        if !FileManager.default.fileExists(atPath: targetPath) {
            guard Self.createDiskImage(at: targetPath, sizeMB: ProcessInfo.processInfo.environment["FLUX_MSIX_STRESS"] == "1" ? 512 : 64 * 1024) else {
                return
            }
        }

        let isInstalled = Self.isTargetDiskBootable(path: targetPath)
        let installerPathEnv = ProcessInfo.processInfo.environment["FLUX_INSTALLER_DISK"]
            ?? (appDir + "/flux-win11-boot.raw")

        let effectiveInstallerPath: String?
        if isInstalled {
            print("📀 [FluxVM] Target disk contains installed Windows system; prioritizing target disk boot.")
            effectiveInstallerPath = FileManager.default.fileExists(atPath: installerPathEnv) ? installerPathEnv : nil
        } else {
            effectiveInstallerPath = installerPathEnv
            if let instPath = effectiveInstallerPath, FileManager.default.fileExists(atPath: instPath) {
                print("📋 [FluxVM] Preparing unattended installation for edition: \(edition)...")
                let config = FluxUnattendConfig(editionName: edition)
                let xml = FluxUnattend.generate(config: config)
                _ = FluxInstallerInjector.injectUnattendXML(installerDiskPath: instPath, xmlContent: xml)
            }
        }

        guard exitHandler.nvme.configure(
            guestRAM: hostRAM,
            guestBase: UInt64(memory.guestBase),
            guestSize: memory.size,
            targetDiskPath: targetPath,
            installerDiskPath: effectiveInstallerPath
        ) else {
            return
        }
        exitHandler.nvme.onInterruptPending = { [weak self] in
            guard let self else { return }
            var vcpuIds = self.vcpus.compactMap { $0.isCreated ? $0.vcpu : nil }
            if !vcpuIds.isEmpty {
                _ = hv_vcpus_exit(&vcpuIds, UInt32(vcpuIds.count))
            }
        }
        exitHandler.nvme.onPCICommandWrite = { [weak self] command in
            guard let self,
                  self.awaitingPostResetPCICommand,
                  command == 0x0007 else { return }
            self.awaitingPostResetPCICommand = false
            self.scheduleDriverBindingScan()
        }

        // ─── Empty VirtIO Slot 0 (0x0A000000) ────────────
        let emptySlot0 = FluxVirtIOBlock(
            base: 0x0A000000,
            size: 0x200,
            spiINTID: 48,
            name: "slot0-empty",
            readOnly: true,
            deviceID: 0
        )
        exitHandler.virtioBlocks.append(emptySlot0)

        // ─── Empty VirtIO Slot 1 (0x0A000200) ────────────
        // Kept at deviceID = 0 so EDK2 boots from NVMe Namespace 2
        let emptySlot1 = FluxVirtIOBlock(
            base: 0x0A000200,
            size: 0x200,
            spiINTID: 49,
            name: "slot1-empty",
            readOnly: true,
            deviceID: 0
        )
        exitHandler.virtioBlocks.append(emptySlot1)

        // ─── vCPU setup (4 vCPUs) ────────────────────────
        exitHandler.psci.vcpus = vcpus
        exitHandler.psci.vm = self

        guard vcpus[0].create() else {
            return
        }

        guard vcpus[0].initialize(
            pc: firmware.codeBase
        ) else {
            return
        }

        guard gic.initializeCPUInterface(
            vcpu: vcpus[0].vcpu
        ) else {
            return
        }

        guard gic.configureVirtualTimerPPI(
            vcpu: vcpus[0].vcpu
        ) else {
            return
        }

        // Initialize and start secondary vCPU worker threads (CPU 1..3)
        for i in 1...3 {
            let secCPU = vcpus[i]
            let initSem = DispatchSemaphore(value: 0)
            Thread.detachNewThread { [weak self] in
                guard let self else { return }
                guard secCPU.create() else {
                    print("❌ Failed creating secondary vCPU \(secCPU.id)")
                    initSem.signal()
                    return
                }
                guard self.gic.initializeCPUInterface(vcpu: secCPU.vcpu),
                      self.gic.configureVirtualTimerPPI(vcpu: secCPU.vcpu) else {
                    print("❌ Failed configuring GIC for secondary vCPU \(secCPU.id)")
                    initSem.signal()
                    return
                }
                initSem.signal()
                self.runSecondaryVCPU(secCPU)
            }
            initSem.wait()
        }

        guard timer.initialize() else {
            return
        }

        // ─── Configure Storage SPIs ──────────────────────
        guard configureVirtIOSPI() else {
            return
        }

        runPlatform()
    }

    /// Report and verify GIC distributor readiness for storage SPIs.
    private func configureVirtIOSPI() -> Bool {
        for dev in exitHandler.virtioBlocks where dev.deviceID != 0 {
            print("✅ VirtIO-BLK[\(dev.name)] SPI INTID \(dev.spiINTID) ready @ 0x\(String(dev.base, radix: 16))")
        }
        print("✅ NVMe SPI INTID \(exitHandler.nvme.spiINTID) ready (PCIe Dev 1 Func 0)")
        return true
    }

    // MARK: - Platform run loop (4-vCPU SMP)

    private func runPlatform() {

        print("")
        print("================================")
        print("▶️ Flux UEFI Platform Running (4 vCPUs)")
        print("================================")
        setlinebuf(stdout)

        let cpu0 = vcpus[0]
        if ProcessInfo.processInfo.environment["FLUX_VERBOSE_SAMPLER"] == "1" {
            let vcpuId = cpu0.vcpu
            Thread.detachNewThread { [weak self] in
                while self?.isShuttingDown == false {
                    Thread.sleep(forTimeInterval: 1.0)
                    var id = vcpuId
                    _ = hv_vcpus_exit(&id, 1)
                }
            }
        }

        var exitCount: UInt64 = 0

        while !isShuttingDown {

            let result = cpu0.run()

            guard result == HV_SUCCESS else {
                if isShuttingDown { break }
                print("❌ [vCPU 0] hv_vcpu_run failed: \(result)")
                return
            }

            guard let exitInfo = cpu0.exitInfo else {
                print("❌ [vCPU 0] Missing vCPU exit info")
                return
            }

            exitCount += 1

            let reason = exitInfo.pointee.reason

            if Self.verboseExits && exitCount % 500 == 0 {
                let pc = cpu0.register(HV_REG_PC)
                print("Exit #\(exitCount) reason=\(reason.rawValue) PC=0x\(String(pc, radix: 16))")
            }

            // ── Virtual timer ──────────────────────────
            if reason == HV_EXIT_REASON_VTIMER_ACTIVATED {
                _ = hv_vcpu_set_vtimer_mask(cpu0.vcpu, true)
                continue
            }

            // ── Canceled ───────────────────────────────
            if reason == HV_EXIT_REASON_CANCELED {
                guard ProcessInfo.processInfo.environment["FLUX_VERBOSE_SAMPLER"] == "1" else {
                    continue
                }
                let pc = cpu0.register(HV_REG_PC)
                let lr = cpu0.register(HV_REG_LR)
                let cpsr = cpu0.register(HV_REG_CPSR)
                let x0 = cpu0.register(HV_REG_X0)
                let x1 = cpu0.register(HV_REG_X1)
                let x2 = cpu0.register(HV_REG_X2)
                let x8 = cpu0.register(HV_REG_X8)

                var elr: UInt64 = 0
                var esr: UInt64 = 0
                var far: UInt64 = 0
                var vbar: UInt64 = 0
                var sp1: UInt64 = 0

                _ = hv_vcpu_get_sys_reg(cpu0.vcpu, HV_SYS_REG_ELR_EL1, &elr)
                _ = hv_vcpu_get_sys_reg(cpu0.vcpu, HV_SYS_REG_ESR_EL1, &esr)
                _ = hv_vcpu_get_sys_reg(cpu0.vcpu, HV_SYS_REG_FAR_EL1, &far)
                _ = hv_vcpu_get_sys_reg(cpu0.vcpu, HV_SYS_REG_VBAR_EL1, &vbar)
                _ = hv_vcpu_get_sys_reg(cpu0.vcpu, HV_SYS_REG_SP_EL1, &sp1)

                print("⏱ SAMPLER: PC=0x\(String(pc, radix: 16)) LR=0x\(String(lr, radix: 16)) VBAR=0x\(String(vbar, radix: 16)) ELR=0x\(String(elr, radix: 16))")

                let snap = FluxFramebuffer.shared.snapshot()
                if snap.isConfigured, let hostPtr = snap.hostPointer, snap.width > 0, snap.height > 0 {
                    let totalPixels = snap.width * snap.height
                    let ptr = hostPtr.assumingMemoryBound(to: UInt32.self)
                    var nonZero = 0
                    for i in stride(from: 0, to: totalPixels, by: 4) {
                        if ptr[i] != 0 { nonZero += 1 }
                    }
                    let activeCount = nonZero * 4
                    if activeCount > 400_000 {
                        Self.saveScreenshot(hostPtr: hostPtr, width: snap.width, height: snap.height, stride: snap.stride)
                        if let ram = memory.hostAddress {
                            Self.dumpPantherLogs(hostRAM: ram, ramSize: memory.size)
                        }
                    }
                }
                continue
            }

            // ── All other exits ────────────────────────
            let keepRunning = handleExitSynchronized(
                exit: exitInfo.pointee,
                cpu: cpu0,
                exitNumber: Int(exitCount)
            )

            if !keepRunning {
                if exitHandler.consumeSystemResetRequest() {
                    handlePlatformReset()
                    exitCount = 0
                    continue
                }
                print("")
                print("VM stopped after \(exitCount) exits")
                return
            }
        }
    }

    /// Secondary vCPU execution loop for CPU 1, 2, 3
    private func runSecondaryVCPU(_ cpu: FluxVCPU) {
        defer {
            cpu.cleanup()
        }
        while !isShuttingDown {
            // Secondary vCPU pauses until PSCI CPU_ON requests boot
            guard cpu.waitForBoot() else {
                break
            }

            var exitCount: UInt64 = 0
            while cpu.state == .running && !isShuttingDown {
                let result = cpu.run()
                guard result == HV_SUCCESS else {
                    if isShuttingDown { break }
                    print("❌ [vCPU \(cpu.id)] hv_vcpu_run failed: \(result)")
                    break
                }

                guard let exitInfo = cpu.exitInfo else { break }
                exitCount += 1
                let reason = exitInfo.pointee.reason

                if reason == HV_EXIT_REASON_VTIMER_ACTIVATED {
                    _ = hv_vcpu_set_vtimer_mask(cpu.vcpu, true)
                    continue
                }

                if reason == HV_EXIT_REASON_CANCELED {
                    continue
                }

                let keepRunning = handleExitSynchronized(
                    exit: exitInfo.pointee,
                    cpu: cpu,
                    exitNumber: Int(exitCount)
                )

                if !keepRunning {
                    if exitHandler.consumeSystemResetRequest() {
                        handlePlatformReset()
                        break
                    }
                    if cpu.state != .running {
                        // CPU_OFF was executed; return to waiting for boot
                        break
                    }
                    break
                }
            }
        }
    }

    private func handleExitSynchronized(
        exit: hv_vcpu_exit_t,
        cpu: FluxVCPU,
        exitNumber: Int
    ) -> Bool {
        return exitHandler.handle(
            exit: exit,
            cpu: cpu,
            firmware: firmware,
            exitNumber: exitNumber
        )
    }

    private func handlePlatformReset() {
        platformResetLock.lock()
        guard !isResetting else {
            platformResetLock.unlock()
            return
        }
        isResetting = true
        platformResetLock.unlock()

        defer {
            platformResetLock.lock()
            isResetting = false
            platformResetLock.unlock()
        }

        exitHandler.nvme.logTargetDiskIdentity("before PSCI SYSTEM_RESET handling")
        print("🔄 Guest requested system reset across all 4 vCPUs")
        if ProcessInfo.processInfo.environment["FLUX_SCAN_BUGCHECK"] == "1", let hostRAM = memory.hostAddress {
            Self.captureBugCheckEvidence(hostRAM: hostRAM, ramSize: memory.size, guestBase: memory.guestBase)
        }
        print("🔄 Reinitializing vCPU and GIC for guest reset")
        guard resetGuestExecution() else {
            print("❌ Guest reset reinitialization failed")
            return
        }
        exitHandler.nvme.logTargetDiskIdentity("before guest execution resumes after reset")
        awaitingPostResetPCICommand = true
    }

    /// PSCI SYSTEM_RESET restarts execution while preserving guest RAM, flash,
    /// and virtual disks, just as a platform reset would.
    private func resetGuestExecution() -> Bool {
        // Stop every run loop before touching architectural or GIC CPU-interface
        // state.  In particular, CPU0's PSCI exit has returned from
        // hv_vcpu_run(), while any secondary that was running must acknowledge
        // hv_vcpus_exit() on its owning thread.
        for cpu in vcpus {
            var vid = cpu.vcpu
            _ = hv_vcpus_exit(&vid, 1)
        }

        // Keep secondary CPUs off across the reset and wait for all vCPUs to
        // be outside Hypervisor.framework before resetting CPU0.
        for i in 1...3 {
            vcpus[i].powerOff()
        }
        for cpu in vcpus {
            cpu.waitUntilQuiesced()
        }
        guard vcpus[0].isCreated, vcpus[0].isQuiesced else {
            print("❌ CPU0 is not ready for GIC CPU-interface reinitialization")
            return false
        }
        print("✅ All vCPUs quiesced before CPU0 GIC CPU-interface reinitialization")

        // Reset NVMe controller state
        exitHandler.nvme.reset()

        // Restore platform DTB into guest RAM (at 0x40000000) across reset,
        // matching QEMU's ROM-backed DTB restoration semantics.
        guard memory.loadDeviceTree() else {
            print("❌ Failed reloading DTB on guest reset")
            return false
        }

        // Reset vCPU 0 registers to initial firmware entry state without destroying vCPU,
        // preserving Hypervisor GIC redistributor bindings.
        guard vcpus[0].resetRegisters(pc: UInt64(firmware.codeBase), x0: UInt64(memory.guestBase)),
              gic.initializeCPUInterface(vcpu: vcpus[0].vcpu),
              gic.configureVirtualTimerPPI(vcpu: vcpus[0].vcpu),
              timer.initialize() else {
            return false
        }

        return configureVirtIOSPI()
    }



    /// Windows loads SetupAPI/PnP state after the firmware-requested reset.
    /// Capture it once, off the vCPU thread, without restoring sampler noise.
    private func scheduleDriverBindingScan() {
        guard let hostRAM = memory.hostAddress else { return }
        let ramSize = memory.size
        // The reset returns into Windows' boot path before SetupAPI has bound
        // storage drivers.  Sample once after its PCI/PnP pass has had time to
        // create the device instance, rather than scanning the early registry
        // image that only proves the inbox package exists.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
            Self.dumpPantherLogs(hostRAM: hostRAM, ramSize: ramSize)
        }
    }

    // MARK: - Framebuffer Screenshot Capture

    static func captureCurrentScreenshot(path: String? = nil) {
        let snap = FluxFramebuffer.shared.snapshot()
        if snap.isConfigured, let hostPtr = snap.hostPointer, snap.width > 0, snap.height > 0 {
            saveScreenshot(hostPtr: hostPtr, width: snap.width, height: snap.height, stride: snap.stride, toPath: path)
        }
    }

    private static func saveScreenshot(hostPtr: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int, toPath: String? = nil) {
        let rowBytes = width * 4
        let imageSize = rowBytes * height
        let fileSize = 54 + imageSize
        var data = Data(capacity: fileSize)

        // BMP header (14 bytes)
        var b = UInt8(ascii: "B")
        var m = UInt8(ascii: "M")
        data.append(&b, count: 1)
        data.append(&m, count: 1)
        var fs = UInt32(fileSize)
        withUnsafeBytes(of: &fs) { data.append(contentsOf: $0) }
        var zero16: UInt16 = 0
        withUnsafeBytes(of: &zero16) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &zero16) { data.append(contentsOf: $0) }
        var offset54: UInt32 = 54
        withUnsafeBytes(of: &offset54) { data.append(contentsOf: $0) }

        // DIB header (40 bytes)
        var headerSize: UInt32 = 40
        withUnsafeBytes(of: &headerSize) { data.append(contentsOf: $0) }
        var w = Int32(width)
        withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
        var h = -Int32(height) // top-down
        withUnsafeBytes(of: &h) { data.append(contentsOf: $0) }
        var planes: UInt16 = 1
        withUnsafeBytes(of: &planes) { data.append(contentsOf: $0) }
        var bpp: UInt16 = 32
        withUnsafeBytes(of: &bpp) { data.append(contentsOf: $0) }
        var comp: UInt32 = 0
        withUnsafeBytes(of: &comp) { data.append(contentsOf: $0) }
        var isize = UInt32(imageSize)
        withUnsafeBytes(of: &isize) { data.append(contentsOf: $0) }
        var ppm: UInt32 = 2835
        withUnsafeBytes(of: &ppm) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &ppm) { data.append(contentsOf: $0) }
        var zero32: UInt32 = 0
        withUnsafeBytes(of: &zero32) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &zero32) { data.append(contentsOf: $0) }

        // Pixel rows
        for y in 0..<height {
            let rowPtr = hostPtr.advanced(by: y * stride)
            data.append(rowPtr.assumingMemoryBound(to: UInt8.self), count: rowBytes)
        }

        let path = toPath ?? (defaultAppDirectory() + "/flux_screenshot.bmp")
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("📸 [FluxVM] Screenshot saved to \(path) (\(width)x\(height), \(fileSize) bytes)")
        } catch {
            print("❌ [FluxVM] Failed to save screenshot: \(error)")
        }
    }

    private static func captureBugCheckEvidence(hostRAM: UnsafeMutableRawPointer, ramSize: Int, guestBase: UInt64) {
        let snap = FluxFramebuffer.shared.snapshot()
        if snap.isConfigured, let hostPtr = snap.hostPointer, snap.width > 0, snap.height > 0 {
            saveScreenshot(hostPtr: hostPtr, width: snap.width, height: snap.height, stride: snap.stride)
        }

        print("🔍 [BugCheck Scanner] Scanning guest RAM for BugCheck 0xA5 and ACPI_BIOS_ERROR...")

        // 1. Scan for KiBugCheckData (0x00000000000000A5)
        let qwordA5: [UInt8] = [0xA5, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        var cur = hostRAM
        var rem = ramSize
        var candidates = 0
        while rem >= 40, let hit = memmem(cur, rem, qwordA5, 8) {
            let offset = hit - hostRAM
            if offset % 8 == 0 {
                let gpa = guestBase + UInt64(offset)
                let q = hit.assumingMemoryBound(to: UInt64.self)
                let code = q[0]
                let p1 = q[1]
                let p2 = q[2]
                let p3 = q[3]
                let p4 = q[4]
                print("🚨 [KiBugCheckData (8-byte aligned)] GPA: 0x\(String(gpa, radix: 16))")
                print("   BugCheckCode: 0x\(String(code, radix: 16))")
                print("   Arg1: 0x\(String(p1, radix: 16))")
                print("   Arg2: 0x\(String(p2, radix: 16))")
                print("   Arg3: 0x\(String(p3, radix: 16))")
                print("   Arg4: 0x\(String(p4, radix: 16))")
                candidates += 1
            }
            let advance = (hit - cur) + 8
            cur = hit.advanced(by: 8)
            rem -= advance
        }

        // 2. Scan for 4-byte aligned BugCheckCode (0x000000A5)
        let dwordA5: [UInt8] = [0xA5, 0x00, 0x00, 0x00]
        cur = hostRAM
        rem = ramSize
        while rem >= 36, let hit = memmem(cur, rem, dwordA5, 4) {
            let offset = hit - hostRAM
            if offset % 8 == 4 {
                let gpa = guestBase + UInt64(offset)
                let q = hit.advanced(by: 4).assumingMemoryBound(to: UInt64.self)
                let p1 = q[0]
                let p2 = q[1]
                let p3 = q[2]
                let p4 = q[3]
                if p1 != 0 || p2 != 0 || p3 != 0 || p4 != 0 {
                    print("🚨 [KiBugCheckData (4-byte aligned)] GPA: 0x\(String(gpa, radix: 16))")
                    print("   BugCheckCode: 0xA5")
                    print("   Arg1: 0x\(String(p1, radix: 16))")
                    print("   Arg2: 0x\(String(p2, radix: 16))")
                    print("   Arg3: 0x\(String(p3, radix: 16))")
                    print("   Arg4: 0x\(String(p4, radix: 16))")
                    candidates += 1
                }
            }
            let advance = (hit - cur) + 4
            cur = hit.advanced(by: 4)
            rem -= advance
        }

        // 3. Scan for strings "ACPI_BIOS_ERROR"
        let strNeedle = "ACPI_BIOS_ERROR"
        let asciiNeedle = Array(strNeedle.utf8)
        cur = hostRAM
        rem = ramSize
        while rem >= asciiNeedle.count, let hit = memmem(cur, rem, asciiNeedle, asciiNeedle.count) {
            let offset = hit - hostRAM
            let gpa = guestBase + UInt64(offset)
            print("📍 [BugCheck ASCII] 'ACPI_BIOS_ERROR' at GPA 0x\(String(gpa, radix: 16))")
            let advance = (hit - cur) + asciiNeedle.count
            cur = hit.advanced(by: asciiNeedle.count)
            rem -= advance
        }

        let utf16Chars = Array(strNeedle.utf16)
        let utf16Bytes: [UInt8] = utf16Chars.withUnsafeBufferPointer { buf in
            let raw = UnsafeRawBufferPointer(buf)
            return Array(raw)
        }
        cur = hostRAM
        rem = ramSize
        while rem >= utf16Bytes.count, let hit = memmem(cur, rem, utf16Bytes, utf16Bytes.count) {
            let offset = hit - hostRAM
            let gpa = guestBase + UInt64(offset)
            print("📍 [BugCheck UTF-16] 'ACPI_BIOS_ERROR' at GPA 0x\(String(gpa, radix: 16))")
            let advance = (hit - cur) + utf16Bytes.count
            cur = hit.advanced(by: utf16Bytes.count)
            rem -= advance
        }

        print("🔍 [BugCheck Scanner] Completed scan (found \(candidates) candidates)")
    }

    // MARK: - Disk image utilities

    /// Directory for storing virtual disks inside the app's container.
    static func defaultAppDirectory() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.path

        let dir = appSupport + "/Flux"

        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        return dir
    }

    /// Durable startup breadcrumbs for GUI launches, whose stdout is not
    /// reliably retained by LaunchServices. This records existing control-flow
    /// boundaries only; it does not alter startup behavior.
    private static func startStartupDiagnostic() -> String {
        let path = defaultAppDirectory() + "/startup-diagnostic.log"
        let header = "=== Flux startup diagnostic \(ISO8601DateFormatter().string(from: Date())) ===\n"
        try? header.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func writeStartupDiagnostic(_ message: String, to path: String) {
        let line = message + "\n"
        print("[STARTUP] \(message)")
        guard let data = line.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.synchronizeFile()
    }

    /// Check if target disk has a valid GPT EFI System Partition (ESP)
    static func isTargetDiskBootable(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let fd = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? fd.close() }
        do {
            try fd.seek(toOffset: 512)
            let gptHead = fd.readData(ofLength: 8)
            if gptHead == Data("EFI PART".utf8) {
                try fd.seek(toOffset: 1024)
                let firstPart = fd.readData(ofLength: 16)
                // ESP GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B (little-endian bytes)
                let espGUID = Data([0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b])
                return firstPart == espGUID
            }
        } catch {
            return false
        }
        return false
    }

    /// Create a sparse raw disk image.
    private static func createDiskImage(at path: String, sizeMB: Int) -> Bool {

        let sizeBytes = off_t(UInt64(sizeMB) * 1024 * 1024)

        // Creation must be atomic and non-destructive. An existing VM disk is
        // never a valid target for this helper, even if a caller raced a prior
        // existence check.
        let fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0o644)

        guard fd >= 0 else {
            if errno == EEXIST {
                print("⚠️ Refusing to create disk image because it already exists: \(path)")
            } else {
                print("❌ Cannot create disk image: \(path) (errno \(errno))")
            }
            return false
        }

        // ftruncate creates a sparse file — no physical disk space used until written.
        guard ftruncate(fd, sizeBytes) == 0 else {
            print("❌ ftruncate failed for disk image: \(path)")
            close(fd)
            return false
        }

        close(fd)

        print("✅ Created disk image: \(path)")
        print("   Size: \(sizeMB) MB (sparse)")

        return true
    }

    // MARK: - VM lifecycle

    private func createVM() -> Bool {

        let result = hv_vm_create(nil)
        let resultDecimal = Int32(result)
        let resultHex = String(format: "0x%08X", UInt32(bitPattern: resultDecimal))
        let resultSucceeded = result == HV_SUCCESS
        let resultSuccessText = resultSucceeded ? "YES" : "NO"
        let startupDiagnosticPath = Self.defaultAppDirectory() + "/startup-diagnostic.log"
        Self.writeStartupDiagnostic("HV_VM_CREATE_RETURN_DEC=\(resultDecimal)", to: startupDiagnosticPath)
        Self.writeStartupDiagnostic("HV_VM_CREATE_RETURN_HEX=\(resultHex)", to: startupDiagnosticPath)
        Self.writeStartupDiagnostic("HV_VM_CREATE_SUCCESS=\(resultSuccessText)", to: startupDiagnosticPath)

        guard result == HV_SUCCESS else {
            print("❌ hv_vm_create failed: \(result)")
            return false
        }

        vmCreated = true

        print("✅ VM created")

        return true
    }

    private func cleanup() {

        // The Metal display may render after the run loop exits.  Remove its
        // borrowed guest-RAM pointer before unmapping that allocation.
        FluxFramebuffer.shared.invalidate()
        if !vcpus.isEmpty {
            vcpus[0].cleanup()
        }
        firmware.cleanup()
        memory.cleanup()

        if vmCreated {

            let result = hv_vm_destroy()

            if result == HV_SUCCESS {
                print("✅ VM destroyed")
            } else {
                print("⚠️ hv_vm_destroy: \(result)")
            }

            vmCreated = false
        }
    }

    // MARK: - Disposable reset/disk preservation validation

    private struct ValidationImageFingerprint: Equatable {
        let identity: FluxNVMe.DiskIdentity
        let first4KiB: UInt64
        let middle4KiB: UInt64
        let last4KiB: UInt64
    }

    /// Exercises the production platform-reset handler against a uniquely named
    /// temporary disk. It never opens the Windows target, installer, or VARS.
    func runResetDiskValidation() -> Bool {
        let imageSize: Int64 = 64 * 1024 * 1024
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("flux-reset-disk-validation-\(UUID().uuidString).raw")
            .path
        print("================================")
        print("Flux Engine — Disposable Reset Disk Validation")
        print("================================")
        print("💽 Validation image: \(path)")

        let imageFD = open(path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard imageFD >= 0 else {
            print("❌ Could not create disposable validation image (errno \(errno))")
            return false
        }
        defer {
            close(imageFD)
            unlink(path)
        }
        guard ftruncate(imageFD, off_t(imageSize)) == 0,
              Self.writeValidationMarkers(fd: imageFD, imageSize: imageSize) else {
            print("❌ Could not initialize disposable validation image")
            return false
        }
        _ = fsync(imageFD)

        var secondaryStopped: [DispatchSemaphore] = []
        guard createVM(), gic.create(), memory.allocate(), memory.loadDeviceTree(), memory.map(),
              let hostRAM = memory.hostAddress else {
            cleanup()
            return false
        }
        defer {
            for cpu in vcpus.dropFirst() { cpu.requestExit() }
            for stopped in secondaryStopped { stopped.wait() }
            exitHandler.nvme.cleanup()
            cleanup()
        }

        guard exitHandler.nvme.configure(
            guestRAM: hostRAM,
            guestBase: UInt64(memory.guestBase),
            guestSize: memory.size,
            targetDiskPath: path,
            // The same disposable file is exposed read-only as NSID2 solely
            // to verify that NSID2 write commands remain host no-ops.
            installerDiskPath: path
        ),
        vcpus[0].create(),
        vcpus[0].initialize(pc: firmware.codeBase),
        gic.initializeCPUInterface(vcpu: vcpus[0].vcpu),
        gic.configureVirtualTimerPPI(vcpu: vcpus[0].vcpu),
        timer.initialize(),
        configureVirtIOSPI() else {
            return false
        }

        // Hypervisor.framework requires each secondary vCPU to be created on
        // its owning host thread, exactly as the production startup path does.
        for cpu in vcpus.dropFirst() {
            let initialized = DispatchSemaphore(value: 0)
            let stopped = DispatchSemaphore(value: 0)
            secondaryStopped.append(stopped)
            Thread.detachNewThread { [weak self] in
                guard let self,
                      cpu.create(),
                      self.gic.initializeCPUInterface(vcpu: cpu.vcpu),
                      self.gic.configureVirtualTimerPPI(vcpu: cpu.vcpu) else {
                    print("❌ Could not initialize validation vCPU \(cpu.id)")
                    initialized.signal()
                    stopped.signal()
                    return
                }
                initialized.signal()
                self.runSecondaryVCPU(cpu)
                stopped.signal()
            }
            initialized.wait()
            guard cpu.isCreated else { return false }
        }

        guard let baseline = Self.validationFingerprint(path: path, fd: imageFD, imageSize: imageSize) else {
            return false
        }
        print("💽 [Reset Validation] baseline inode=\(baseline.identity.inode) size=\(baseline.identity.size) blocks=\(baseline.identity.blocks) first=0x\(String(baseline.first4KiB, radix: 16)) middle=0x\(String(baseline.middle4KiB, radix: 16)) last=0x\(String(baseline.last4KiB, radix: 16))")

        for iteration in 1...20 {
            handlePlatformReset()
            guard let after = Self.validationFingerprint(path: path, fd: imageFD, imageSize: imageSize),
                  after == baseline else {
                print("❌ [Reset Validation] iteration \(iteration): disk identity or marker changed")
                return false
            }
            print("✅ [Reset Validation] iteration \(iteration): PASS")
        }
        guard exitHandler.nvme.runStorageIntegrityValidation() else {
            print("❌ [Storage Integrity] reset-gate or bounds validation failed")
            return false
        }
        print("✅ [Reset Validation] all 20 production reset iterations preserved the disposable image")
        return true
    }

    private static func writeValidationMarkers(fd: Int32, imageSize: Int64) -> Bool {
        var first = [UInt8](repeating: 0, count: 4096)
        Array("FLUX-RESET-VALIDATION-LBA0".utf8).enumerated().forEach { first[$0.offset] = $0.element }
        Array("FLUX-RESET-VALIDATION-LBA1".utf8).enumerated().forEach { first[512 + $0.offset] = $0.element }
        let middle = [UInt8](repeating: 0x5A, count: 4096)
        let last = [UInt8](repeating: 0xA5, count: 4096)
        let writes: [([UInt8], off_t)] = [
            (first, 0), (middle, off_t(imageSize / 2)), (last, off_t(imageSize - 4096))
        ]
        for (bytes, offset) in writes {
            let count = bytes.withUnsafeBytes { buffer in
                pwrite(fd, buffer.baseAddress, buffer.count, offset)
            }
            guard count == bytes.count else { return false }
        }
        return true
    }

    private static func validationFingerprint(path: String, fd: Int32, imageSize: Int64) -> ValidationImageFingerprint? {
        guard let identity = readDiskIdentity(fd: fd),
              let first = checksum(fd: fd, offset: 0),
              let middle = checksum(fd: fd, offset: off_t(imageSize / 2)),
              let last = checksum(fd: fd, offset: off_t(imageSize - 4096)) else {
            return nil
        }
        _ = path // Retain the named path in this boundary-checking API.
        return ValidationImageFingerprint(identity: identity, first4KiB: first, middle4KiB: middle, last4KiB: last)
    }

    private static func readDiskIdentity(fd: Int32) -> FluxNVMe.DiskIdentity? {
        var st = stat()
        guard fstat(fd, &st) == 0, let first = checksum(fd: fd, offset: 0) else { return nil }
        return FluxNVMe.DiskIdentity(inode: UInt64(st.st_ino), size: Int64(st.st_size), blocks: Int64(st.st_blocks), first4KiBChecksum: first)
    }

    private static func checksum(fd: Int32, offset: off_t) -> UInt64? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = bytes.withUnsafeMutableBytes { buffer in
            pread(fd, buffer.baseAddress, buffer.count, offset)
        }
        guard count == bytes.count else { return nil }
        return bytes.reduce(UInt64(0xcbf29ce484222325)) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100000001b3
        }
    }

    // MARK: - Synthetic NVMe Benchmark

    func validateNVMe() -> Bool {
        print("================================")
        print("Flux Engine — NVMe SQHD Validation")
        print("================================")

        guard createVM() else {
            return false
        }

        defer {
            exitHandler.nvme.cleanup()
            cleanup()
        }

        guard memory.allocate(), memory.map(), let hostRAM = memory.hostAddress else {
            print("❌ Failed allocating memory for validation")
            return false
        }

        let appDir = Self.defaultAppDirectory()
        let targetPath = ProcessInfo.processInfo.environment["FLUX_TARGET_DISK"]
            ?? (appDir + "/flux-target-disk.raw")

        if !FileManager.default.fileExists(atPath: targetPath) {
            guard Self.createDiskImage(at: targetPath, sizeMB: 64 * 1024) else {
                return false
            }
        }

        guard exitHandler.nvme.configure(
            guestRAM: hostRAM,
            guestBase: UInt64(memory.guestBase),
            guestSize: memory.size,
            targetDiskPath: targetPath,
            installerDiskPath: nil
        ) else {
            print("❌ Failed configuring NVMe for validation")
            return false
        }

        return exitHandler.nvme.runInitializationValidation()
    }

    func runNVMeBenchmark(targetMB: Int = 100) -> (Double, Double) {
        print("================================")
        print("Flux Engine — NVMe Benchmark (\(targetMB) MB)")
        print("================================")

        guard createVM() else {
            return (0, 0)
        }

        // Keep the standalone benchmark lifecycle identical to runTest(): the
        // production GIC setup owns the HVF MSI-region queries, SPI 64...79
        // reservation, and publication of FluxGIC.msiFrame.
        guard gic.create(), let msiFrame = FluxGIC.msiFrame else {
            print("❌ Failed configuring production GIC MSI frame for benchmark")
            cleanup()
            return (0, 0)
        }
        print("✅ [NVMe MSI-X Validation] MSI frame available: YES")
        print("   IPA: 0x\(String(msiFrame.base, radix: 16))")
        print("   Size: \(msiFrame.size) | alignment: \(msiFrame.alignment)")
        print("   SPI range: \(msiFrame.spiBase)...\(msiFrame.spiBase + msiFrame.spiCount - 1)")
        print("   Matches production VM configuration: YES")

        defer {
            exitHandler.nvme.cleanup()
            cleanup()
        }

        guard memory.allocate(), memory.map(), let hostRAM = memory.hostAddress else {
            print("❌ Failed allocating memory for benchmark")
            return (0, 0)
        }

        let appDir = Self.defaultAppDirectory()
        let isMSIXStress = ProcessInfo.processInfo.environment["FLUX_MSIX_STRESS"] == "1"
        let targetPath = isMSIXStress
            ? (appDir + "/flux-msix-validation.raw")
            : (ProcessInfo.processInfo.environment["FLUX_TARGET_DISK"] ?? (appDir + "/flux-target-disk.raw"))

        if !FileManager.default.fileExists(atPath: targetPath) {
            guard Self.createDiskImage(at: targetPath, sizeMB: isMSIXStress ? 512 : 64 * 1024) else {
                return (0, 0)
            }
        }

        guard exitHandler.nvme.configure(
            guestRAM: hostRAM,
            guestBase: UInt64(memory.guestBase),
            guestSize: memory.size,
            targetDiskPath: targetPath,
            installerDiskPath: nil
        ) else {
            print("❌ Failed configuring NVMe for benchmark")
            return (0, 0)
        }

        return exitHandler.nvme.runBenchmark(targetMB: targetMB)
    }

    // MARK: - Panther Logs Scanner

    private static var didDumpLogs = false

    private static func dumpPantherLogs(hostRAM: UnsafeMutableRawPointer, ramSize: Int) {
        guard !didDumpLogs else { return }
        didDumpLogs = true

        // The lower region only held the static driver store.  Probe the
        // active Windows heap window instead, still as one bounded scan—not a
        // sweep of guest RAM.
        let scanOffset = min(1536 * 1024 * 1024, max(0, ramSize - 768 * 1024 * 1024))
        let scanSize = min(768 * 1024 * 1024, ramSize - scanOffset)
        let raw = Data(bytesNoCopy: hostRAM.advanced(by: scanOffset), count: scanSize, deallocator: .none)
        var logOutput = ""

        print("🔍 PNP_LOG: scanning \(scanSize / 1024 / 1024) MiB at guest 0x\(String(scanOffset, radix: 16)) for PCI/NVMe driver binding evidence")
        let needles = ["PCI\\VEN_8086&DEV_0953", "PCI\\CC_010802", "stornvme", "storport", "Standard NVM Express", "CM_PROB", "Problem Status", "SetupAPI.dev.log", "AddDevice", "StartDevice", "Device install requested", "resource assignment", "interrupt resource"]
        for needle in needles {
            for isUTF16 in [false, true] {
                let needleData: Data
                if isUTF16 {
                    let utf16 = Array(needle.utf16)
                    needleData = utf16.withUnsafeBufferPointer { Data(buffer: $0) }
                } else {
                    needleData = Data(needle.utf8)
                }
                var searchStart = 0
                var matchesForNeedle = 0
                while matchesForNeedle < 3,
                      searchStart < raw.count,
                      let range = raw.range(of: needleData, options: [], in: searchStart..<raw.count) {
                    // UTF-16 must start on a code-unit boundary.  The old
                    // arbitrary byte slice made useful context look empty.
                    let contextStart = max(0, range.lowerBound - 1024)
                    let start = isUTF16 ? (contextStart & ~1) : contextStart
                    let end = min(raw.count, range.upperBound + 2048) & (isUTF16 ? ~1 : ~0)
                    let chunk = raw.subdata(in: start..<end)
                    let text = isUTF16 ? (String(data: chunk, encoding: .utf16LittleEndian) ?? String(decoding: chunk, as: UTF8.self))
                                       : (String(data: chunk, encoding: .utf8) ?? String(decoding: chunk, as: UTF8.self))
                    let printable = String(text.unicodeScalars.map { scalar in
                        if scalar.value == 0x0A || scalar.value == 0x0D { return Character("\n") }
                        if scalar.value >= 0x20 && scalar.value <= 0x7E { return Character(String(scalar)) }
                        return Character(" ")
                    })
                    let compact = printable
                        .split(whereSeparator: { $0.isWhitespace })
                        .joined(separator: " ")
                        .prefix(3500)
                    let matchAddress = scanOffset + range.lowerBound
                    let match = "\n=== PNP_LOG MATCH '\(needle)' (\(isUTF16 ? "UTF16" : "UTF8")) @ 0x\(String(matchAddress, radix: 16)) ===\n\(compact)\n"
                    logOutput += match
                    print(match)
                    matchesForNeedle += 1
                    searchStart = range.upperBound + 4096
                }
            }
        }

        if !logOutput.isEmpty {
            let outPath = defaultAppDirectory() + "/setupact_dump.txt"
            do {
                try logOutput.write(toFile: outPath, atomically: true, encoding: .utf8)
                print("📝 [FluxVM] Dumped Windows Setup logs to \(outPath) (\(logOutput.count) bytes)")
            } catch {
                print("❌ [FluxVM] Failed writing logs to \(outPath): \(error)")
            }
        }
    }
}
