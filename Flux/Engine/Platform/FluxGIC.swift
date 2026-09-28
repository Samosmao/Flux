import Foundation
import Hypervisor

nonisolated final class FluxGIC {

    /// GICv2m-compatible message frame exposed through the virtual GIC.  This
    /// is deliberately a message-based SPI frame, not an ITS/LPI interface.
    struct MSIFrame: Sendable {
        let base: hv_ipa_t
        let size: Int
        let alignment: Int
        let spiBase: UInt32
        let spiCount: UInt32

        var setSPINSRAddress: hv_ipa_t {
            base + hv_ipa_t(HV_GIC_REG_GICM_SET_SPI_NSR.rawValue)
        }
    }

    /// The ACPI producer runs after `create()` and consumes this exact
    /// descriptor for the MADT Generic MSI Frame entry.
    private(set) static var msiFrame: MSIFrame?

    /// Keep this separate from all fixed platform SPIs: UART=33, VirtIO=48/49,
    /// and legacy NVMe INTx=50.
    static let msiSPIBase: UInt32 = 64
    static let msiSPICount: UInt32 = 16

    // Keep GIC MMIO away from guest RAM at 0x40000000.
    private(set) var distributorBase: hv_ipa_t = 0x08000000
    private(set) var redistributorBase: hv_ipa_t = 0x080A0000

    private(set) var distributorSize: Int = 0
    private(set) var redistributorRegionSize: Int = 0

    private(set) var spiBase: UInt32 = 0
    private(set) var spiCount: UInt32 = 0

    private(set) var msiRegionBase: hv_ipa_t = 0
    private(set) var msiRegionSize: Int = 0
    private(set) var msiRegionAlignment: Int = 0

    private(set) var isCreated = false

    func create() -> Bool {

        var distSize: Int = 0
        var distAlignment: Int = 0

        var redistRegionSize: Int = 0
        var redistAlignment: Int = 0

        var msiSize: Int = 0
        var msiAlignment: Int = 0

        var spiBaseValue: UInt32 = 0
        var spiCountValue: UInt32 = 0

        var result = hv_gic_get_distributor_size(
            &distSize
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed getting GIC distributor size: \(result)")
            return false
        }

        result = hv_gic_get_distributor_base_alignment(
            &distAlignment
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed getting GIC distributor alignment: \(result)")
            return false
        }

        result = hv_gic_get_redistributor_region_size(
            &redistRegionSize
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed getting GIC redistributor region size: \(result)")
            return false
        }

        result = hv_gic_get_redistributor_base_alignment(
            &redistAlignment
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed getting GIC redistributor alignment: \(result)")
            return false
        }

        result = hv_gic_get_spi_interrupt_range(
            &spiBaseValue,
            &spiCountValue
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed getting GIC SPI range: \(result)")
            return false
        }

        result = hv_gic_get_msi_region_size(&msiSize)
        guard result == HV_SUCCESS, msiSize > 0 else {
            print("❌ Failed getting GIC MSI region size: \(result)")
            return false
        }

        result = hv_gic_get_msi_region_base_alignment(&msiAlignment)
        guard result == HV_SUCCESS, msiAlignment > 0 else {
            print("❌ Failed getting GIC MSI region alignment: \(result)")
            return false
        }

        let requestedMSIEnd = Self.msiSPIBase + Self.msiSPICount
        let availableSPIEnd = spiBaseValue + spiCountValue
        guard Self.msiSPIBase >= spiBaseValue,
              requestedMSIEnd <= availableSPIEnd else {
            print("❌ GIC SPI range \(spiBaseValue)...\(availableSPIEnd - 1) cannot reserve MSI \(Self.msiSPIBase)...\(requestedMSIEnd - 1)")
            return false
        }

        distributorSize = distSize
        redistributorRegionSize = redistRegionSize

        spiBase = spiBaseValue
        spiCount = spiCountValue
        msiRegionSize = msiSize
        msiRegionAlignment = msiAlignment

        // Align the requested MMIO bases using the values
        // reported by Hypervisor.framework.
        distributorBase = alignUp(
            distributorBase,
            alignment: distAlignment
        )

        redistributorBase = alignUp(
            redistributorBase,
            alignment: redistAlignment
        )

        // Place the queried MSI frame directly after the queried GICR region,
        // then align it exactly as required by Hypervisor.framework.
        msiRegionBase = alignUp(
            redistributorBase + hv_ipa_t(redistRegionSize),
            alignment: msiAlignment
        )

        let config = hv_gic_config_create()

        result = hv_gic_config_set_distributor_base(
            config,
            distributorBase
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed setting GIC distributor base: \(result)")
            return false
        }

        result = hv_gic_config_set_redistributor_base(
            config,
            redistributorBase
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed setting GIC redistributor base: \(result)")
            return false
        }

        result = hv_gic_config_set_msi_region_base(config, msiRegionBase)
        guard result == HV_SUCCESS else {
            print("❌ Failed setting GIC MSI region base: \(result)")
            return false
        }

        result = hv_gic_config_set_msi_interrupt_range(
            config,
            Self.msiSPIBase,
            Self.msiSPICount
        )
        guard result == HV_SUCCESS else {
            print("❌ Failed setting GIC MSI SPI range: \(result)")
            return false
        }

        result = hv_gic_create(config)

        guard result == HV_SUCCESS else {
            print("❌ hv_gic_create failed: \(result)")
            return false
        }

        isCreated = true
        Self.msiFrame = MSIFrame(
            base: msiRegionBase,
            size: msiRegionSize,
            alignment: msiRegionAlignment,
            spiBase: Self.msiSPIBase,
            spiCount: Self.msiSPICount
        )

        print("✅ GICv3 created")
        print(
            "   Distributor: 0x" +
            String(distributorBase, radix: 16)
        )
        print(
            "   Distributor size: \(distributorSize) bytes"
        )
        print(
            "   Redistributor: 0x" +
            String(redistributorBase, radix: 16)
        )
        print(
            "   Redistributor region size: " +
            "\(redistributorRegionSize) bytes"
        )
        print(
            "   SPI range: \(spiBase)..." +
            "\(spiBase + spiCount - 1)"
        )
        print("   MSI frame: 0x\(String(msiRegionBase, radix: 16)) (\(msiRegionSize) bytes, align \(msiRegionAlignment))")
        print("   MSI SPI range: \(Self.msiSPIBase)...\(Self.msiSPIBase + Self.msiSPICount - 1)")

        return true
    }

    func reset() {

        guard isCreated else {
            return
        }

        let result = hv_gic_reset()

        if result == HV_SUCCESS {
            print("✅ GICv3 reset")
        } else {
            print("⚠️ hv_gic_reset: \(result)")
        }

        isCreated = false
        Self.msiFrame = nil
    }

    static func validMSI(address: hv_ipa_t, intid: UInt32) -> Bool {
        guard let frame = msiFrame else { return false }
        return address == frame.setSPINSRAddress &&
            intid >= frame.spiBase && intid < frame.spiBase + frame.spiCount
    }

    private func alignUp(
        _ value: hv_ipa_t,
        alignment: Int
    ) -> hv_ipa_t {

        guard alignment > 0 else {
            return value
        }

        let a = hv_ipa_t(alignment)

        return (value + a - 1) & ~(a - 1)
    }

    func dumpCPUInterface(vcpu: hv_vcpu_t) {

        print("")
        print("===== GIC CPU INTERFACE =====")

        let registers: [(String, hv_gic_icc_reg_t)] = [
            ("ICC_SRE_EL1", HV_GIC_ICC_REG_SRE_EL1),
            ("ICC_PMR_EL1", HV_GIC_ICC_REG_PMR_EL1),
            ("ICC_CTLR_EL1", HV_GIC_ICC_REG_CTLR_EL1),
            ("ICC_IGRPEN0_EL1", HV_GIC_ICC_REG_IGRPEN0_EL1),
            ("ICC_IGRPEN1_EL1", HV_GIC_ICC_REG_IGRPEN1_EL1)
        ]

        for (name, reg) in registers {

            var value: UInt64 = 0

            let result = hv_gic_get_icc_reg(
                vcpu,
                reg,
                &value
            )

            if result == HV_SUCCESS {
                print(
                    "\(name) = 0x" +
                    String(value, radix: 16)
                )
            } else {
                print(
                    "❌ \(name) read failed: \(result)"
                )
            }
        }

        print("=============================")
        print("")
    }

    func initializeCPUInterface(vcpu: hv_vcpu_t) -> Bool {

        print("")
        print("===== INITIALIZING GIC CPU INTERFACE =====")

        var result = hv_gic_set_icc_reg(
            vcpu,
            HV_GIC_ICC_REG_PMR_EL1,
            0xFF
        )

        guard result == HV_SUCCESS else {
            print("❌ ICC_PMR_EL1 failed: \(result)")
            return false
        }

        result = hv_gic_set_icc_reg(
            vcpu,
            HV_GIC_ICC_REG_IGRPEN1_EL1,
            1
        )

        guard result == HV_SUCCESS else {
            print("❌ ICC_IGRPEN1_EL1 failed: \(result)")
            return false
        }

        print("✅ ICC_PMR_EL1 = 0xFF")
        print("✅ ICC_IGRPEN1_EL1 = 1")
        print("==========================================")
        print("")

        return true
    }


    func dumpVirtualTimerPPI(vcpu: hv_vcpu_t) {

        print("")
        print("===== GIC REDISTRIBUTOR / PPI 27 =====")

        var redistributorBase: hv_ipa_t = 0

        let baseResult = hv_gic_get_redistributor_base(
            vcpu,
            &redistributorBase
        )

        if baseResult == HV_SUCCESS {
            print(
                "Redistributor base: 0x" +
                String(redistributorBase, radix: 16)
            )
        } else {
            print(
                "❌ Redistributor base read failed: \(baseResult)"
            )
        }

        let registers: [(String, hv_gic_redistributor_reg_t)] = [
            ("GICR_TYPER",
             HV_GIC_REDISTRIBUTOR_REG_GICR_TYPER),

            ("GICR_IGROUPR0",
             HV_GIC_REDISTRIBUTOR_REG_GICR_IGROUPR0),

            ("GICR_ISENABLER0",
             HV_GIC_REDISTRIBUTOR_REG_GICR_ISENABLER0),

            ("GICR_ISPENDR0",
             HV_GIC_REDISTRIBUTOR_REG_GICR_ISPENDR0),

            ("GICR_ISACTIVER0",
             HV_GIC_REDISTRIBUTOR_REG_GICR_ISACTIVER0),

            ("GICR_IPRIORITYR6",
             HV_GIC_REDISTRIBUTOR_REG_GICR_IPRIORITYR6),

            ("GICR_ICFGR1",
             HV_GIC_REDISTRIBUTOR_REG_GICR_ICFGR1)
        ]

        for (name, reg) in registers {

            var value: UInt64 = 0

            let result = hv_gic_get_redistributor_reg(
                vcpu,
                reg,
                &value
            )

            if result == HV_SUCCESS {
                print(
                    "\(name) = 0x" +
                    String(value, radix: 16)
                )
            } else {
                print(
                    "❌ \(name) read failed: \(result)"
                )
            }
        }

        print("")
        print("PPI 27 bit mask = 0x08000000")
        print("=======================================")
        print("")
    }


    func configureVirtualTimerPPI(vcpu: hv_vcpu_t) -> Bool {

        let timerBit: UInt64 = 1 << 27

        print("")
        print("===== CONFIGURING VTIMER PPI 27 =====")

        // INTID 27 -> Group 1
        var result = hv_gic_set_redistributor_reg(
            vcpu,
            HV_GIC_REDISTRIBUTOR_REG_GICR_IGROUPR0,
            timerBit
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed setting PPI 27 Group 1: \(result)")
            return false
        }

        // INTID 27 is byte 3 of IPRIORITYR6.
        // Priority = 0x80.
        result = hv_gic_set_redistributor_reg(
            vcpu,
            HV_GIC_REDISTRIBUTOR_REG_GICR_IPRIORITYR6,
            0x80000000
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed setting PPI 27 priority: \(result)")
            return false
        }

        // Enable PPI 27.
        result = hv_gic_set_redistributor_reg(
            vcpu,
            HV_GIC_REDISTRIBUTOR_REG_GICR_ISENABLER0,
            timerBit
        )

        guard result == HV_SUCCESS else {
            print("❌ Failed enabling PPI 27: \(result)")
            return false
        }

        print("✅ PPI 27 assigned to Group 1")
        print("✅ PPI 27 priority = 0x80")
        print("✅ PPI 27 enabled")
        print("======================================")
        print("")

        return true
    }

}
