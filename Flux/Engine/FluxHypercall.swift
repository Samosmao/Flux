import Foundation
import Hypervisor

nonisolated final class FluxHypercall {

    private(set) var console = ""

    func handle(cpu: FluxVCPU) -> Bool {

        let service = cpu.register(HV_REG_X0)
        let argument = cpu.register(HV_REG_X1)
        let pc = cpu.register(HV_REG_PC)

        print(
            "HVC service=\(service) " +
            "PC=0x\(String(pc, radix: 16))"
        )

        switch service {

        // Service 1 = Guest console output
        case 1:

            guard let scalar =
                UnicodeScalar(Int(argument & 0xFF))
            else {
                print("❌ Invalid console character")
                return false
            }

            let character = String(Character(scalar))

            console += character

            print("Flux Console ← '\(character)'")

            return true

        // Service 0 = Guest shutdown
        case 0:

            print("🛑 Guest requested shutdown")

            return false

        default:

            print("⚠️ Unknown Flux hypercall: \(service)")

            return false
        }
    }
}
