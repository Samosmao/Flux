import Foundation
import Hypervisor
import Darwin

nonisolated final class FluxMemory {

    let size: Int
    let guestBase: hv_ipa_t

    private(set) var hostAddress: UnsafeMutableRawPointer?
    private(set) var isMapped = false

    init(
        size: Int = 4096 * 1024 * 1024,
        guestBase: hv_ipa_t = 0x40000000
    ) {
        self.size = size
        self.guestBase = guestBase
    }

    func allocate() -> Bool {

        guard hostAddress == nil else {
            return true
        }

        guard let memory = mmap(
            nil,
            size,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANON,
            -1,
            0
        ), memory != MAP_FAILED else {
            print("❌ Guest RAM allocation failed")
            return false
        }

        hostAddress = memory
        memset(memory, 0, min(size, 16 * 1024 * 1024))

        print("✅ \(size / 1024 / 1024) MB guest RAM allocated")
        return true
    }

    /// Converts a guest physical address to a host virtual memory pointer.
    func hostPointer(forGuestAddress guestAddress: UInt64) -> UnsafeMutableRawPointer? {
        guard let hostAddress else { return nil }
        guard guestAddress >= guestBase && guestAddress < guestBase + UInt64(size) else {
            return nil
        }
        return hostAddress.advanced(by: Int(guestAddress - guestBase))
    }

    func loadDeviceTree() -> Bool {

        guard let hostAddress else {
            print("❌ Guest RAM not allocated")
            return false
        }

        guard let dtbURL = Bundle.main.url(
            forResource: "flux",
            withExtension: "dtb"
        ) else {
            print("❌ flux.dtb not found in app bundle")
            return false
        }

        guard let data = try? Data(contentsOf: dtbURL) else {
            print("❌ Unable to read flux.dtb")
            return false
        }

        guard data.count < size else {
            print("❌ DTB larger than guest RAM")
            return false
        }

        data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                memcpy(
                    hostAddress,
                    base,
                    data.count
                )
            }
        }

        let magic = hostAddress
            .assumingMemoryBound(to: UInt32.self)
            .pointee
            .bigEndian

        guard magic == 0xD00DFEED else {
            print(
                "❌ Invalid DTB magic: 0x" +
                String(magic, radix: 16)
            )
            return false
        }

        print("✅ Device Tree loaded")
        print("   IPA: 0x40000000")
        print("   Size: \(data.count) bytes")
        print("   Magic: 0xd00dfeed")

        return true
    }

    func loadTestProgram() -> Bool {

        guard let hostAddress else {
            print("❌ Guest RAM not allocated")
            return false
        }

        // Test #7 — MMIO UART
        //
        // UART base = 0x09000000
        //
        // Guest writes:
        //   F
        //   L
        //   U
        //   X
        //   \n
        //
        // Each STRB targets unmapped MMIO and exits to Flux.
        // Host emulates UART write and advances PC.
        // HVC service 104 means all UART writes completed.

        let instructions: [UInt32] = [

            0xD2A12000, // mov x0, #0x09000000

            0x528008C1, // mov w1, #'F'
            0x39000001, // strb w1, [x0]

            0x52800981, // mov w1, #'L'
            0x39000001, // strb w1, [x0]

            0x52800AA1, // mov w1, #'U'
            0x39000001, // strb w1, [x0]

            0x52800B01, // mov w1, #'X'
            0x39000001, // strb w1, [x0]

            0x52800141, // mov w1, #10
            0x39000001, // strb w1, [x0]

            0xD2800D00, // mov x0, #104
            0xD4000002, // hvc #0

            0x14000000  // b .
        ]

        let code = hostAddress.bindMemory(
            to: UInt32.self,
            capacity: instructions.count
        )

        for (index, instruction) in instructions.enumerated() {
            code[index] = instruction
        }

        print("✅ Test #7 MMIO UART guest program loaded")
        print("   UART base: 0x09000000")
        print("   Expected output: FLUX")

        return true
    }

    func map() -> Bool {

        guard let hostAddress else {
            print("❌ Guest RAM not allocated")
            return false
        }

        let flags: hv_memory_flags_t =
            hv_memory_flags_t(HV_MEMORY_READ) |
            hv_memory_flags_t(HV_MEMORY_WRITE) |
            hv_memory_flags_t(HV_MEMORY_EXEC)

        let result = hv_vm_map(
            hostAddress,
            guestBase,
            size,
            flags
        )

        guard result == HV_SUCCESS else {
            print("❌ hv_vm_map failed: \(result)")
            return false
        }

        isMapped = true

        print("✅ Guest RAM mapped")
        print("   IPA: 0x\(String(guestBase, radix: 16))")

        return true
    }

    func cleanup() {

        if isMapped {

            let result = hv_vm_unmap(
                guestBase,
                size
            )

            if result == HV_SUCCESS {
                print("✅ Guest RAM unmapped")
            } else {
                print("⚠️ hv_vm_unmap: \(result)")
            }

            isMapped = false
        }

        if let hostAddress {
            munmap(hostAddress, size)
            self.hostAddress = nil
        }
    }
}
