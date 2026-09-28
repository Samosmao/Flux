import Foundation

enum FluxInstallerInjector {

    static func injectUnattendXML(
        installerDiskPath: String,
        xmlContent: String
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: installerDiskPath) else {
            print("❌ [FluxInstallerInjector] Installer disk not found: \(installerDiskPath)")
            return false
        }

        print("🔧 [FluxInstallerInjector] Attaching installer disk to inject autounattend.xml...")
        let attachProcess = Process()
        attachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attachProcess.arguments = [
            "attach",
            "-imagekey", "diskimage-class=CRawDiskImage",
            "-nomount",
            installerDiskPath
        ]
        let attachPipe = Pipe()
        attachProcess.standardOutput = attachPipe
        attachProcess.standardError = attachPipe

        do {
            try attachProcess.run()
            attachProcess.waitUntilExit()
        } catch {
            print("❌ [FluxInstallerInjector] Failed to run hdiutil attach: \(error)")
            return false
        }

        let attachData = attachPipe.fileHandleForReading.readDataToEndOfFile()
        guard let attachOutput = String(data: attachData, encoding: .utf8) else {
            print("❌ [FluxInstallerInjector] Failed to decode hdiutil output")
            return false
        }

        var topDiskNode: String?
        var dataPartNode: String?

        for line in attachOutput.components(separatedBy: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = parts.first else { continue }
            let devNode = String(first)
            if topDiskNode == nil && devNode.hasPrefix("/dev/disk") && !devNode.dropFirst(9).contains("s") {
                topDiskNode = devNode
            }
            if line.contains("Microsoft Basic Data") || line.contains("Windows_FAT_32") || line.contains("DOS_FAT_32") {
                dataPartNode = devNode
            }
        }

        if topDiskNode == nil {
            for line in attachOutput.components(separatedBy: "\n") {
                if let first = line.split(whereSeparator: { $0.isWhitespace }).first, first.hasPrefix("/dev/disk") {
                    topDiskNode = String(first)
                    break
                }
            }
        }

        guard let topDisk = topDiskNode, let dataPart = dataPartNode else {
            print("❌ [FluxInstallerInjector] Could not find data partition in attached disk: \(attachOutput)")
            if let topDisk = topDiskNode {
                _ = detachDisk(topDisk)
            }
            return false
        }

        let mntPath = "/tmp/flux_installer_mnt"
        try? FileManager.default.createDirectory(atPath: mntPath, withIntermediateDirectories: true)

        print("🔧 [FluxInstallerInjector] Mounting \(dataPart) to \(mntPath)...")
        let mountProcess = Process()
        mountProcess.executableURL = URL(fileURLWithPath: "/sbin/mount")
        mountProcess.arguments = ["-t", "msdos", dataPart, mntPath]
        try? mountProcess.run()
        mountProcess.waitUntilExit()

        guard mountProcess.terminationStatus == 0 else {
            print("❌ [FluxInstallerInjector] Mount failed with code \(mountProcess.terminationStatus)")
            _ = detachDisk(topDisk)
            return false
        }

        let targetXMLPath = mntPath + "/autounattend.xml"
        do {
            try xmlContent.write(toFile: targetXMLPath, atomically: true, encoding: .utf8)
            print("✅ [FluxInstallerInjector] Successfully wrote autounattend.xml (\(xmlContent.count) bytes) to installer media root")
        } catch {
            print("❌ [FluxInstallerInjector] Failed to write autounattend.xml: \(error)")
        }

        // Note: Hardware requirements (CPU cores) are patched directly in hwreqchk.dll,
        // and TPM/SecureBoot checks are bypassed via LabConfig in autounattend.xml.

        // Unmount
        let umountProcess = Process()
        umountProcess.executableURL = URL(fileURLWithPath: "/sbin/umount")
        umountProcess.arguments = [mntPath]
        try? umountProcess.run()
        umountProcess.waitUntilExit()

        // Detach
        let detached = detachDisk(topDisk)
        print("✅ [FluxInstallerInjector] Injection completed, installer disk detached (success=\(detached))")
        return true
    }

    private static func detachDisk(_ devNode: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["detach", devNode]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
