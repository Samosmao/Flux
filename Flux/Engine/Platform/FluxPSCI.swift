import Foundation
import Hypervisor

nonisolated final class FluxPSCI {

    // SMCCC
    private let smcccVersion: UInt64 = 0x80000000
    private let smcccArchFeatures: UInt64 = 0x80000001

    // PSCI 32-bit & 64-bit function IDs
    private let psciVersion: UInt64 = 0x84000000
    private let psciCPUOff: UInt64 = 0x84000002
    private let psciCPUOn32: UInt64 = 0x84000003
    private let psciCPUOn64: UInt64 = 0xC4000003
    private let psciAffinityInfo32: UInt64 = 0x84000004
    private let psciAffinityInfo64: UInt64 = 0xC4000004
    private let psciSystemOff: UInt64 = 0x84000008
    private let psciSystemReset: UInt64 = 0x84000009
    private let psciFeatures: UInt64 = 0x8400000A

    // PSCI return values
    private let psciSuccess: UInt64 = 0
    private let psciNotSupported: UInt64 = UInt64(bitPattern: Int64(-1))
    private let psciInvalidParameters: UInt64 = UInt64(bitPattern: Int64(-2))
    private let psciAlreadyOn: UInt64 = UInt64(bitPattern: Int64(-4))

    /// Reference to all platform vCPUs for SMP coordination
    weak var vm: FluxVM?
    var vcpus: [FluxVCPU] = []

    enum Result {
        case handledContinue
        case cpuOff
        case systemOff
        case systemReset
        case notHandled
    }

    func handle(
        cpu: FluxVCPU
    ) -> Result {

        let functionID = cpu.register(HV_REG_X0)

        switch functionID {

        // SMCCC v1.1
        case smcccVersion:
            _ = cpu.setRegister(
                HV_REG_X0,
                value: 0x00010001
            )
            return .handledContinue

        case smcccArchFeatures:
            _ = cpu.setRegister(
                HV_REG_X0,
                value: psciNotSupported
            )
            return .handledContinue

        // PSCI v1.1
        case psciVersion:
            _ = cpu.setRegister(
                HV_REG_X0,
                value: 0x00010001
            )
            return .handledContinue

        case psciFeatures:
            let queriedFunction = cpu.register(HV_REG_X1)
            let supported: Bool

            switch queriedFunction {
            case psciVersion,
                 smcccVersion,
                 psciCPUOff,
                 psciCPUOn32,
                 psciCPUOn64,
                 psciAffinityInfo32,
                 psciAffinityInfo64,
                 psciSystemOff,
                 psciSystemReset,
                 psciFeatures:
                supported = true
            default:
                supported = false
            }

            _ = cpu.setRegister(
                HV_REG_X0,
                value: supported ? psciSuccess : psciNotSupported
            )
            return .handledContinue

        // CPU_ON (64-bit and 32-bit)
        case psciCPUOn64, psciCPUOn32:
            let targetMPIDR = cpu.register(HV_REG_X1)
            let entryPoint = cpu.register(HV_REG_X2)
            let contextId = cpu.register(HV_REG_X3)

            let targetAff0 = Int(targetMPIDR & 0xFF)
            guard targetAff0 < vcpus.count else {
                print("❌ PSCI CPU_ON: Invalid target MPIDR 0x\(String(targetMPIDR, radix: 16))")
                _ = cpu.setRegister(HV_REG_X0, value: psciInvalidParameters)
                return .handledContinue
            }

            let targetCPU = vcpus[targetAff0]
            if targetCPU.state == .running {
                _ = cpu.setRegister(HV_REG_X0, value: psciAlreadyOn)
                return .handledContinue
            }

            let booted = targetCPU.requestBoot(entryPoint: entryPoint, contextId: contextId)
            let ret = booted ? psciSuccess : psciAlreadyOn
            _ = cpu.setRegister(HV_REG_X0, value: ret)
            return .handledContinue

        // AFFINITY_INFO (64-bit and 32-bit)
        case psciAffinityInfo64, psciAffinityInfo32:
            let targetMPIDR = cpu.register(HV_REG_X1)
            let targetAff0 = Int(targetMPIDR & 0xFF)

            guard targetAff0 < vcpus.count else {
                _ = cpu.setRegister(HV_REG_X0, value: psciInvalidParameters)
                return .handledContinue
            }

            // 0: ON, 1: OFF
            let status: UInt64 = (vcpus[targetAff0].state == .running) ? 0 : 1
            _ = cpu.setRegister(HV_REG_X0, value: status)
            return .handledContinue

        // CPU_OFF
        case psciCPUOff:
            cpu.powerOff()
            return .cpuOff

        case psciSystemOff:
            print("🛑 PSCI_SYSTEM_OFF")
            return .systemOff

        case psciSystemReset:
            print("🔄 PSCI_SYSTEM_RESET")
            return .systemReset

        default:
            if (functionID & 0x80000000) != 0 {
                // Return NOT_SUPPORTED (-1) for unhandled SMCCC/PSCI calls per ARM DEN 0028C
                _ = cpu.setRegister(HV_REG_X0, value: psciNotSupported)
                return .handledContinue
            }
            return .notHandled
        }
    }
}
