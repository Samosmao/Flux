import Foundation
import Security
import Hypervisor

nonisolated final class FluxTRNG {

    private let versionFID: UInt64 = 0x84000050
    private let featuresFID: UInt64 = 0x84000051
    private let uuidFID: UInt64 = 0x84000052
    private let rnd64FID: UInt64 = 0xC4000053

    private let success: UInt64 = 0
    private let notSupported =
        UInt64(bitPattern: Int64(-1))
    private let invalidParameter =
        UInt64(bitPattern: Int64(-2))
    private let noEntropy =
        UInt64(bitPattern: Int64(-3))

    enum Result {
        case handled
        case notHandled
    }

    func handle(cpu: FluxVCPU) -> Result {

        let fid = cpu.register(HV_REG_X0)

        switch fid {

        case versionFID:
            // TRNG ABI 1.0
            _ = cpu.setRegister(
                HV_REG_X0,
                value: 0x00010000
            )

            print("TRNG_VERSION -> 1.0")
            return .handled

        case featuresFID:
            let requested =
                cpu.register(HV_REG_X1)

            let supported =
                requested == versionFID ||
                requested == featuresFID ||
                requested == uuidFID ||
                requested == rnd64FID

            _ = cpu.setRegister(
                HV_REG_X0,
                value: supported
                    ? success
                    : notSupported
            )

            print(
                "TRNG_FEATURES 0x" +
                String(requested, radix: 16) +
                " -> " +
                (supported
                    ? "supported"
                    : "not supported")
            )

            return .handled

        case uuidFID:
            // Stable Flux TRNG backend UUID.
            _ = cpu.setRegister(
                HV_REG_X0,
                value: 0x46584C55
            )
            _ = cpu.setRegister(
                HV_REG_X1,
                value: 0x54524E47
            )
            _ = cpu.setRegister(
                HV_REG_X2,
                value: 0x00000001
            )
            _ = cpu.setRegister(
                HV_REG_X3,
                value: 0x00000000
            )

            print("TRNG_GET_UUID")
            return .handled

        case rnd64FID:
            let requestedBits =
                cpu.register(HV_REG_X1)

            guard requestedBits > 0,
                  requestedBits <= 192 else {

                _ = cpu.setRegister(
                    HV_REG_X0,
                    value: invalidParameter
                )

                print(
                    "TRNG_RND invalid bits: \(requestedBits)"
                )

                return .handled
            }

            var words = [UInt64](repeating: 0, count: 3)

            let status = words.withUnsafeMutableBytes {
                SecRandomCopyBytes(
                    kSecRandomDefault,
                    $0.count,
                    $0.baseAddress!
                )
            }

            guard status == errSecSuccess else {

                _ = cpu.setRegister(
                    HV_REG_X0,
                    value: noEntropy
                )

                print("TRNG_RND entropy failure")
                return .handled
            }

            _ = cpu.setRegister(
                HV_REG_X0,
                value: success
            )

            _ = cpu.setRegister(
                HV_REG_X1,
                value: words[0]
            )

            _ = cpu.setRegister(
                HV_REG_X2,
                value: words[1]
            )

            _ = cpu.setRegister(
                HV_REG_X3,
                value: words[2]
            )

            print(
                "TRNG_RND -> \(requestedBits) bits"
            )

            return .handled

        default:
            return .notHandled
        }
    }
}
