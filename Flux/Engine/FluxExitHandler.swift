import Foundation
import Hypervisor

nonisolated final class FluxExitHandler {

    /// Set to `true` to emit per-exit diagnostics (NOR, MMIO, VirtIO, …).
    /// Keep `false` for normal operation — verbose stdout can stall the
    /// vCPU thread when output is redirected to a file/pipe.
    static var verbose = false

    let hypercall = FluxHypercall()
    let uart = FluxUART()
    let psci = FluxPSCI()
    let trng = FluxTRNG()
    let fwcfg = FluxFWCfg()
    let rtc = FluxRTC()
    var virtioBlocks: [FluxVirtIOBlock] = []
    let nvme = FluxNVMe()
    let xhci = FluxXHCI()
    let pcie: FluxPCIe

    init() {
        self.pcie = FluxPCIe(nvme: nvme, xhci: xhci)
    }

    func findVirtIOBlock(at address: UInt64) -> FluxVirtIOBlock? {
        virtioBlocks.first { $0.contains(address) }
    }

    private enum NORMode {
        case array
        case deviceID
        case bufferedWriteAwaitCount
        case bufferedWriteData(remaining: Int)
        case bufferedWriteAwaitConfirm
        case eraseAwaitConfirm(address: UInt64)
        case status
    }

    private var norMode: NORMode = .array
    private let flashLock = NSLock()
    private var oslarLocked: Bool = false
    private let oslarLock = NSLock()
    private var systemResetRequested = false
    private let resetLock = NSLock()

    func consumeSystemResetRequest() -> Bool {
        resetLock.lock()
        defer { resetLock.unlock() }
        defer { systemResetRequested = false }
        return systemResetRequested
    }

    func handle(
        exit: hv_vcpu_exit_t,
        cpu: FluxVCPU,
        firmware: FluxFirmware,
        exitNumber: Int
    ) -> Bool {

        switch exit.reason {

        case HV_EXIT_REASON_EXCEPTION:

            let esr = UInt64(
                exit.exception.syndrome
            )

            let exceptionClass =
                (esr >> 26) & 0x3F

            // EC 0x24 / 0x25 = Data Abort caused by MMIO.
            if exceptionClass == 0x24 ||
                exceptionClass == 0x25 {

                let iss = esr & 0x01FF_FFFF

                let isValid =
                    ((iss >> 24) & 1) == 1

                let sas =
                    Int((iss >> 22) & 0x3)

                let srt =
                    Int((iss >> 16) & 0x1F)

                let isWrite =
                    ((iss >> 6) & 1) == 1

                let accessSize = 1 << sas

                let ipa = UInt64(
                    exit.exception.physical_address
                )

                guard isValid else {
                    print(
                        "❌ MMIO abort without valid ISS"
                    )
                    return false
                }

                let isUART = uart.contains(ipa)
                let isFWCfg = fwcfg.contains(ipa)
                let isRTC = rtc.contains(ipa)
                let isVirtIOBlock = findVirtIOBlock(at: ipa) != nil
                let isPCIeConfig = pcie.containsConfig(ipa)
                let isPCIeIO = pcie.containsIO(ipa)
                let isNVMeMMIO = nvme.containsMMIO(ipa)
                let isXHCIMMIO = xhci.containsMMIO(ipa)

                let registers: [hv_reg_t] = [
                    HV_REG_X0, HV_REG_X1,
                    HV_REG_X2, HV_REG_X3,
                    HV_REG_X4, HV_REG_X5,
                    HV_REG_X6, HV_REG_X7,
                    HV_REG_X8, HV_REG_X9,
                    HV_REG_X10, HV_REG_X11,
                    HV_REG_X12, HV_REG_X13,
                    HV_REG_X14, HV_REG_X15,
                    HV_REG_X16, HV_REG_X17,
                    HV_REG_X18, HV_REG_X19,
                    HV_REG_X20, HV_REG_X21,
                    HV_REG_X22, HV_REG_X23,
                    HV_REG_X24, HV_REG_X25,
                    HV_REG_X26, HV_REG_X27,
                    HV_REG_X28,
                    HV_REG_FP,
                    HV_REG_LR
                ]

                let isVARS =
                    ipa >= 0x04000000 &&
                    ipa < 0x08000000

                if isVARS {
                    flashLock.lock()
                    defer { flashLock.unlock() }

                    if Self.verbose {
                        print("")
                        print("===== NOR FLASH =====")
                        print(
                            "IPA: 0x" +
                            String(ipa, radix: 16)
                        )
                        print(
                            "Access size: \(accessSize) byte(s)"
                        )
                        print(
                            "Register: X\(srt)"
                        )
                        print(
                            "Operation: " +
                            (isWrite ? "WRITE" : "READ")
                        )
                    }

                    if isWrite {

                        let value: UInt64

                        if srt == 31 {
                            value = 0
                        } else {
                            guard srt < registers.count else {
                                print(
                                    "❌ Invalid NOR source register"
                                )
                                return false
                            }

                            value = cpu.register(
                                registers[srt]
                            )
                        }

                        if Self.verbose {
                            print(
                                "Value: 0x" +
                                String(value, radix: 16)
                            )
                        }

                        if case .bufferedWriteAwaitCount =
                            norMode {

                            // QEMU CFI01 masks the count to the
                            // physical device width. Our flash uses
                            // two 16-bit devices on a 32-bit bank.
                            let count =
                                UInt16(truncatingIfNeeded: value)

                            let transfers =
                                Int(count) + 1

                            if Self.verbose {
                                print(
                                    "✅ NOR BUFFER COUNT"
                                )
                                print(
                                    "   Count field: \(count)"
                                )
                                print(
                                    "   Transfers: \(transfers)"
                                )
                            }

                            norMode =
                                .bufferedWriteData(
                                    remaining: transfers
                                )

                            let pc =
                                cpu.register(HV_REG_PC)

                            guard cpu.setRegister(
                                HV_REG_PC,
                                value: pc + 4
                            ) else {
                                return false
                            }

                            if Self.verbose { print("=====================") }
                            return true
                        }

                        if case let .bufferedWriteData(
                            remaining
                        ) = norMode {

                            guard firmware.programVars(
                                at: ipa,
                                value: value,
                                size: accessSize
                            ) else {
                                print(
                                    "❌ NOR buffered data program failed"
                                )
                                return false
                            }

                            let nextRemaining =
                                remaining - 1

                            if nextRemaining == 0 {

                                norMode =
                                    .bufferedWriteAwaitConfirm

                                if Self.verbose {
                                    print("✅ NOR buffered data complete")
                                    print("   Awaiting 0xD0 confirm")
                                }

                            } else {

                                norMode =
                                    .bufferedWriteData(
                                        remaining: nextRemaining
                                    )
                            }

                            let pc =
                                cpu.register(HV_REG_PC)

                            guard cpu.setRegister(
                                HV_REG_PC,
                                value: pc + 4
                            ) else {
                                return false
                            }

                            return true
                        }

                        if case let .eraseAwaitConfirm(
                            eraseAddress
                        ) = norMode {

                            let confirm =
                                UInt8(
                                    truncatingIfNeeded: value
                                )

                            guard confirm == 0xD0 else {
                                print(
                                    "❌ NOR erase expected 0xD0, got 0x" +
                                    String(confirm, radix: 16)
                                )
                                return false
                            }

                            // EDK2/QEMU ArmVirt NOR uses 256 KiB blocks.
                            guard firmware.eraseVarsBlock(
                                containing: eraseAddress,
                                blockSize: 256 * 1024
                            ) else {
                                print(
                                    "❌ NOR block erase failed"
                                )
                                return false
                            }

                            if Self.verbose {
                                print("✅ NOR BLOCK ERASE CONFIRMED")
                                print(
                                    "   Block address: 0x" +
                                    String(eraseAddress, radix: 16)
                                )
                            }

                            norMode = .status

                            let pc =
                                cpu.register(HV_REG_PC)

                            guard cpu.setRegister(
                                HV_REG_PC,
                                value: pc + 4
                            ) else {
                                return false
                            }

                            if Self.verbose { print("=====================") }
                            return true
                        }

                        if case .bufferedWriteAwaitConfirm =
                            norMode {

                            let confirm =
                                UInt8(
                                    truncatingIfNeeded: value
                                )

                            guard confirm == 0xD0 else {

                                print(
                                    "❌ NOR expected 0xD0 confirm, got 0x" +
                                    String(confirm, radix: 16)
                                )

                                return false
                            }

                            if Self.verbose {
                                print("✅ NOR BUFFERED WRITE CONFIRMED")
                            }

                            norMode = .status

                            let pc =
                                cpu.register(HV_REG_PC)

                            guard cpu.setRegister(
                                HV_REG_PC,
                                value: pc + 4
                            ) else {
                                return false
                            }

                            if Self.verbose { print("=====================") }
                            return true
                        }

                        let command =
                            UInt8(truncatingIfNeeded: value)

                        if Self.verbose {
                            print(
                                "CFI command: 0x" +
                                String(command, radix: 16)
                            )
                        }

                        switch command {

                        case 0xFF:

                            if Self.verbose {
                                print("✅ NOR READ ARRAY / RESET")
                            }

                            norMode = .array

                            guard firmware.setVarsReadMapped(
                                true
                            ) else {
                                return false
                            }

                        case 0x20:

                            if Self.verbose {
                                print("✅ NOR BLOCK ERASE SETUP")
                            }

                            norMode =
                                .eraseAwaitConfirm(
                                    address: ipa
                                )

                            guard firmware.setVarsReadMapped(
                                false
                            ) else {
                                return false
                            }

                        case 0x50:

                            if Self.verbose {
                                print("✅ NOR CLEAR STATUS")
                            }

                            // QEMU CFI01 clears status bits and
                            // returns immediately to READ ARRAY.
                            norMode = .array

                            guard firmware.setVarsReadMapped(
                                true
                            ) else {
                                return false
                            }

                        case 0x70:

                            if Self.verbose {
                                print("✅ NOR READ STATUS mode")
                            }

                            norMode = .status

                            guard firmware.setVarsReadMapped(
                                false
                            ) else {
                                return false
                            }

                        case 0x90:

                            if Self.verbose {
                                print("✅ NOR READ DEVICE ID mode")
                            }

                            norMode = .deviceID

                            guard firmware.setVarsReadMapped(
                                false
                            ) else {
                                return false
                            }

                        case 0xE8:

                            if Self.verbose {
                                print("✅ NOR BUFFERED WRITE setup")
                            }

                            norMode =
                                .bufferedWriteAwaitCount

                            // Status reads must trap.
                            guard firmware.setVarsReadMapped(
                                false
                            ) else {
                                return false
                            }

                        default:

                            print(
                                "🔥 NEXT NOR COMMAND DISCOVERED"
                            )
                            print("=====================")
                            return false
                        }

                    } else {

                        // Intel CFI01 Device-ID mode.
                        //
                        // QEMU ARM virt flash:
                        // bank width   = 4 bytes
                        // device width = 2 bytes
                        // manufacturer = 0x89
                        // device ID    = 0x18
                        //
                        // IDs are replicated across the 32-bit bus.
                        let offset =
                            ipa - UInt64(firmware.varsBase)

                        let value: UInt64

                        switch norMode {

                        case .deviceID:

                            switch offset {

                            case 0x00:
                                value = 0x00890089

                                if Self.verbose {
                                    print("✅ NOR Manufacturer ID -> 0x00890089")
                                }

                            case 0x04:
                                value = 0x00180018

                                if Self.verbose {
                                    print("✅ NOR Device ID -> 0x00180018")
                                }

                            case 0x08, 0x0C:
                                value = 0

                                if Self.verbose {
                                    print("✅ NOR Device Info -> 0")
                                }

                            default:
                                print(
                                    "🔥 NEXT NOR ID READ ADDRESS"
                                )
                                print(
                                    "Offset: 0x" +
                                    String(offset, radix: 16)
                                )
                                print("=====================")
                                return false
                            }

                        case .bufferedWriteAwaitCount,
                             .bufferedWriteAwaitConfirm,
                             .eraseAwaitConfirm,
                             .status:

                            // READY bit set on both 16-bit devices.
                            value = 0x00800080

                            if Self.verbose {
                                print("✅ NOR STATUS -> 0x00800080")
                            }

                        case .bufferedWriteData:

                            // Firmware normally should not poll while
                            // feeding the buffer, but return READY if it
                            // does.
                            value = 0x00800080

                        case .array:

                            print(
                                "❌ Unexpected trapped read in array mode"
                            )
                            return false
                        }

                        // XZR/WZR discards the read.
                        if srt != 31 {

                            guard srt < registers.count else {
                                print(
                                    "❌ Invalid NOR target register"
                                )
                                return false
                            }

                            guard cpu.setRegister(
                                registers[srt],
                                value: value
                            ) else {
                                return false
                            }
                        }
                    }

                    let pc =
                        cpu.register(HV_REG_PC)

                    guard cpu.setRegister(
                        HV_REG_PC,
                        value: pc + 4
                    ) else {
                        return false
                    }

                    if Self.verbose { print("=====================") }
                    return true
                }

                guard isUART || isFWCfg || isRTC || isVirtIOBlock || isPCIeConfig || isPCIeIO || isNVMeMMIO || isXHCIMMIO else {
                    print(
                        "❌ Unhandled MMIO IPA: 0x" +
                        String(ipa, radix: 16)
                    )
                    return false
                }

                if isWrite {

                    let value: UInt64

                    if srt == 31 {
                        value = 0
                    } else {
                        guard srt < registers.count else {
                            print(
                                "❌ Invalid MMIO source register"
                            )
                            return false
                        }

                        value = cpu.register(
                            registers[srt]
                        )
                    }

                    let handledWrite: Bool

                    if uart.contains(ipa) {
                        handledWrite = uart.write(
                            address: ipa,
                            value: value,
                            size: accessSize
                        )
                    } else if fwcfg.contains(ipa) {
                        handledWrite = fwcfg.write(
                            address: ipa,
                            value: value,
                            size: accessSize
                        )
                    } else if rtc.contains(ipa) {
                        handledWrite = rtc.write(
                             address: ipa,
                             value: value,
                             size: accessSize
                         )
                    } else if let dev = findVirtIOBlock(at: ipa) {
                        handledWrite = dev.write(
                            address: ipa,
                            value: value,
                            size: accessSize
                        )
                    } else if pcie.containsConfig(ipa) {
                        pcie.writeConfig(address: ipa, value: value, size: accessSize)
                        handledWrite = true
                    } else if pcie.containsIO(ipa) {
                        pcie.writeIO(address: ipa, value: value, size: accessSize)
                        handledWrite = true
                    } else if nvme.containsMMIO(ipa) {
                        nvme.writeMMIO(address: ipa, value: value, size: accessSize)
                        handledWrite = true
                    } else if xhci.containsMMIO(ipa) {
                        xhci.writeMMIO(address: ipa, value: value, size: accessSize)
                        handledWrite = true
                    } else {
                        handledWrite = false
                    }

                    guard handledWrite else {
                        print(
                            "❌ MMIO write failed @ 0x" +
                            String(ipa, radix: 16)
                        )
                        return false
                    }

                } else {

                    let value: UInt64?

                    if uart.contains(ipa) {
                        value = uart.read(
                            address: ipa,
                            size: accessSize
                        )
                    } else if fwcfg.contains(ipa) {
                        value = fwcfg.read(
                            address: ipa,
                            size: accessSize
                        )
                    } else if rtc.contains(ipa) {
                        value = rtc.read(
                            address: ipa,
                            size: accessSize
                        )
                    } else if let dev = findVirtIOBlock(at: ipa) {
                        value = dev.read(
                            address: ipa,
                            size: accessSize
                        )
                    } else if pcie.containsConfig(ipa) {
                        value = pcie.readConfig(address: ipa, size: accessSize)
                    } else if pcie.containsIO(ipa) {
                        value = pcie.readIO(address: ipa, size: accessSize)
                    } else if nvme.containsMMIO(ipa) {
                        value = nvme.readMMIO(address: ipa, size: accessSize)
                    } else if xhci.containsMMIO(ipa) {
                        value = xhci.readMMIO(address: ipa, size: accessSize)
                    } else {
                        value = nil
                    }

                    guard let value else {
                        print(
                            "❌ MMIO read failed @ 0x" +
                            String(ipa, radix: 16)
                        )
                        return false
                    }

                    // XZR/WZR discards the result.
                    if srt != 31 {

                        guard srt < registers.count else {
                            print(
                                "❌ Invalid MMIO target register"
                            )
                            return false
                        }

                        guard cpu.setRegister(
                            registers[srt],
                            value: value
                        ) else {
                            return false
                        }
                    }
                }

                let pc = cpu.register(HV_REG_PC)

                guard cpu.setRegister(
                    HV_REG_PC,
                    value: pc + 4
                ) else {
                    return false
                }

                return true
            }

            // EC 0x18 = Trapped MSR, MRS, or System Instruction in AArch64
            if exceptionClass == 0x18 {
                let iss = esr & 0x01FF_FFFF
                let isRead = (iss & 1) == 1
                let crm = Int((iss >> 1) & 0xF)
                let rt = Int((iss >> 5) & 0x1F)
                let crn = Int((iss >> 10) & 0xF)
                let op1 = Int((iss >> 14) & 0x7)
                let op2 = Int((iss >> 17) & 0x7)
                let op0 = Int((iss >> 20) & 0x3)

                // Match OSLSR_EL1: Op0=2, Op1=0, CRn=1, CRm=1, Op2=4
                if op0 == 2 && op1 == 0 && crn == 1 && crm == 1 && op2 == 4 {
                    if isRead {
                        // OS Lock Status Register (OSLSR_EL1):
                        // Bit 3 = OSLM[1] (1 = OS Lock implemented)
                        // Bit 2 = nTT (0)
                        // Bit 1 = OSLK (0 = Unlocked, 1 = Locked)
                        // Bit 0 = OSLM[0] (0)
                        // Return 0x8 when unlocked (OSLM=0b10, OSLK=0).
                        oslarLock.lock()
                        let isLocked = oslarLocked
                        oslarLock.unlock()
                        let val: UInt64 = isLocked ? 0x0A : 0x08
                        if rt < 31 {
                            let reg = hv_reg_t(HV_REG_X0.rawValue + UInt32(rt))
                            cpu.setRegister(reg, value: val)
                        }
                    }
                    let pc = cpu.register(HV_REG_PC)
                    cpu.setRegister(HV_REG_PC, value: pc + 4)
                    return true
                }

                // Match OSLAR_EL1: Op0=2, Op1=0, CRn=1, CRm=0, Op2=4
                if op0 == 2 && op1 == 0 && crn == 1 && crm == 0 && op2 == 4 {
                    if !isRead {
                        // OS Lock Access Register (OSLAR_EL1):
                        // Bit 0 = OSLK (1 = lock, 0 = unlock)
                        let regVal: UInt64
                        if rt < 31 {
                            let reg = hv_reg_t(HV_REG_X0.rawValue + UInt32(rt))
                            regVal = cpu.register(reg)
                        } else {
                            regVal = 0
                        }
                        oslarLock.lock()
                        oslarLocked = (regVal & 1) != 0
                        oslarLock.unlock()
                    }
                    let pc = cpu.register(HV_REG_PC)
                    cpu.setRegister(HV_REG_PC, value: pc + 4)
                    return true
                }

                // Match OSDLR_EL1: Op0=2, Op1=0, CRn=1, CRm=3, Op2=4 (DoubleLock status)
                if op0 == 2 && op1 == 0 && crn == 1 && crm == 3 && op2 == 4 {
                    if isRead && rt < 31 {
                        let reg = hv_reg_t(HV_REG_X0.rawValue + UInt32(rt))
                        cpu.setRegister(reg, value: 0)
                    }
                    let pc = cpu.register(HV_REG_PC)
                    cpu.setRegister(HV_REG_PC, value: pc + 4)
                    return true
                }

                print("❌ Unhandled trapped system register:")
                print("   Direction: \(isRead ? "READ (MRS)" : "WRITE (MSR)")")
                print("   Rt: X\(rt)")
                print("   Encoding: Op0=\(op0), Op1=\(op1), CRn=\(crn), CRm=\(crm), Op2=\(op2) (S\(op0)_\(op1)_c\(crn)_c\(crm)_\(op2))")
                let pc = cpu.register(HV_REG_PC)
                print("   PC: 0x" + String(pc, radix: 16))
                return false
            }

            // EC 0x16 = HVC executed in AArch64 state
            guard exceptionClass == 0x16 else {

                print("")
                print("================================")
                print("🧪 TEST #6A.13 — EXCEPTION STATE")
                print("================================")
                print("Host exit EC: 0x" + String(exceptionClass, radix: 16))
                print("Host exit ESR: 0x" + String(esr, radix: 16))

                let pc = cpu.register(HV_REG_PC)
                print("Current PC: 0x" + String(pc, radix: 16))

                let sysRegs: [(String, hv_sys_reg_t)] = [
                    ("VBAR_EL1", HV_SYS_REG_VBAR_EL1),
                    ("ELR_EL1", HV_SYS_REG_ELR_EL1),
                    ("SPSR_EL1", HV_SYS_REG_SPSR_EL1),
                    ("ESR_EL1", HV_SYS_REG_ESR_EL1),
                    ("FAR_EL1", HV_SYS_REG_FAR_EL1),
                    ("SP_EL0", HV_SYS_REG_SP_EL0),
                    ("SP_EL1", HV_SYS_REG_SP_EL1)
                ]

                for (name, reg) in sysRegs {
                    var value: UInt64 = 0
                    let result = hv_vcpu_get_sys_reg(
                        cpu.vcpu,
                        reg,
                        &value
                    )

                    if result == HV_SUCCESS {
                        print(name + ": 0x" + String(value, radix: 16))
                    } else {
                        print("❌ " + name + " read failed: \(result)")
                    }
                }

                var irqPending = false
                var fiqPending = false

                let irqResult = hv_vcpu_get_pending_interrupt(
                    cpu.vcpu,
                    HV_INTERRUPT_TYPE_IRQ,
                    &irqPending
                )

                let fiqResult = hv_vcpu_get_pending_interrupt(
                    cpu.vcpu,
                    HV_INTERRUPT_TYPE_FIQ,
                    &fiqPending
                )

                if irqResult == HV_SUCCESS {
                    print("IRQ pending: \(irqPending)")
                }

                if fiqResult == HV_SUCCESS {
                    print("FIQ pending: \(fiqPending)")
                }

                print("================================")
                print("")
                return false
            }
            if Self.verbose {
                print(
                    "VM Exit #\(exitNumber)",
                    terminator: " "
                )
            }

            // Test #6A.3:
            // Service 99 means the guest has configured CNTV itself
            // and reached the verification HVC.
            let service = cpu.register(HV_REG_X0)

            switch trng.handle(cpu: cpu) {
            case .handled:
                return true
            case .notHandled:
                break
            }

            switch psci.handle(cpu: cpu) {

            case .handledContinue:
                return true

            case .cpuOff:
                return cpu.waitForBoot()

            case .systemOff:
                print("")
                print("🛑 Guest requested system off")
                return false

            case .systemReset:
                print("")
                print("🔄 Guest requested system reset")
                resetLock.lock()
                systemResetRequested = true
                resetLock.unlock()
                return false

            case .notHandled:
                break
            }

            if service == 104 {
                print("")
                print("")
                print("================================")

                if uart.output == "FLUX\n" {
                    print("🔥 TEST #7 PASS")
                    print("Guest MMIO UART write emulation works")
                } else {
                    print("❌ TEST #7 FAIL")
                    print(
                        "UART output: " +
                        String(reflecting: uart.output)
                    )
                }

                print("================================")
                return false
            }

            if service == 102 {
                print("")
                print("================================")
                print("🔥 TEST #6B.2 PASS")
                print("IRQ acknowledged and completed")
                print("ICC_EOIR1_EL1 completed")
                print("ERET returned to guest successfully")
                print("================================")
                return false
            }

            if service == 103 {
                print("")
                print("================================")
                print("❌ TEST #6B.2 FAIL")
                print("Unexpected ICC_IAR1_EL1 INTID")
                print("Expected INTID: 27")
                print("================================")
                return false
            }

            if service == 101 {
                print("")
                print("================================")
                print("🔥 TEST #6B.1 PASS")
                print("EL1 IRQ VECTOR ENTERED")
                print("Timer -> GIC -> PPI 27 -> EL1 IRQ")
                print("================================")
                return false
            }

            if service == 100 {

                let cntvct = cpu.register(HV_REG_X1)
                let cntfrq = cpu.register(HV_REG_X2)

                print("")
                print("================================")
                print("🧪 TEST #6A.7 — TIMER FREQUENCY")
                print("================================")
                print("CNTVCT_EL0: \(cntvct)")
                print("CNTFRQ_EL0: \(cntfrq) Hz")

                if cntfrq > 0 {
                    print("Ticks / 1 ms: \(cntfrq / 1000)")
                }

                print("================================")

                return false
            }

            if service == 99 {

                print("HVC service=99 — VTimer verification")

                var cval: UInt64 = 0
                var ctl: UInt64 = 0
                var masked = true

                let cvalResult = hv_vcpu_get_sys_reg(
                    cpu.vcpu,
                    HV_SYS_REG_CNTV_CVAL_EL0,
                    &cval
                )

                let ctlResult = hv_vcpu_get_sys_reg(
                    cpu.vcpu,
                    HV_SYS_REG_CNTV_CTL_EL0,
                    &ctl
                )

                let maskResult = hv_vcpu_get_vtimer_mask(
                    cpu.vcpu,
                    &masked
                )

                let pc = cpu.register(HV_REG_PC)

                print("")
                print("----- VTIMER GUEST VERIFICATION -----")
                print("PC: 0x" + String(pc, radix: 16))

                if cvalResult == HV_SUCCESS {
                    print("CNTV_CVAL_EL0: \(cval)")
                } else {
                    print("❌ CNTV_CVAL read failed: \(cvalResult)")
                }

                if ctlResult == HV_SUCCESS {
                    print(
                        "CNTV_CTL_EL0: 0x" +
                        String(ctl, radix: 16)
                    )
                } else {
                    print("❌ CNTV_CTL read failed: \(ctlResult)")
                }

                if maskResult == HV_SUCCESS {
                    print("Hypervisor VTimer masked: \(masked)")
                } else {
                    print("❌ VTimer mask read failed: \(maskResult)")
                }

                let unmaskResult = hv_vcpu_set_vtimer_mask(
                    cpu.vcpu,
                    false
                )

                print(
                    "VTimer explicit unmask result: \(unmaskResult)"
                )

                var verifyMask = true

                let verifyMaskResult = hv_vcpu_get_vtimer_mask(
                    cpu.vcpu,
                    &verifyMask
                )

                if verifyMaskResult == HV_SUCCESS {
                    print(
                        "VTimer mask immediately before re-entry: \(verifyMask)"
                    )
                }

                print("-------------------------------------")
                print("▶️ Re-entering guest for clean VTimer test...")
                print("")

                return true
            }

            return hypercall.handle(cpu: cpu)

        case HV_EXIT_REASON_CANCELED:

            print("")
            print("================================")
            print("🧪 TEST #6A.5 — FORCED EXIT")
            print("================================")

            var ctl: UInt64 = 0
            var cval: UInt64 = 0
            var masked = true

            let ctlResult = hv_vcpu_get_sys_reg(
                cpu.vcpu,
                HV_SYS_REG_CNTV_CTL_EL0,
                &ctl
            )

            let cvalResult = hv_vcpu_get_sys_reg(
                cpu.vcpu,
                HV_SYS_REG_CNTV_CVAL_EL0,
                &cval
            )

            let maskResult = hv_vcpu_get_vtimer_mask(
                cpu.vcpu,
                &masked
            )

            if ctlResult == HV_SUCCESS {

                let enabled = (ctl & 0x1) != 0
                let imask = (ctl & 0x2) != 0
                let istatus = (ctl & 0x4) != 0

                print(
                    "CNTV_CTL_EL0: 0x" +
                    String(ctl, radix: 16)
                )

                print("ENABLE : \(enabled)")
                print("IMASK  : \(imask)")
                print("ISTATUS: \(istatus)")

            } else {

                print(
                    "❌ CNTV_CTL read failed: \(ctlResult)"
                )
            }

            if cvalResult == HV_SUCCESS {

                print(
                    "CNTV_CVAL_EL0: \(cval)"
                )

            } else {

                print(
                    "❌ CNTV_CVAL read failed: \(cvalResult)"
                )
            }

            if maskResult == HV_SUCCESS {

                print(
                    "Hypervisor VTimer masked: \(masked)"
                )

            } else {

                print(
                    "❌ VTimer mask read failed: \(maskResult)"
                )
            }

            print("================================")

            return false

        case HV_EXIT_REASON_VTIMER_ACTIVATED:

            print("================================")
            print("⏱ VIRTUAL TIMER FIRED")
            print("🔥 TEST #6A PASS")
            print("Hypervisor returned VTIMER_ACTIVATED")
            print("================================")
            return false

        default:

            print(
                "❌ Unknown VM exit: " +
                "\(exit.reason.rawValue)"
            )

            return false
        }
    }
}
