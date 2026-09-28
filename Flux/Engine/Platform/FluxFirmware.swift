import Foundation
import Hypervisor
import Darwin

nonisolated final class FluxFirmware {

    let codeBase: hv_ipa_t = 0x00000000
    let varsBase: hv_ipa_t = 0x04000000

    let codeSize = 64 * 1024 * 1024
    let varsSize = 64 * 1024 * 1024

    private var codeHost: UnsafeMutableRawPointer?
    private var varsHost: UnsafeMutableRawPointer?
    private var varsFD: Int32 = -1

    private var codeMapped = false
    private var varsMapped = false

    func loadAndMap() -> Bool {

        guard let codeURL = Bundle.main.url(
            forResource: "edk2-aarch64-code",
            withExtension: "fd"
        ) else {
            print("❌ UEFI CODE not found in app bundle")
            print("   Expected: edk2-aarch64-code.fd")
            return false
        }

        guard let varsURL = Bundle.main.url(
            forResource: "edk2-aarch64-vars",
            withExtension: "fd"
        ) else {
            print("❌ UEFI VARS not found in app bundle")
            print("   Expected: edk2-aarch64-vars.fd")
            return false
        }

        let appDir = FluxVM.defaultAppDirectory()
        let persistentVarsPath = appDir + "/flux-vars.fd"
        if !FileManager.default.fileExists(atPath: persistentVarsPath) {
            do {
                try FileManager.default.copyItem(atPath: varsURL.path, toPath: persistentVarsPath)
                print("✅ Copied initial UEFI VARS to persistent path: \(persistentVarsPath)")
            } catch {
                print("⚠️ Failed to copy initial UEFI VARS: \(error)")
            }
        }
        let targetVarsPath = FileManager.default.fileExists(atPath: persistentVarsPath) ? persistentVarsPath : varsURL.path

        print("✅ UEFI resources found in app bundle")
        print("   CODE: \(codeURL.path)")
        print("   VARS: \(targetVarsPath)")

        guard loadCode(path: codeURL.path) else {
            return false
        }

        guard loadVars(path: targetVarsPath) else {
            return false
        }


        // Diagnostic: verify beginning of VARS firmware image.
        if let varsURL = Bundle.main.url(
            forResource: "edk2-aarch64-vars",
            withExtension: "fd"
        ),
        let varsData = try? Data(contentsOf: varsURL) {

            let count = min(32, varsData.count)

            let prefix = varsData.prefix(count).map {
                String(format: "%02x", $0)
            }.joined(separator: " ")

            print("===== UEFI VARS FLASH HEADER =====")
            print(prefix)
            print("==================================")
        } else {
            print("⚠️ Could not inspect UEFI VARS image")
        }

        print("✅ UEFI firmware mapped")
        print("   CODE: 0x00000000 - 0x03FFFFFF")
        print("   VARS: 0x04000000 - 0x07FFFFFF")

        return true
    }

    private func loadCode(
        path: String
    ) -> Bool {

        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: path)
        ) else {
            print("❌ Unable to load UEFI CODE")
            print("   \(path)")
            return false
        }

        guard data.count == codeSize else {
            print(
                "❌ Unexpected CODE size: \(data.count)"
            )
            return false
        }

        guard let memory = mmap(
            nil,
            codeSize,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANON,
            -1,
            0
        ), memory != MAP_FAILED else {
            print("❌ CODE mmap failed")
            return false
        }

        data.withUnsafeBytes { bytes in
            memcpy(
                memory,
                bytes.baseAddress!,
                codeSize
            )
        }

        let flags =
            hv_memory_flags_t(HV_MEMORY_READ) |
            hv_memory_flags_t(HV_MEMORY_EXEC)

        let result = hv_vm_map(
            memory,
            codeBase,
            codeSize,
            flags
        )

        guard result == HV_SUCCESS else {
            print(
                "❌ UEFI CODE hv_vm_map failed: \(result)"
            )
            munmap(memory, codeSize)
            return false
        }

        codeHost = memory
        codeMapped = true

        print("✅ UEFI CODE loaded")
        print("   Size: 64 MB")
        print("   IPA: 0x00000000")

        return true
    }

    private func loadVars(
        path: String
    ) -> Bool {

        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            print("❌ Unable to open UEFI VARS: \(path)")
            return false
        }
        varsFD = fd

        let currentSize = lseek(fd, 0, SEEK_END)
        if currentSize < off_t(varsSize) {
            ftruncate(fd, off_t(varsSize))
        }
        _ = lseek(fd, 0, SEEK_SET)

        guard let memory = mmap(
            nil,
            varsSize,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            0
        ), memory != MAP_FAILED else {
            print("❌ VARS mmap MAP_SHARED failed")
            close(varsFD)
            varsFD = -1
            return false
        }

        // Keep VARS directly readable by the guest for performance,
        // but remove guest write permission so NOR program/erase
        // operations trap to the VMM.
        let flags =
            hv_memory_flags_t(HV_MEMORY_READ)

        let result = hv_vm_map(
            memory,
            varsBase,
            varsSize,
            flags
        )

        guard result == HV_SUCCESS else {
            print(
                "❌ UEFI VARS hv_vm_map failed: \(result)"
            )
            munmap(memory, varsSize)
            close(varsFD)
            varsFD = -1
            return false
        }

        varsHost = memory
        varsMapped = true

        print("✅ UEFI VARS loaded & mapped (Persistent: \(path))")
        print("   Size: 64 MB")
        print("   IPA: 0x04000000")

        return true
    }

    func setVarsReadMapped(_ enabled: Bool) -> Bool {

        guard let varsHost else {
            print("❌ VARS host memory missing")
            return false
        }

        if enabled {

            if varsMapped {
                return true
            }

            let flags =
                hv_memory_flags_t(HV_MEMORY_READ)

            let result = hv_vm_map(
                varsHost,
                varsBase,
                varsSize,
                flags
            )

            guard result == HV_SUCCESS else {
                print(
                    "❌ VARS remap failed: \(result)"
                )
                return false
            }

            varsMapped = true

            if FluxExitHandler.verbose {
                print("✅ NOR direct-read mapping enabled")
            }
            return true

        } else {

            if !varsMapped {
                return true
            }

            let result = hv_vm_unmap(
                varsBase,
                varsSize
            )

            guard result == HV_SUCCESS else {
                print(
                    "❌ VARS unmap failed: \(result)"
                )
                return false
            }

            varsMapped = false

            if FluxExitHandler.verbose {
                print("✅ NOR MMIO trap mode enabled")
            }
            return true
        }
    }

    func containsVars(_ ipa: UInt64) -> Bool {
        ipa >= UInt64(varsBase) &&
        ipa < UInt64(varsBase) + UInt64(varsSize)
    }

    func readVarsByte(at ipa: UInt64) -> UInt8? {

        guard containsVars(ipa),
              let varsHost else {
            return nil
        }

        let offset =
            Int(ipa - UInt64(varsBase))

        return varsHost
            .advanced(by: offset)
            .assumingMemoryBound(to: UInt8.self)
            .pointee
    }

    func writeVarsByte(
        at ipa: UInt64,
        value: UInt8
    ) -> Bool {

        guard containsVars(ipa),
              let varsHost else {
            return false
        }

        let offset =
            Int(ipa - UInt64(varsBase))

        varsHost
            .advanced(by: offset)
            .assumingMemoryBound(to: UInt8.self)
            .pointee = value

        return true
    }

    func programVars(
        at ipa: UInt64,
        value: UInt64,
        size: Int
    ) -> Bool {

        guard containsVars(ipa),
              let varsHost,
              size == 1 ||
              size == 2 ||
              size == 4 ||
              size == 8 else {
            return false
        }

        let offset =
            Int(ipa - UInt64(varsBase))

        guard offset >= 0,
              offset + size <= varsSize else {
            return false
        }

        let destination =
            varsHost.advanced(by: offset)
                .assumingMemoryBound(to: UInt8.self)

        // NOR programming can only change bits 1 -> 0.
        // Erase is required to restore bits back to 1.
        for i in 0..<size {

            let incoming =
                UInt8(
                    truncatingIfNeeded:
                        value >> UInt64(i * 8)
                )

            destination[i] &= incoming
        }

        msync(varsHost.advanced(by: offset), size, MS_ASYNC)
        return true
    }

    func eraseVarsBlock(
        containing ipa: UInt64,
        blockSize: Int
    ) -> Bool {

        guard containsVars(ipa),
              let varsHost,
              blockSize > 0 else {
            return false
        }

        let offset =
            Int(ipa - UInt64(varsBase))

        let blockStart =
            (offset / blockSize) * blockSize

        guard blockStart + blockSize <= varsSize else {
            return false
        }

        memset(
            varsHost.advanced(by: blockStart),
            0xFF,
            blockSize
        )

        msync(varsHost.advanced(by: blockStart), blockSize, MS_ASYNC)
        return true
    }

    func cleanup() {

        if codeMapped {
            _ = hv_vm_unmap(
                codeBase,
                codeSize
            )
            codeMapped = false
        }

        if varsMapped {
            _ = hv_vm_unmap(
                varsBase,
                varsSize
            )
            varsMapped = false
        }

        if let codeHost {
            munmap(codeHost, codeSize)
            self.codeHost = nil
        }

        if let varsHost {
            msync(varsHost, varsSize, MS_SYNC)
            munmap(varsHost, varsSize)
            self.varsHost = nil
        }

        if varsFD >= 0 {
            close(varsFD)
            varsFD = -1
        }

        print("✅ UEFI firmware unmapped")
    }
}
