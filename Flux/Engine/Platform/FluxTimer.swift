import Foundation
import Hypervisor
import Darwin

nonisolated final class FluxTimer {

    private(set) var virtualTimerINTID: UInt32 = 0

    func initialize() -> Bool {

        var intid: UInt32 = 0

        let result = hv_gic_get_intid(
            HV_GIC_INT_EL1_VIRTUAL_TIMER,
            &intid
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed getting virtual timer INTID: \(result)")
            return false
        }

        virtualTimerINTID = intid

        print("✅ Flux virtual timer initialized")
        print("   GIC INTID: \(intid)")

        return true
    }

    func arm(
        cpu: FluxVCPU,
        milliseconds: UInt64
    ) -> Bool {

        // Apple Hypervisor.framework:
        //
        // CNTVCT_EL0 =
        //     mach_absolute_time() - vtimer_offset

        var offset: UInt64 = 0

        var result = hv_vcpu_get_vtimer_offset(
            cpu.vcpu,
            &offset
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed reading VTimer offset: \(result)")
            return false
        }

        var timebase = mach_timebase_info_data_t()

        guard mach_timebase_info(&timebase) == KERN_SUCCESS else {
            print("❌ Failed reading mach timebase")
            return false
        }

        let hostNow = mach_absolute_time()

        // Current guest virtual counter.
        let guestNow = hostNow &- offset

        let nanoseconds =
            milliseconds * 1_000_000

        // Convert nanoseconds -> mach absolute-time ticks.
        let deltaTicks =
            nanoseconds *
            UInt64(timebase.denom) /
            UInt64(timebase.numer)

        // Test #6A.1:
        // Force the virtual timer condition to already be true
        // before hv_vcpu_run(). This removes host timing/race
        // from the experiment.
        let deadline =
            guestNow &- 1

        result = hv_vcpu_set_sys_reg(
            cpu.vcpu,
            HV_SYS_REG_CNTV_CVAL_EL0,
            deadline
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed setting CNTV_CVAL_EL0: \(result)")
            return false
        }

        // ENABLE = 1
        // IMASK  = 0
        result = hv_vcpu_set_sys_reg(
            cpu.vcpu,
            HV_SYS_REG_CNTV_CTL_EL0,
            1
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed enabling CNTV timer: \(result)")
            return false
        }

        // Allow Hypervisor to exit when VTimer activates.
        result = hv_vcpu_set_vtimer_mask(
            cpu.vcpu,
            false
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed unmasking VTimer: \(result)")
            return false
        }

        // Read back timer state for Test #6A diagnostics.

        var readCVAL: UInt64 = 0
        var readCTL: UInt64 = 0
        var masked = true

        let cvalResult = hv_vcpu_get_sys_reg(
            cpu.vcpu,
            HV_SYS_REG_CNTV_CVAL_EL0,
            &readCVAL
        )

        let ctlResult = hv_vcpu_get_sys_reg(
            cpu.vcpu,
            HV_SYS_REG_CNTV_CTL_EL0,
            &readCTL
        )

        let maskResult = hv_vcpu_get_vtimer_mask(
            cpu.vcpu,
            &masked
        )

        print("⏱ Flux virtual timer armed")
        print("   Delay: \(milliseconds) ms")
        print("   Host now: \(hostNow)")
        print("   VTimer offset: \(offset)")
        print("   Guest CNTVCT estimate: \(guestNow)")
        print("   Deadline: \(deadline)")

        if cvalResult == HV_SUCCESS {
            print("   CNTV_CVAL_EL0: \(readCVAL)")
        }

        if ctlResult == HV_SUCCESS {
            print(
                "   CNTV_CTL_EL0: 0x" +
                String(readCTL, radix: 16)
            )
        }

        if maskResult == HV_SUCCESS {
            print("   Hypervisor VTimer masked: \(masked)")
        }

        return true
    }
}
