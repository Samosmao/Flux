import Foundation
import Hypervisor

nonisolated final class FluxVCPU {

    enum State: Sendable {
        case poweredOff
        case bootRequested
        case running
    }

    let id: Int
    private(set) var vcpu: hv_vcpu_t = 0

    private(set) var exitInfo:
        UnsafeMutablePointer<hv_vcpu_exit_t>?

    private(set) var isCreated = false

    private let condition = NSCondition()
    private(set) var state: State = .poweredOff
    private(set) var pendingEntryPoint: UInt64 = 0
    private(set) var pendingContextId: UInt64 = 0
    private(set) var shouldExit = false
    // A platform reset must not reprogram this vCPU's architectural/GIC state
    // while Hypervisor.framework still has it in hv_vcpu_run().
    private var executingInHypervisor = false

    init(id: Int = 0) {
        self.id = id
        if id == 0 {
            self.state = .running
        }
    }

    func create() -> Bool {

        let result = hv_vcpu_create(
            &vcpu,
            &exitInfo,
            nil
        )

        guard result == HV_SUCCESS else {
            print("❌ [vCPU \(id)] hv_vcpu_create failed: \(result)")
            return false
        }

        guard exitInfo != nil else {
            print("❌ [vCPU \(id)] Missing vCPU exit information")
            _ = hv_vcpu_destroy(vcpu)
            return false
        }

        isCreated = true

        // vCPU affinity:
        // Aff3=0, Aff2=0, Aff1=0, Aff0=id
        let mpidrValue = UInt64(id)
        let mpidrResult = hv_vcpu_set_sys_reg(
            vcpu,
            HV_SYS_REG_MPIDR_EL1,
            mpidrValue
        )

        guard mpidrResult == HV_SUCCESS else {
            print("❌ [vCPU \(id)] Failed setting MPIDR_EL1: \(mpidrResult)")
            _ = hv_vcpu_destroy(vcpu)
            isCreated = false
            exitInfo = nil
            return false
        }

        var mpidr: UInt64 = 0

        let readResult = hv_vcpu_get_sys_reg(
            vcpu,
            HV_SYS_REG_MPIDR_EL1,
            &mpidr
        )

        guard readResult == HV_SUCCESS else {
            print("❌ [vCPU \(id)] Failed reading MPIDR_EL1: \(readResult)")
            _ = hv_vcpu_destroy(vcpu)
            isCreated = false
            exitInfo = nil
            return false
        }

        // Enable PMU visibility: set PMUVer=0x1 in ID_AA64DFR0_EL1 bits [11:8]
        // so guest MRS PMCCNTR_EL0 etc. execute natively instead of UNDEFINED
        var dfr0: UInt64 = 0
        if hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_ID_AA64DFR0_EL1, &dfr0) == HV_SUCCESS {
            let newDfr0 = (dfr0 & ~UInt64(0xF00)) | (UInt64(0x1) << 8)
            let pmuResult = hv_vcpu_set_sys_reg(
                vcpu,
                HV_SYS_REG_ID_AA64DFR0_EL1,
                newDfr0
            )
            guard pmuResult == HV_SUCCESS else {
                print("❌ [vCPU \(id)] Failed setting PMUVer in ID_AA64DFR0_EL1: \(pmuResult)")
                _ = hv_vcpu_destroy(vcpu)
                isCreated = false
                exitInfo = nil
                return false
            }
        }

        print("✅ [vCPU \(id)] Created (MPIDR_EL1=0x\(String(mpidr, radix: 16)))")
        return true
    }

    func initialize(pc: hv_ipa_t) -> Bool {

        guard isCreated else {
            print("❌ [vCPU \(id)] vCPU not created")
            return false
        }

        var result = hv_vcpu_set_reg(
            vcpu,
            HV_REG_PC,
            UInt64(pc)
        )

        guard result == HV_SUCCESS else {
            print("❌ [vCPU \(id)] Failed setting PC: \(result)")
            return false
        }

        result = hv_vcpu_set_reg(
            vcpu,
            HV_REG_CPSR,
            0x5
        )

        guard result == HV_SUCCESS else {
            print("❌ [vCPU \(id)] Failed setting CPSR: \(result)")
            return false
        }

        let vectorBase: UInt64 = 0x40001000

        result = hv_vcpu_set_sys_reg(
            vcpu,
            HV_SYS_REG_VBAR_EL1,
            vectorBase
        )

        guard result == HV_SUCCESS else {
            print("❌ [vCPU \(id)] Failed setting VBAR_EL1: \(result)")
            return false
        }

        state = .running
        return true
    }

    /// Called by another vCPU (via PSCI CPU_ON) to request booting this secondary vCPU.
    func requestBoot(entryPoint: UInt64, contextId: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }

        guard state == .poweredOff else {
            return false
        }

        pendingEntryPoint = entryPoint
        pendingContextId = contextId
        state = .bootRequested
        condition.signal()
        return true
    }

    /// Called by the secondary vCPU's owning thread to wait until PSCI CPU_ON boots it.
    func waitForBoot() -> Bool {
        condition.lock()
        defer { condition.unlock() }

        while state == .poweredOff && !shouldExit {
            condition.wait()
        }

        if shouldExit {
            return false
        }

        guard state == .bootRequested else {
            return false
        }

        // Apply initial register state on owning thread
        _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, pendingEntryPoint)
        _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, pendingContextId)
        // EL1h with all DAIF masked per ARM PSCI specification
        _ = hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3c5)
        let vectorBase: UInt64 = 0x40001000
        _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_VBAR_EL1, vectorBase)

        state = .running
        print("⚡️ [vCPU \(id)] Booted via PSCI CPU_ON (PC=0x\(String(pendingEntryPoint, radix: 16)), X0=0x\(String(pendingContextId, radix: 16)))")
        return true
    }

    /// Power off this vCPU (called when guest executes PSCI CPU_OFF).
    func powerOff() {
        condition.lock()
        state = .poweredOff
        condition.unlock()
        print("💤 [vCPU \(id)] Powered off via PSCI CPU_OFF")
    }

    /// Stop this vCPU thread.
    func requestExit() {
        condition.lock()
        shouldExit = true
        condition.signal()
        condition.unlock()

        if isCreated {
            var v = vcpu
            _ = hv_vcpus_exit(&v, 1)
        }
    }

    func resetForRestart() {
        condition.lock()
        shouldExit = false
        state = (id == 0) ? .running : .poweredOff
        condition.unlock()
    }

    /// Resets registers of this vCPU to initial firmware entry state across platform reboot,
    /// avoiding vCPU destruction which would break GIC redistributor bindings.
    func resetRegisters(pc: UInt64, x0: UInt64) -> Bool {
        guard isCreated, isQuiesced else {
            print("❌ [vCPU \(id)] Cannot reset registers before the vCPU is quiesced")
            return false
        }

        func setRegister(_ register: hv_reg_t, _ value: UInt64) -> Bool {
            let result = hv_vcpu_set_reg(vcpu, register, value)
            guard result == HV_SUCCESS else {
                print("❌ [vCPU \(id)] Reset register write failed: \(result)")
                return false
            }
            return true
        }
        func setSystemRegister(_ register: hv_sys_reg_t, _ value: UInt64) -> Bool {
            let result = hv_vcpu_set_sys_reg(vcpu, register, value)
            guard result == HV_SUCCESS else {
                print("❌ [vCPU \(id)] Reset system-register write failed: \(result)")
                return false
            }
            return true
        }

        guard setRegister(HV_REG_PC, pc),
              setRegister(HV_REG_X0, x0) else { return false }
        for i: UInt32 in 1...28 {
            guard setRegister(hv_reg_t(HV_REG_X0.rawValue + i), 0) else { return false }
        }
        guard setRegister(HV_REG_FP, 0),
              setRegister(HV_REG_LR, 0),
              setSystemRegister(HV_SYS_REG_SP_EL1, 0),
              setSystemRegister(HV_SYS_REG_SP_EL0, 0),
              setRegister(HV_REG_CPSR, 0x5) else { return false }

        // Reset EL1 system registers to architectural reset state (MMU & caches disabled)
        guard setSystemRegister(HV_SYS_REG_SCTLR_EL1, 0x00c50078),
              setSystemRegister(HV_SYS_REG_TCR_EL1, 0),
              setSystemRegister(HV_SYS_REG_TTBR0_EL1, 0),
              setSystemRegister(HV_SYS_REG_TTBR1_EL1, 0),
              setSystemRegister(HV_SYS_REG_VBAR_EL1, 0x40001000),
              setSystemRegister(HV_SYS_REG_CPACR_EL1, 0),
              setSystemRegister(HV_SYS_REG_CNTV_CTL_EL0, 0) else { return false }

        condition.lock()
        state = .running
        condition.unlock()
        return true
    }

    func run() -> hv_return_t {
        condition.lock()
        executingInHypervisor = true
        condition.unlock()

        let result = hv_vcpu_run(vcpu)

        condition.lock()
        executingInHypervisor = false
        condition.broadcast()
        condition.unlock()
        return result
    }

    var isQuiesced: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !executingInHypervisor
    }

    /// Wait until the owning thread has returned from hv_vcpu_run().
    func waitUntilQuiesced() {
        condition.lock()
        while executingInHypervisor {
            condition.wait()
        }
        condition.unlock()
    }

    func register(_ register: hv_reg_t) -> UInt64 {

        var value: UInt64 = 0

        let result = hv_vcpu_get_reg(
            vcpu,
            register,
            &value
        )

        if result != HV_SUCCESS {
            print("⚠️ Failed reading register: \(result)")
        }

        return value
    }

    @discardableResult
    func setRegister(
        _ register: hv_reg_t,
        value: UInt64
    ) -> Bool {
        let result = hv_vcpu_set_reg(
            vcpu,
            register,
            value
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed writing register: \(result)")
            return false
        }

        return true
    }

    func cleanup() {

        guard isCreated else {
            return
        }

        let result = hv_vcpu_destroy(vcpu)

        if result == HV_SUCCESS {
            print("✅ [vCPU \(id)] Destroyed")
        } else {
            print("⚠️ [vCPU \(id)] hv_vcpu_destroy: \(result)")
        }

        isCreated = false
        exitInfo = nil
        state = .poweredOff
    }
}
