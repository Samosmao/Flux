import Foundation
import CoreGraphics
import AppKit
import CryptoKit

/// Thread-safe USB HID Absolute Pointer state tracker and report queue.
/// Services USB Endpoint 0x82 / xHCI DCI 5 on Slot 1.
///
/// Report format (6 bytes):
/// - Byte 0: Buttons (Bit 0: Left, Bit 1: Right, Bit 2: Middle)
/// - Bytes 1..2: Absolute X (UInt16 Little-Endian, 0...32767)
/// - Bytes 3..4: Absolute Y (UInt16 Little-Endian, 0...32767)
/// - Byte 5: Vertical Wheel (Int8 Little-Endian, -127...+127)
nonisolated final class FluxHIDPointer {
    static let shared = FluxHIDPointer()

    private let lock = NSLock()
    private var buttons: UInt8 = 0
    private var currentX: UInt16 = 16384
    private var currentY: UInt16 = 16384
    private var reportQueue: [[UInt8]] = []

    private init() {}

    // MARK: - State Updates

    /// Updates pointer position and enqueues a report.
    /// Coalesces consecutive motion-only events so pending queues do not lag.
    func updatePosition(x: UInt16, y: UInt16) {
        var reportBytes: [UInt8] = []
        lock.lock()
        currentX = x
        currentY = y
        reportBytes = enqueueReportLocked(coalesceMotion: true, wheel: 0)
        lock.unlock()

        FluxXHCI.notifyPointerEvent()
    }

    /// Updates mouse button mask and enqueues a report.
    /// Button transitions are NEVER coalesced away.
    func updateButtons(_ newButtons: UInt8) {
        var reportBytes: [UInt8] = []
        var changed = false
        lock.lock()
        if (newButtons & 0x07) != buttons {
            buttons = newButtons & 0x07
            reportBytes = enqueueReportLocked(coalesceMotion: false, wheel: 0)
            changed = true
        }
        lock.unlock()

        if changed {
            print("🖱️ [HID-POINTER] buttons=0x\(String(format: "%02x", buttons)) (L=\(buttons & 1 != 0 ? 1 : 0) R=\(buttons & 2 != 0 ? 1 : 0) M=\(buttons & 4 != 0 ? 1 : 0)) report=[\(reportBytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            FluxXHCI.notifyPointerEvent()
        }
    }

    /// Updates both position and button state in a single call.
    func updateState(x: UInt16, y: UInt16, buttons newButtons: UInt8) {
        var reportBytes: [UInt8] = []
        lock.lock()
        let buttonChanged = (newButtons & 0x07) != buttons
        buttons = newButtons & 0x07
        currentX = x
        currentY = y
        reportBytes = enqueueReportLocked(coalesceMotion: !buttonChanged, wheel: 0)
        lock.unlock()

        FluxXHCI.notifyPointerEvent()
    }

    /// Enqueues a relative vertical scroll wheel event.
    func updateWheel(delta: Int8) {
        guard delta != 0 else { return }
        var reportBytes: [UInt8] = []
        lock.lock()
        reportBytes = enqueueReportLocked(coalesceMotion: false, wheel: delta)
        lock.unlock()

        print("🖱️ [HID-POINTER] wheel delta=\(delta) report=[\(reportBytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
        FluxXHCI.notifyPointerEvent()
    }

    /// Safety release for all mouse buttons on window focus loss.
    func resetButtons() {
        var reportBytes: [UInt8] = []
        var changed = false
        lock.lock()
        if buttons != 0 {
            buttons = 0
            reportBytes = enqueueReportLocked(coalesceMotion: false, wheel: 0)
            changed = true
        }
        lock.unlock()

        if changed {
            print("🖱️ [HID-POINTER] resetButtons: released all buttons report=[\(reportBytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            FluxXHCI.notifyPointerEvent()
        }
    }

    // MARK: - Queue Management

    private func makeReportBytes(b: UInt8, x: UInt16, y: UInt16, wheel: Int8) -> [UInt8] {
        [
            b & 0x07,
            UInt8(truncatingIfNeeded: x),
            UInt8(truncatingIfNeeded: x >> 8),
            UInt8(truncatingIfNeeded: y),
            UInt8(truncatingIfNeeded: y >> 8),
            UInt8(bitPattern: wheel)
        ]
    }

    private func enqueueReportLocked(coalesceMotion: Bool, wheel: Int8) -> [UInt8] {
        let rep = makeReportBytes(b: buttons, x: currentX, y: currentY, wheel: wheel)
        // Only coalesce pure motion events (no wheel delta, same buttons)
        if coalesceMotion, wheel == 0, !reportQueue.isEmpty {
            let lastIndex = reportQueue.count - 1
            if reportQueue[lastIndex][0] == (buttons & 0x07), reportQueue[lastIndex][5] == 0 {
                // Same buttons and no pending wheel delta: coalesce motion in-place
                reportQueue[lastIndex] = rep
                return rep
            }
        }
        // Cap maximum queue length to prevent unbounded growth if guest stops servicing
        if reportQueue.count >= 32 {
            if let dropIdx = reportQueue.indices.first(where: { idx in
                idx > 0 && reportQueue[idx][0] == reportQueue[idx - 1][0] && reportQueue[idx][5] == 0
            }) {
                reportQueue.remove(at: dropIdx)
            }
        }
        reportQueue.append(rep)
        return rep
    }

    func peekReport() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return reportQueue.first
    }

    func popReport() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard !reportQueue.isEmpty else { return nil }
        return reportQueue.removeFirst()
    }

    var queueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reportQueue.count
    }

    // MARK: - Coordinate Mapping

    /// Maps Mac display view coordinates (with top-left as origin (0, 0)) to:
    /// - `hidX`, `hidY`: normalized HID coordinates (0...32767)
    /// - `guestX`, `guestY`: guest visible framebuffer pixel coordinates
    ///
    /// Correctly accounts for letterboxing, pillarboxing, aspect-ratio scaling,
    /// and guest framebuffer dimensions.
    static func mapPointToHID(
        viewPoint: CGPoint,
        viewSize: CGSize,
        fbWidth: Int,
        fbHeight: Int
    ) -> (hidX: UInt16, hidY: UInt16, guestX: Int, guestY: Int)? {
        guard fbWidth > 0, fbHeight > 0, viewSize.width > 0, viewSize.height > 0 else {
            return nil
        }

        let fbAspect = CGFloat(fbWidth) / CGFloat(fbHeight)
        let viewAspect = viewSize.width / viewSize.height

        let renderWidth: CGFloat
        let renderHeight: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat

        if viewAspect > fbAspect {
            // View is wider than guest framebuffer: pillarboxed (black bars left and right)
            renderHeight = viewSize.height
            renderWidth = viewSize.height * fbAspect
            offsetX = (viewSize.width - renderWidth) / 2.0
            offsetY = 0
        } else {
            // View is taller than guest framebuffer: letterboxed (black bars top and bottom)
            renderWidth = viewSize.width
            renderHeight = viewSize.width / fbAspect
            offsetX = 0
            offsetY = (viewSize.height - renderHeight) / 2.0
        }

        // Clamp view point to the active guest image rectangle
        let clampedX = min(max(viewPoint.x - offsetX, 0), renderWidth)
        let clampedY = min(max(viewPoint.y - offsetY, 0), renderHeight)

        let normalizedX = renderWidth > 0 ? (clampedX / renderWidth) : 0
        let normalizedY = renderHeight > 0 ? (clampedY / renderHeight) : 0

        let hidX = UInt16(clamping: Int(round(normalizedX * 32767.0)))
        let hidY = UInt16(clamping: Int(round(normalizedY * 32767.0)))

        let guestX = Int(round(normalizedX * CGFloat(fbWidth - 1)))
        let guestY = Int(round(normalizedY * CGFloat(fbHeight - 1)))

        return (hidX, hidY, guestX, guestY)
    }

    // MARK: - Automated Live Test Runner

    private var testStarted = false
    private let probeStatusLock = NSLock()

    /// Test-only durable phase breadcrumbs for the one-command probe.  The
    /// status file is intentionally separate from VM diagnostics so the host
    /// orchestrator can wait for completion without using framebuffer state.
    private func startProbeStatusLog() {
        let path = FluxVM.defaultAppDirectory() + "/probe-run-status.log"
        let header = "=== Flux existing-probe run \(ISO8601DateFormatter().string(from: Date())) ===\n"
        probeStatusLock.lock()
        defer { probeStatusLock.unlock() }
        try? header.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func writeProbeStatus(_ marker: String) {
        let path = FluxVM.defaultAppDirectory() + "/probe-run-status.log"
        let line = marker + "\n"
        print("[EXISTING-PROBE] \(marker)")
        probeStatusLock.lock()
        defer { probeStatusLock.unlock() }
        guard let data = line.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.synchronizeFile()
    }

    func notifyEP5Armed() {
        let isPointerTest = ProcessInfo.processInfo.environment["FLUX_TEST_HID_POINTER"] == "1"
        let isResoTest = ProcessInfo.processInfo.environment["FLUX_TEST_RESOLUTION"] == "1"
        let isFastProbeDelivery = ProcessInfo.processInfo.environment["FLUX_FAST_PROBE_DELIVERY"] == "1"
        let isContinuationProbe = ProcessInfo.processInfo.environment["FLUX_CONTINUE_PROBE"] == "1"
        let isPayloadAudit = ProcessInfo.processInfo.environment["FLUX_TEST_PAYLOAD_AUDIT"] == "1"
        let isExistingProbeWinR = ProcessInfo.processInfo.environment["FLUX_RUN_EXISTING_PROBE"] == "1"
        let isGuestProbeUpdate = ProcessInfo.processInfo.environment["FLUX_UPDATE_GUEST_PROBE"] == "1"
        let isEncodedCommandTest = ProcessInfo.processInfo.environment["FLUX_TEST_ENCODED_COMMAND"] == "1"
        let isDisplayStackDiagnostic = ProcessInfo.processInfo.environment["FLUX_DISPLAY_STACK_DIAG"] == "1"
        guard isPointerTest || isResoTest || isFastProbeDelivery || isContinuationProbe || isPayloadAudit || isExistingProbeWinR || isGuestProbeUpdate || isEncodedCommandTest || isDisplayStackDiagnostic else { return }
        lock.lock()
        if testStarted {
            lock.unlock()
            return
        }
        testStarted = true
        lock.unlock()

        if isExistingProbeWinR || isGuestProbeUpdate || isEncodedCommandTest || isDisplayStackDiagnostic {
            startProbeStatusLog()
            writeProbeStatus("PROBE_TEST_START")
            writeProbeStatus("DESKTOP_READY")
            writeProbeStatus("SETTLE_75_START")
        }

        // EP5 becomes armed during the Windows logon sequence, before the
        // interactive shell is necessarily ready.  The payload audit is a
        // desktop-only test, so leave a conservative settling window before
        // injecting its first isolated key.  Other validation modes retain
        // their existing timing.
        let testDelay: TimeInterval
        if isExistingProbeWinR || isGuestProbeUpdate || isEncodedCommandTest || isDisplayStackDiagnostic {
            // This is a one-command test path.  EP5 is armed before the shell
            // is necessarily ready, so retain the proven 75-second settle.
            testDelay = 75.0
        } else {
            testDelay = (isPayloadAudit || isResoTest || isFastProbeDelivery || isContinuationProbe) ? 95.0 : 3.0
        }

        if isResoTest {
            // In case Windows booted into WinRE due to prior abnormal termination,
            // send Return to select "Continue: Exit and continue Windows".
            DispatchQueue.global().asyncAfter(deadline: .now() + 10.0) {
                FluxHIDKeyboard.shared.handleKeyDown(keyCode: 0x24, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.1)
                FluxHIDKeyboard.shared.handleKeyUp(keyCode: 0x24)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 18.0) {
                FluxHIDKeyboard.shared.handleKeyDown(keyCode: 0x24, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.1)
                FluxHIDKeyboard.shared.handleKeyUp(keyCode: 0x24)
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + testDelay) { [weak self] in
            guard let self else { return }
            if isDisplayStackDiagnostic {
                self.writeProbeStatus("SETTLE_75_DONE")
                self.runDisplayStackDiagnostic()
            } else if isEncodedCommandTest {
                self.writeProbeStatus("SETTLE_75_DONE")
                self.runMinimalEncodedCommandTest()
            } else if isGuestProbeUpdate {
                self.writeProbeStatus("SETTLE_75_DONE")
                self.runGuestProbeUpdateTest()
            } else if isExistingProbeWinR {
                self.writeProbeStatus("SETTLE_75_DONE")
                self.runExistingProbeWinRTest()
            } else if isResoTest || isFastProbeDelivery || isContinuationProbe {
                self.runResolutionValidationTest()
            } else if isPayloadAudit {
                self.runPayloadAuditWinRTest()
            } else {
                self.runLiveValidationTest()
            }
        }
    }

    /// Runs the already-verified probe exactly once through the normal Win+R
    /// path.  The explicit delay belongs only to this test flow; ordinary HID
    /// keyboard input and mappings remain unchanged.
    private func runExistingProbeWinRTest() {
        let command = "cmd /c powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\Public\\flux_probe.ps1 > C:\\Users\\Public\\flux_probe_exec.log 2>&1"
        let testOnlyCommandCharacterDelay: TimeInterval = 0.05
        let evidenceDirectory = FluxVM.defaultAppDirectory()

        print("[EXISTING-PROBE] WINR_ONCE command=\(command)")
        print("[EXISTING-PROBE] COMMAND_CHARACTER_DELAY=\(testOnlyCommandCharacterDelay)s")
        print("[EXISTING-PROBE] ONE_ENTER_ONLY=YES")
        writeProbeStatus("WINR_SUBMIT_START")
        FluxHIDKeyboard.shared.sendWinRForProbeEvidence(
            command: command,
            charDelay: testOnlyCommandCharacterDelay
        ) { [weak self] in
            FluxVM.captureCurrentScreenshot(path: evidenceDirectory + "/probe-before-enter.bmp")
            self?.writeProbeStatus("PROBE_BEFORE_ENTER_CAPTURED")
        }
        writeProbeStatus("WINR_SUBMIT_DONE")

        Thread.sleep(forTimeInterval: 2.0)
        FluxVM.captureCurrentScreenshot(path: evidenceDirectory + "/probe-after-enter-2s.bmp")
        writeProbeStatus("PROBE_AFTER_ENTER_2S_CAPTURED")
        Thread.sleep(forTimeInterval: 6.0)
        FluxVM.captureCurrentScreenshot(path: evidenceDirectory + "/probe-after-enter-8s.bmp")
        writeProbeStatus("PROBE_AFTER_ENTER_8S_CAPTURED")

        // Allow only this already-submitted enumeration command to complete.
        // Completion remains established by the guest output file after shutdown.
        writeProbeStatus("POST_WAIT_45_START")
        Thread.sleep(forTimeInterval: 45.0)
        writeProbeStatus("POST_WAIT_45_DONE")
        writeProbeStatus("PROBE_TEST_COMPLETE")
    }

    /// Test-only, one-time in-place guest update for the three confirmed
    /// PowerShell interpolation fixes.  It does not send Base64 or execute the
    /// probe; the corrected file is verified from the stopped disk before a
    /// separate single-command execution run is allowed.
    private func runGuestProbeUpdateTest() {
        let patchScript = #"""
$p='C:\Users\Public\flux_probe.ps1'
$s=[IO.File]::ReadAllText($p).Replace('Controller #$vcCount:','Controller #${vcCount}:').Replace('Monitor #$mCount:','Monitor #${mCount}:').Replace('Device #$devIdx:','Device #${devIdx}:').TrimEnd([char[]]"`r`n")+"`n"
[IO.File]::WriteAllText($p,$s,[Text.UTF8Encoding]::new($false))
"""#
        let encoded = patchScript.data(using: .utf8)!.base64EncodedString()
        let chunks = stride(from: 0, to: encoded.count, by: 96).map {
            String(encoded.dropFirst($0).prefix(96))
        }
        let commands = chunks.enumerated().map { index, chunk in
            "cmd /c echo \(chunk)\(index == 0 ? ">" : ">>")%TEMP%\\fxp928.b64"
        }
        let decodeCommand = "cmd /c certutil -f -decode %TEMP%\\fxp928.b64 %TEMP%\\fxp928.ps1"
        let executeCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File %TEMP%\\fxp928.ps1"
        guard (commands + [decodeCommand, executeCommand]).allSatisfy({ $0.count <= 174 }) else {
            fatalError("Patch helper command exceeded safe Win+R length")
        }

        writeProbeStatus("GUEST_PROBE_UPDATE_START")
        writeProbeStatus("HELPER_BYTES=\(patchScript.utf8.count)")
        writeProbeStatus("HELPER_BASE64_LENGTH=\(encoded.count)")
        writeProbeStatus("HELPER_CHUNK_COUNT=\(chunks.count)")
        writeProbeStatus("HELPER_MAX_COMMAND_LENGTH=\((commands + [decodeCommand, executeCommand]).map(\.count).max() ?? 0)")
        for command in commands {
            FluxHIDKeyboard.shared.sendWinR(command: command, charDelay: 0.05)
            Thread.sleep(forTimeInterval: 2.0)
        }
        FluxHIDKeyboard.shared.sendWinR(command: decodeCommand, charDelay: 0.05)
        Thread.sleep(forTimeInterval: 4.0)
        FluxHIDKeyboard.shared.sendWinR(command: executeCommand, charDelay: 0.05)
        writeProbeStatus("GUEST_PROBE_UPDATE_SUBMITTED")
        Thread.sleep(forTimeInterval: 20.0)
        writeProbeStatus("GUEST_PROBE_UPDATE_COMPLETE")
    }

    /// Isolated transport diagnostic: proves only whether a minimal Windows
    /// PowerShell EncodedCommand survives the established Win+R input path.
    private func runMinimalEncodedCommandTest() {
        let script = "Set-Content C:\\Users\\Public\\fxe928c.txt OK"
        let payload = script.data(using: .utf16LittleEndian)!.base64EncodedString()
        let command = "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand \(payload)"
        let commandHash = SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = FluxVM.defaultAppDirectory()

        writeProbeStatus("ENCODED_SCRIPT=\(script)")
        writeProbeStatus("ENCODED_PAYLOAD_LENGTH=\(payload.count)")
        writeProbeStatus("ENCODED_COMMAND_LENGTH=\(command.count)")
        writeProbeStatus("ENCODED_COMMAND_SHA256=\(commandHash)")
        writeProbeStatus("WINR_SUBMIT_START")
        FluxHIDKeyboard.shared.sendWinRForProbeEvidence(command: command, charDelay: 0.05) { [weak self] in
            FluxVM.captureCurrentScreenshot(path: directory + "/probe-before-enter.bmp")
            self?.writeProbeStatus("PROBE_BEFORE_ENTER_CAPTURED")
        }
        writeProbeStatus("WINR_SUBMIT_DONE")
        Thread.sleep(forTimeInterval: 2.0)
        FluxVM.captureCurrentScreenshot(path: directory + "/probe-after-enter-2s.bmp")
        writeProbeStatus("PROBE_AFTER_ENTER_2S_CAPTURED")
        Thread.sleep(forTimeInterval: 6.0)
        FluxVM.captureCurrentScreenshot(path: directory + "/probe-after-enter-8s.bmp")
        writeProbeStatus("PROBE_AFTER_ENTER_8S_CAPTURED")
        writeProbeStatus("POST_WAIT_45_START")
        Thread.sleep(forTimeInterval: 45.0)
        writeProbeStatus("POST_WAIT_45_DONE")
        writeProbeStatus("PROBE_TEST_COMPLETE")
    }

    /// Read-only Windows display-stack evidence collection.  The script does
    /// not enumerate modes through a setter or change any VM display behavior.
    private func runDisplayStackDiagnostic() {
        let script = #"""
$o='C:\Users\Public\flux_display_stack.txt'
function A($s){$s|Out-File $o -Append -Encoding utf8}
A '=== PNP DISPLAY CLASS ===';pnputil /enum-devices /class Display 2>&1|Out-File $o -Append -Encoding utf8
A '=== PNP CONNECTED ===';pnputil /enum-devices /connected 2>&1|Out-File $o -Append -Encoding utf8
foreach($n in 'BasicDisplay','BasicRender'){A "=== SC QUERY $n ===";sc.exe query $n 2>&1|Out-File $o -Append -Encoding utf8;A "=== SC QC $n ===";sc.exe qc $n 2>&1|Out-File $o -Append -Encoding utf8}
A '=== DRIVERQUERY BASIC ===';driverquery /v /fo list 2>&1|Select-String 'BasicDisplay|BasicRender'|Out-File $o -Append -Encoding utf8
A '=== ENUM PCI ===';reg query HKLM\SYSTEM\CurrentControlSet\Enum\PCI /s 2>&1|Select-String 'Class|Display|0300|0301|0302'|Out-File $o -Append -Encoding utf8
A '=== ENUM ACPI ===';reg query HKLM\SYSTEM\CurrentControlSet\Enum\ACPI /s 2>&1|Select-String 'Display|Video|Graphics'|Out-File $o -Append -Encoding utf8
A '=== CONTROL VIDEO ===';reg query HKLM\SYSTEM\CurrentControlSet\Control\Video /s 2>&1|Out-File $o -Append -Encoding utf8
"""#
        let encoded = script.data(using: .utf8)!.base64EncodedString()
        let chunks = stride(from: 0, to: encoded.count, by: 96).map { String(encoded.dropFirst($0).prefix(96)) }
        let commands = chunks.enumerated().map { index, chunk in "cmd /c echo \(chunk)\(index == 0 ? ">" : ">>")%TEMP%\\fxd.b64" }
        let decode = "cmd /c certutil -f -decode %TEMP%\\fxd.b64 %TEMP%\\fxd.ps1"
        let execute = "powershell -NoProfile -ExecutionPolicy Bypass -File %TEMP%\\fxd.ps1"
        guard (commands + [decode, execute]).allSatisfy({ $0.count <= 174 }) else { fatalError("Display diagnostic command too long") }
        writeProbeStatus("DISPLAY_DIAG_HELPER_BYTES=\(script.utf8.count)")
        writeProbeStatus("DISPLAY_DIAG_CHUNKS=\(chunks.count)")
        for command in commands { FluxHIDKeyboard.shared.sendWinR(command: command, charDelay: 0.05); Thread.sleep(forTimeInterval: 1.0) }
        FluxHIDKeyboard.shared.sendWinR(command: decode, charDelay: 0.05)
        Thread.sleep(forTimeInterval: 4.0)
        FluxHIDKeyboard.shared.sendWinR(command: execute, charDelay: 0.05)
        Thread.sleep(forTimeInterval: 20.0)
        writeProbeStatus("PROBE_TEST_COMPLETE")
    }

    /// Diagnostic proving PowerShell -EncodedCommand execution path
    /// (direct, current file-based, and corrected file-based).
    private func runPayloadAuditWinRTest() {
        let auditDirectory = FluxVM.defaultAppDirectory()
        FluxHIDKeyboard.shared.resetState()

        // Payload 1: Set-Content C:\Users\Public\flux_encoded_test.txt ENCODED_OK
        // Base64 (160 chars):
        let b64_direct = "UwBlAHQALQBDAG8AbgB0AGUAbgB0ACAAQwA6AFwAVQBzAGUAcgBzAFwAUAB1AGIAbABpAGMAXABmAGwAdQB4AF8AZQBuAGMAbwBkAGUAZABfAHQAZQBzAHQALgB0AHgAdAAgAEUATgBDAE8ARABFAEQAXwBPAEsA"

        // Payload 2: Set-Content C:\Users\Public\flux_file_encoded_test.txt ENCODED_OK
        // Base64 (176 chars):
        let b64_file = "UwBlAHQALQBDAG8AbgB0AGUAbgB0ACAAQwA6AFwAVQBzAGUAcgBzAFwAUAB1AGIAbABpAGMAXABmAGwAdQB4AF8AZgBpAGwAZQBfAGUAbgBjAG8AZABlAGQAXwB0AGUAcwB0AC4AdAB4AHQAIABFAE4AQwBPAEQARQBEAF8ATwBLAA=="

        // Step 1: Direct -EncodedCommand
        print("[ENCODED-TEST] Step 1: Direct -EncodedCommand")
        FluxHIDKeyboard.shared.sendWinR(command: "powershell -NoProfile -EncodedCommand \(b64_direct)", charDelay: 0.02)
        Thread.sleep(forTimeInterval: 5.0)

        // Step 2: Write flux_small.b64 for testing current file-based syntax
        print("[ENCODED-TEST] Step 2: Write b64 to C:\\Users\\Public\\flux_small.b64")
        FluxHIDKeyboard.shared.sendWinR(command: "powershell -NoProfile -Command \"Set-Content C:\\Users\\Public\\flux_small.b64 '\(b64_direct)'\"", charDelay: 0.02)
        Thread.sleep(forTimeInterval: 4.0)

        // Step 3: Test CURRENT file-based syntax (probe style)
        print("[ENCODED-TEST] Step 3: Test current file-based form")
        FluxHIDKeyboard.shared.sendWinR(command: "powershell -NoProfile -EncodedCommand ([IO.File]::ReadAllText('C:\\Users\\Public\\flux_small.b64').Trim())", charDelay: 0.02)
        Thread.sleep(forTimeInterval: 4.0)
        FluxVM.captureCurrentScreenshot(path: auditDirectory + "/encoded_current_form.bmp")
        print("[ENCODED-TEST] Captured encoded_current_form.bmp")

        // Step 4: Write b64_file to flux_small.b64
        print("[ENCODED-TEST] Step 4: Write b64_file to flux_small.b64")
        FluxHIDKeyboard.shared.sendWinR(command: "powershell -NoProfile -Command \"Set-Content C:\\Users\\Public\\flux_small.b64 '\(b64_file)'\"", charDelay: 0.02)
        Thread.sleep(forTimeInterval: 4.0)

        // Step 5: Test CORRECTED file-based form
        print("[ENCODED-TEST] Step 5: Test corrected file-based form")
        FluxHIDKeyboard.shared.sendWinR(command: "powershell -NoProfile -Command \"$b=[IO.File]::ReadAllText('C:\\Users\\Public\\flux_small.b64').Trim(); powershell -NoProfile -EncodedCommand $b\"", charDelay: 0.02)
        Thread.sleep(forTimeInterval: 5.0)
        FluxVM.captureCurrentScreenshot(path: auditDirectory + "/encoded_corrected_form.bmp")
        print("[ENCODED-TEST] Captured encoded_corrected_form.bmp")
        print("[ENCODED-TEST] Completed PowerShell -EncodedCommand proof diagnostic")
    }

    private func runResolutionValidationTest() {
        let auditDirectory = FluxVM.defaultAppDirectory()
        FluxHIDKeyboard.shared.resetState()

        print("🧪 [DISPMODE-PROBE] ==================================================")
        print("🧪 [DISPMODE-PROBE] Display Device Enumeration & Settings Audit")
        print("🧪 [DISPMODE-PROBE] ==================================================")

        let probePS1 = #"""
$o=[Collections.Generic.List[string]]::new()
$o.Add("=== FLUX DISPLAY DEVICE & ENUMERATION PROBE ===")

try{
Add-Type -TypeDefinition @"
using System;using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
public struct DISPLAY_DEVICEW{
 public int cb;
 [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string DeviceName;
 [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)]public string DeviceString;
 public int StateFlags;
 [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)]public string DeviceID;
 [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)]public string DeviceKey;
}
[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Ansi)]
public struct DM{
 [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string dmDeviceName;
 public short dmSpecVersion,dmDriverVersion,dmSize,dmDriverExtra;
 public int dmFields,dmPositionX,dmPositionY,dmDisplayOrientation,dmDisplayFixedOutput;
 public short dmColor,dmDuplex,dmYResolution,dmTTOption,dmCollate;
 [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string dmFormName;
 public short dmLogPixels;
 public int dmBitsPerPel,dmPelsWidth,dmPelsHeight,dmDisplayFlags,dmDisplayFrequency;
 public int dmICMMethod,dmICMIntent,dmMediaType,dmDitherType,dmReserved1,dmReserved2,dmPanningWidth,dmPanningHeight;
}
public class U{
 [DllImport("user32",CharSet=CharSet.Unicode)]public static extern bool EnumDisplayDevicesW(string d,uint i,ref DISPLAY_DEVICEW m,uint f);
 [DllImport("user32",CharSet=CharSet.Unicode)]public static extern bool EnumDisplaySettingsW(string d,int n,ref DM m);
}
"@
 $o.Add("Add-Type: SUCCESS")
}catch{
 $o.Add("Add-Type ERROR: "+$_)
}

$o.Add("Is64BitProcess: "+[Environment]::Is64BitProcess)
try{$o.Add("DM SizeOf: "+[Runtime.InteropServices.Marshal]::SizeOf([DM]))}catch{$o.Add("DM SizeOf ERROR: "+$_)}

$o.Add("")
$o.Add("=== CIM WIN32_VIDEOCONTROLLER ===")
try{
 $vcs=Get-CimInstance Win32_VideoController;$vcCount=0
 foreach($vc in $vcs){
  $vcCount++
  $o.Add("Controller #${vcCount}:")
  $o.Add("  Name:                         "+$vc.Name)
  $o.Add("  Caption:                      "+$vc.Caption)
  $o.Add("  PNPDeviceID:                  "+$vc.PNPDeviceID)
  $o.Add("  DriverVersion:                "+$vc.DriverVersion)
  $o.Add("  VideoModeDescription:         "+$vc.VideoModeDescription)
  $o.Add("  CurrentHorizontalResolution:  "+$vc.CurrentHorizontalResolution)
  $o.Add("  CurrentVerticalResolution:    "+$vc.CurrentVerticalResolution)
  $o.Add("  CurrentBitsPerPixel:          "+$vc.CurrentBitsPerPixel)
  $o.Add("  CurrentRefreshRate:           "+$vc.CurrentRefreshRate)
  $o.Add("  Status:                       "+$vc.Status)
 }
 if($vcCount -eq 0){$o.Add("  (none returned)")}
}catch{$o.Add("  Error: "+$_)}

$o.Add("")
$o.Add("=== CIM WIN32_DESKTOPMONITOR ===")
try{
 $mons=Get-CimInstance Win32_DesktopMonitor;$mCount=0
 foreach($m in $mons){
  $mCount++
  $o.Add("Monitor #${mCount}:")
  $o.Add("  Name:         "+$m.Name)
  $o.Add("  Caption:      "+$m.Caption)
  $o.Add("  DeviceID:     "+$m.DeviceID)
  $o.Add("  PNPDeviceID:  "+$m.PNPDeviceID)
  $o.Add("  ScreenHeight: "+$m.ScreenHeight)
  $o.Add("  ScreenWidth:  "+$m.ScreenWidth)
  $o.Add("  Status:       "+$m.Status)
 }
 if($mCount -eq 0){$o.Add("  (none returned)")}
}catch{$o.Add("  Error: "+$_)}

$o.Add("")
$o.Add("=== ENUMDISPLAYDEVICESW ===")
try{
 $devList=[Collections.Generic.List[string]]::new();$devIdx=0
 while($true){
  $d=New-Object DISPLAY_DEVICEW;$d.cb=[Runtime.InteropServices.Marshal]::SizeOf($d)
  if(-not [U]::EnumDisplayDevicesW($null,[uint32]$devIdx,[ref]$d,0)){break}
  $devList.Add($d.DeviceName)
  $o.Add("Device #${devIdx}:")
  $o.Add("  DeviceName:   "+$d.DeviceName)
  $o.Add("  DeviceString: "+$d.DeviceString)
  $o.Add("  StateFlags:   0x"+[Convert]::ToString($d.StateFlags,16)+" ("+$d.StateFlags+")")
  $o.Add("  DeviceID:     "+$d.DeviceID)
  $o.Add("  DeviceKey:    "+$d.DeviceKey)
  $devIdx++
 }
 $o.Add("Total DISPLAY_DEVICE count: "+$devList.Count)
}catch{$o.Add("EnumDisplayDevicesW Error: "+$_)}

$o.Add("")
$o.Add("=== ENUMDISPLAYSETTINGSW (EXPLICIT DEVICE) ===")
try{
 foreach($dev in $devList){
  $m=New-Object DM;$m.dmSize=[Runtime.InteropServices.Marshal]::SizeOf($m)
  $res=[U]::EnumDisplaySettingsW($dev,-1,[ref]$m)
  $o.Add("Device '$dev' ENUM_CURRENT_SETTINGS:")
  $o.Add("  Return BOOL: "+$res)
  $o.Add("  dmSize:      "+$m.dmSize)
  $o.Add("  Width:       "+$m.dmPelsWidth)
  $o.Add("  Height:      "+$m.dmPelsHeight)
  $o.Add("  BitsPerPel:  "+$m.dmBitsPerPel)
  $o.Add("  Frequency:   "+$m.dmDisplayFrequency)
  $o.Add("  dmFields:    0x"+[Convert]::ToString($m.dmFields,16))
  $seen=@{};$mi=0
  while($true){
   $em=New-Object DM;$em.dmSize=[Runtime.InteropServices.Marshal]::SizeOf($em)
   if(-not [U]::EnumDisplaySettingsW($dev,$mi,[ref]$em)){break}
   $k=""+$em.dmPelsWidth+"x"+$em.dmPelsHeight+"@"+$em.dmDisplayFrequency+"Hz "+$em.dmBitsPerPel+"bpp"
   if(-not $seen[$k]){$seen[$k]=1;$o.Add("    Mode "+$mi+": "+$k)}
   $mi++
  }
  $o.Add("  Total unique modes: "+$seen.Count)
 }
}catch{$o.Add("EnumDisplaySettingsW Error: "+$_)}

$o.Add("")
$o.Add("=== CONTROL CALL: EnumDisplaySettingsW(NULL) ===")
try{
 $nullDM=New-Object DM;$nullDM.dmSize=[Runtime.InteropServices.Marshal]::SizeOf($nullDM)
 $nullResDM=[U]::EnumDisplaySettingsW($null,-1,[ref]$nullDM)
 $o.Add("EnumDisplaySettingsW(NULL): BOOL="+$nullResDM+", Width="+$nullDM.dmPelsWidth+", Height="+$nullDM.dmPelsHeight+", dmSize="+$nullDM.dmSize)
}catch{$o.Add("EnumDisplaySettingsW(NULL) Error: "+$_)}

$o|Out-File 'C:\Users\Public\display_device_probe.txt' -Encoding UTF8
$o|Out-File 'C:\Users\Public\dispprobe.txt' -Encoding UTF8
Start-Process notepad 'C:\Users\Public\display_device_probe.txt'
"""#

        // 1. Host-side encode (raw UTF-8 bytes to Base64)
        let utf8Data = probePS1.data(using: .utf8) ?? Data()
        let b64 = utf8Data.base64EncodedString()
        let hostSHA256 = SHA256.hash(data: utf8Data).map { String(format: "%02x", $0) }.joined()
        print("🧪 [DISPMODE-PROBE] Host probe UTF-8 byte count: \(utf8Data.count)")
        print("🧪 [DISPMODE-PROBE] Host probe Base64 character count: \(b64.count)")

        // Verify roundtrip on host before executing
        if let decodedData = Data(base64Encoded: b64),
           let decodedStr = String(data: decodedData, encoding: .utf8),
           decodedStr == probePS1 {
            print("🧪 [DISPMODE-PROBE] Host local roundtrip verification: PASS")
        } else {
            fatalError("Host base64 roundtrip verification failed!")
        }

        // 2. Split Base64 into 120-character chunks
        let chunkSize = 120
        var chunks: [String] = []
        var startIndex = b64.startIndex
        while startIndex < b64.endIndex {
            let endIndex = b64.index(startIndex, offsetBy: chunkSize, limitedBy: b64.endIndex) ?? b64.endIndex
            chunks.append(String(b64[startIndex..<endIndex]))
            startIndex = endIndex
        }
        print("🧪 [DISPMODE-PROBE] Split Base64 into \(chunks.count) chunks (chunk size \(chunkSize), last chunk \(chunks.last?.count ?? 0))")

        if ProcessInfo.processInfo.environment["FLUX_FAST_PROBE_DELIVERY"] == "1" {
            runFastProbeDelivery(chunks: chunks, base64: b64, probeData: utf8Data, auditDirectory: auditDirectory)
            return
        }

        if ProcessInfo.processInfo.environment["FLUX_CONTINUE_PROBE"] == "1" {
            runContinuationProbe(base64: b64, probeData: utf8Data, auditDirectory: auditDirectory)
            return
        }

        let repairMissingChunk3 = ProcessInfo.processInfo.environment["FLUX_REPAIR_MISSING_CHUNK_3"] == "1"

        // Repair only the known missing third line when the existing guest payload is
        // present. This intentionally avoids replaying the other 63 delivery commands.
        if repairMissingChunk3 {
            guard chunks.count == 64 else {
                fatalError("Expected 64 probe chunks; got \(chunks.count)")
            }
            let missingChunk = chunks[2]
            FluxHIDKeyboard.shared.sendWinR(
                command: "cmd.exe /c >C:\\Users\\Public\\flux_chunk3.b64 echo \(missingChunk)",
                charDelay: 0.01
            )
            Thread.sleep(forTimeInterval: 2.0)
            let spliceCmd = "powershell -NoProfile -Command \"$p='C:\\Users\\Public\\flux_probe.b64';$a=Get-Content $p;$c=Get-Content C:\\Users\\Public\\flux_chunk3.b64;[IO.File]::WriteAllLines($p,@($a[0],$a[1],$c)+$a[2..($a.Count-1)])\""
            FluxHIDKeyboard.shared.sendWinR(command: spliceCmd, charDelay: 0.01)
            Thread.sleep(forTimeInterval: 3.0)
        } else {
        // 3. Deliver Base64 chunks via short cmd.exe echo commands (instant execution, no .NET overhead)
        print("🧪 [DISPMODE-PROBE] Writing \(chunks.count) chunks to C:\\Users\\Public\\flux_probe.b64...")
        for (idx, chunk) in chunks.enumerated() {
            let redir = (idx == 0) ? ">" : ">>"
            let cmd = "cmd.exe /c \(redir)C:\\Users\\Public\\flux_probe.b64 echo \(chunk)"
            print("🧪 [DISPMODE-PROBE] Chunk \(idx + 1)/\(chunks.count) (\(cmd.count) chars)...")
            FluxHIDKeyboard.shared.sendWinR(command: cmd, charDelay: 0.01)
            Thread.sleep(forTimeInterval: 2.0)
        }
        print("🧪 [DISPMODE-PROBE] All \(chunks.count) Base64 chunks written.")
        Thread.sleep(forTimeInterval: 2.0)
        }

        // 4. Decode to C:\Users\Public\flux_probe.ps1
        print("🧪 [DISPMODE-PROBE] Decoding Base64 to C:\\Users\\Public\\flux_probe.ps1...")
        let decodeCmd = "powershell -NoProfile -Command \"$b=([IO.File]::ReadAllText('C:\\Users\\Public\\flux_probe.b64') -replace '\\r\\n',''); [IO.File]::WriteAllBytes('C:\\Users\\Public\\flux_probe.ps1', [Convert]::FromBase64String($b))\""
        print("🧪 [DISPMODE-PROBE] Decode command (\(decodeCmd.count) chars)...")
        FluxHIDKeyboard.shared.sendWinR(command: decodeCmd, charDelay: 0.01)
        Thread.sleep(forTimeInterval: 5.0)

        // 5. Verify the actual repaired guest files. The following command is the
        // only execution gate: it will invoke the unchanged probe only on PASS.
        let verifyCmd = "powershell -NoProfile -Command \"$b='C:\\Users\\Public\\flux_probe.b64';$p='C:\\Users\\Public\\flux_probe.ps1';$v='C:\\Users\\Public\\flux_probe_verify.txt';$s=(Get-Content $b|?{$_ -match '\\S'}).Count;$n=([regex]::Replace((Get-Content $b -Raw),'\\s',''));$ok='YES';try{[void][Convert]::FromBase64String($n)}catch{$ok='NO'};$z=if(Test-Path $p){(Get-Item $p).Length}else{-1};$g=if(Test-Path $p){(Get-FileHash $p -Algorithm SHA256).Hash.ToLower()}else{''};$m=($s -eq 64 -and $n.Length -eq 7616 -and $ok -eq 'YES' -and $z -eq 5710 -and $g -eq '\(hostSHA256)');@('SEGMENTS='+$s,'NORMALIZED_LENGTH='+$n.Length,'DECODE_VALID='+$ok,'PS1_SIZE='+$z,'HOST_SHA256=\(hostSHA256)','GUEST_SHA256='+$g,'HASH_MATCH='+(if($g -eq '\(hostSHA256)'){'YES'}else{'NO'}),'VERIFY='+(if($m){'PASS'}else{'FAIL'}))|Set-Content $v\""
        print("🧪 [DISPMODE-PROBE] Verifying repaired guest payload before execution...")
        FluxHIDKeyboard.shared.sendWinR(command: verifyCmd, charDelay: 0.01)
        Thread.sleep(forTimeInterval: 5.0)

        print("🧪 [DISPMODE-PROBE] Executing C:\\Users\\Public\\flux_probe.ps1 only if guest verification passed...")
        let execCmd = "powershell -NoProfile -Command \"$v=Get-Content 'C:\\Users\\Public\\flux_probe_verify.txt';if($v -contains 'VERIFY=PASS'){& 'C:\\Users\\Public\\flux_probe.ps1'}\""
        FluxHIDKeyboard.shared.sendWinR(command: execCmd, charDelay: 0.01)
        print("🧪 [DISPMODE-PROBE] Waiting 40s for probe execution, P/Invoke Add-Type, and file output...")
        Thread.sleep(forTimeInterval: 40.0)

        FluxVM.captureCurrentScreenshot(path: auditDirectory + "/dispprobe_done.bmp")
        print("🧪 [DISPMODE-PROBE] Probe run complete. Captured dispprobe_done.bmp")
    }

    /// Sends the display probe through one focused PowerShell console. This avoids
    /// reopening the Windows Run dialog for each Base64 segment.
    private func runFastProbeDelivery(chunks: [String], base64: String, probeData: Data, auditDirectory: String) {
        let keyboard = FluxHIDKeyboard.shared
        let hostB64SHA256 = SHA256.hash(data: Data(base64.utf8)).map { String(format: "%02x", $0) }.joined()
        let hostPS1SHA256 = SHA256.hash(data: probeData).map { String(format: "%02x", $0) }.joined()
        let b64Path = "C:\\Users\\Public\\flux_probe.b64"
        let ps1Path = "C:\\Users\\Public\\flux_probe.ps1"
        let verifyPath = "C:\\Users\\Public\\flux_probe_verify.txt"
        let resultPath = "C:\\Users\\Public\\display_device_probe.txt"

        guard chunks.count == 64, base64.count == 7616, probeData.count == 5710 else {
            fatalError("Fast probe host precondition failed")
        }

        print("🧪 [FAST-PROBE] Opening one PowerShell console via Win+R")
        let powerShellOpened = Date()
        keyboard.sendWinR(command: "powershell -NoProfile", charDelay: 0.01)
        Thread.sleep(forTimeInterval: 4.0)
        guard keyboard.waitUntilQueueDrained(timeout: 300.0) else { return }
        print("🧪 [FAST-PROBE] POWERSHELL_READY elapsed=\(String(format: "%.3f", Date().timeIntervalSince(powerShellOpened)))")

        func submit(_ command: String) {
            keyboard.typeString(command, charDelay: 0.008)
            Thread.sleep(forTimeInterval: 0.4)
            keyboard.handleKeyDown(keyCode: 0x24, isRepeat: false)
            Thread.sleep(forTimeInterval: 0.12)
            keyboard.handleKeyUp(keyCode: 0x24)
            Thread.sleep(forTimeInterval: 0.8)
        }

        // Clear only this probe's scratch files in the already-open console.
        submit("Remove-Item '\(b64Path)','\(ps1Path)','\(verifyPath)','\(resultPath)' -Force -ErrorAction SilentlyContinue")

        let base64EnqueueStarted = Date()
        print("🧪 [FAST-PROBE] BASE64_ENQUEUE_START")
        for (index, chunk) in chunks.enumerated() {
            let write = index == 0 ? "WriteAllText" : "AppendAllText"
            submit("[IO.File]::\(write)('\(b64Path)','\(chunk)'+[Environment]::NewLine)")
        }
        print("🧪 [FAST-PROBE] BASE64_ENQUEUE_END elapsed=\(String(format: "%.3f", Date().timeIntervalSince(base64EnqueueStarted)))")

        // Do not type verification until every EP3 report for the final append
        // has been consumed and completed by the guest endpoint.
        guard keyboard.waitUntilQueueDrained(timeout: 300.0) else { return }
        Thread.sleep(forTimeInterval: 1.0) // Allow PowerShell to complete the last AppendAllText call.

        // Base64 verification is completed before any decode is attempted.
        let verificationSent = Date()
        submit("$b='\(b64Path)';$p='\(ps1Path)';$v='\(verifyPath)';$s=(Get-Content $b|?{$_ -match '\\S'}).Count;$n=[regex]::Replace((Get-Content $b -Raw),'\\s','');$bh=(([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($n))|%{$_.ToString('x2')})-join '');$bok=($s -eq 64 -and $n.Length -eq 7616 -and $bh -eq '\(hostB64SHA256)');@('SEGMENTS='+$s,'NORMALIZED_LENGTH='+$n.Length,'HOST_B64_SHA256=\(hostB64SHA256)','GUEST_B64_SHA256='+$bh,'BASE64_VERIFY='+(if($bok){'PASS'}else{'FAIL'}))|Set-Content $v")
        guard keyboard.waitUntilQueueDrained(timeout: 300.0) else { return }
        Thread.sleep(forTimeInterval: 1.0) // Guest-side command completion after Enter.
        print("🧪 [FAST-PROBE] VERIFICATION_COMMAND_DELIVERED elapsed=\(String(format: "%.3f", Date().timeIntervalSince(verificationSent)))")

        // Decode happens only for a verified guest Base64 payload.
        submit("if($bok){[IO.File]::WriteAllBytes($p,[Convert]::FromBase64String($n))}")
        guard keyboard.waitUntilQueueDrained(timeout: 300.0) else { return }
        Thread.sleep(forTimeInterval: 1.0)

        let executionSent = Date()
        submit("$z=if(Test-Path $p){(Get-Item $p).Length}else{-1};$g=if(Test-Path $p){(Get-FileHash $p -Algorithm SHA256).Hash.ToLower()}else{''};$pok=($z -eq 5710 -and $g -eq '\(hostPS1SHA256)');Add-Content $v @('PS1_SIZE='+$z,'HOST_SHA256=\(hostPS1SHA256)','GUEST_SHA256='+$g,'PS1_VERIFY='+(if($pok){'PASS'}else{'FAIL'}),'VERIFY='+(if($bok -and $pok){'PASS'}else{'FAIL'}));if($bok -and $pok){Set-ExecutionPolicy Bypass -Scope Process -Force;& $p}")
        guard keyboard.waitUntilQueueDrained(timeout: 300.0) else { return }
        Thread.sleep(forTimeInterval: 5.0) // Script startup settle after confirmed command receipt.
        print("🧪 [FAST-PROBE] EXECUTION_COMMAND_DELIVERED elapsed=\(String(format: "%.3f", Date().timeIntervalSince(executionSent)))")

        print("🧪 [FAST-PROBE] Queue-drained delivery complete; capture is diagnostic only, not receipt proof")
        FluxVM.captureCurrentScreenshot(path: auditDirectory + "/dispprobe_done.bmp")
    }

    /// Continues an already complete guest Base64 payload.  This deliberately
    /// sends only decode, verification, and probe commands -- never the 64
    /// payload chunks.  Each phase records a guest file marker and then writes
    /// the same unique nonce to the existing PL011 serial port for host-side
    /// acknowledgement before the next phase begins.
    private func runContinuationProbe(base64: String, probeData: Data, auditDirectory: String) {
        let keyboard = FluxHIDKeyboard.shared
        let hostB64SHA256 = SHA256.hash(data: Data(base64.utf8)).map { String(format: "%02x", $0) }.joined()
        let hostPS1SHA256 = SHA256.hash(data: probeData).map { String(format: "%02x", $0) }.joined()
        let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let b64Path = "C:\\Users\\Public\\flux_probe.b64"
        let ps1Path = "C:\\Users\\Public\\flux_probe.ps1"
        let verifyPath = "C:\\Users\\Public\\flux_probe_verify.txt"
        let decodeAckPath = "C:\\Users\\Public\\flux_ack_decode.txt"
        let verifyAckPath = "C:\\Users\\Public\\flux_ack_verify.txt"
        let probeAckPath = "C:\\Users\\Public\\flux_ack_probe.txt"

        guard base64.count == 7616, probeData.count == 5710 else {
            fatalError("Continuation probe host precondition failed")
        }

        func submit(_ command: String) {
            keyboard.typeString(command, charDelay: 0.008)
            Thread.sleep(forTimeInterval: 0.4)
            keyboard.handleKeyDown(keyCode: 0x24, isRepeat: false)
            Thread.sleep(forTimeInterval: 0.12)
            keyboard.handleKeyUp(keyCode: 0x24)
            Thread.sleep(forTimeInterval: 0.8)
        }

        func serialAck(_ marker: String) -> String {
            "$sp=$null;try{$sp=[IO.Ports.SerialPort]::new('COM1',115200,'None',8,'One');$sp.Open();$sp.WriteLine('\(marker)')}finally{if($sp){$sp.Dispose()}}"
        }

        func submitAndAwait(_ phase: String, command: String, marker: String) -> Bool {
            print("🧪 [CONTINUATION-PROBE] \(phase)_COMMAND_SENT marker=\(marker)")
            submit(command)
            guard keyboard.waitUntilQueueDrained(timeout: 120.0) else { return false }
            return FluxUART.waitForDiagnosticOutput(marker, timeout: 120.0)
        }

        print("🧪 [CONTINUATION-PROBE] Opening one PowerShell console; nonce=\(nonce)")
        keyboard.sendWinR(command: "powershell -NoProfile", charDelay: 0.01)
        guard keyboard.waitUntilQueueDrained(timeout: 120.0) else { return }

        let decodeMarker = "DECODE_DONE_\(nonce)"
        let decodeCommand = "$b=[regex]::Replace((Get-Content '\(b64Path)' -Raw),'\\s','');[IO.File]::WriteAllBytes('\(ps1Path)',[Convert]::FromBase64String($b));[IO.File]::WriteAllText('\(decodeAckPath)','\(decodeMarker)');\(serialAck(decodeMarker))"
        guard submitAndAwait("DECODE", command: decodeCommand, marker: decodeMarker) else { return }

        let verifyMarker = "VERIFY_DONE_\(nonce)"
        let verifyCommand = "$b='\(b64Path)';$p='\(ps1Path)';$v='\(verifyPath)';$s=(Get-Content $b|?{$_ -match '\\S'}).Count;$n=[regex]::Replace((Get-Content $b -Raw),'\\s','');$ok='YES';try{[void][Convert]::FromBase64String($n)}catch{$ok='NO'};$z=if(Test-Path $p){(Get-Item $p).Length}else{-1};$g=if(Test-Path $p){(Get-FileHash $p -Algorithm SHA256).Hash.ToLower()}else{''};$m=($s -eq 64 -and $n.Length -eq 7616 -and $ok -eq 'YES' -and $z -eq 5710 -and $g -eq '\(hostPS1SHA256)');@('SEGMENTS='+$s,'NORMALIZED_LENGTH='+$n.Length,'DECODE_VALID='+$ok,'PS1_SIZE='+$z,'HOST_SHA256=\(hostPS1SHA256)','GUEST_SHA256='+$g,'HASH_MATCH='+(if($g -eq '\(hostPS1SHA256)'){'YES'}else{'NO'}),'VERIFY='+(if($m){'PASS'}else{'FAIL'}))|Set-Content $v;[IO.File]::WriteAllText('\(verifyAckPath)','\(verifyMarker)');\(serialAck(verifyMarker))"
        guard submitAndAwait("VERIFY", command: verifyCommand, marker: verifyMarker) else { return }

        let probeMarker = "PROBE_DONE_\(nonce)"
        let probeCommand = "$v=Get-Content '\(verifyPath)';if($v -contains 'VERIFY=PASS'){& '\(ps1Path)';[IO.File]::WriteAllText('\(probeAckPath)','\(probeMarker)');\(serialAck(probeMarker))}"
        guard submitAndAwait("PROBE", command: probeCommand, marker: probeMarker) else { return }

        print("🧪 [CONTINUATION-PROBE] All guest acknowledgements observed; capture is diagnostic only")
        FluxVM.captureCurrentScreenshot(path: auditDirectory + "/dispprobe_done.bmp")
    }


    private func runLiveValidationTest() {

        print("🧪 [INPUT-POLISH] ==================================================")
        print("🧪 [INPUT-POLISH] Starting Parallels-like Input Polish Validation")
        print("🧪 [INPUT-POLISH] ==================================================")

        let fbSnap = FluxFramebuffer.shared.snapshot()
        let fbW = fbSnap.width > 0 ? fbSnap.width : 1024
        let fbH = fbSnap.height > 0 ? fbSnap.height : 768
        let viewSize = CGSize(width: CGFloat(fbW), height: CGFloat(fbH))

        // 1. Slow Motion: Four corners & Center
        print("🧪 [INPUT-POLISH] 1. Slow Motion: Four Corners & Center")
        let cornerTests: [(name: String, pt: CGPoint)] = [
            ("Top-Left", CGPoint(x: 0, y: 0)),
            ("Top-Right", CGPoint(x: CGFloat(fbW), y: 0)),
            ("Bottom-Right", CGPoint(x: CGFloat(fbW), y: CGFloat(fbH))),
            ("Bottom-Left", CGPoint(x: 0, y: CGFloat(fbH))),
            ("Center", CGPoint(x: CGFloat(fbW) / 2.0, y: CGFloat(fbH) / 2.0))
        ]
        for tc in cornerTests {
            if let map = Self.mapPointToHID(viewPoint: tc.pt, viewSize: viewSize, fbWidth: fbW, fbHeight: fbH) {
                print("🧪 [INPUT-POLISH] Corner: \(tc.name) -> Mac=(\(Int(tc.pt.x)), \(Int(tc.pt.y))) HID=(\(map.hidX), \(map.hidY))")
                self.updatePosition(x: map.hidX, y: map.hidY)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        // 2. Rapid Motion & Coalescing Performance
        print("🧪 [INPUT-POLISH] 2. Rapid Motion & Coalescing Performance Test")
        let rapidStart = CFAbsoluteTimeGetCurrent()
        let rapidCount = 60
        for i in 0..<rapidCount {
            let px = UInt16(10000 + (i * 200))
            let py = UInt16(10000 + (i * 150))
            self.updatePosition(x: px, y: py)
            Thread.sleep(forTimeInterval: 0.005) // 200Hz generation rate
        }
        let rapidDuration = CFAbsoluteTimeGetCurrent() - rapidStart
        let pending = self.queueCount
        let rps = Double(rapidCount) / rapidDuration
        print("🧪 [INPUT-POLISH] Rapid motion: \(rapidCount) events in \(String(format: "%.3f", rapidDuration))s (\(Int(rps)) evt/s). Pending queue depth=\(pending)")

        // 3. Click Robustness: Left, Right, Middle, Double-click
        print("🧪 [INPUT-POLISH] 3. Click Robustness: Left, Right, Middle, Double-click")
        self.updatePosition(x: 14000, y: 14000)
        Thread.sleep(forTimeInterval: 0.1)

        // Middle click
        print("🧪 [INPUT-POLISH] Middle click (Button 3)...")
        self.updateButtons(0x04)
        Thread.sleep(forTimeInterval: 0.1)
        self.updateButtons(0x00)
        Thread.sleep(forTimeInterval: 0.2)

        // Right click
        print("🧪 [INPUT-POLISH] Right click (Button 2)...")
        self.updateButtons(0x02)
        Thread.sleep(forTimeInterval: 0.1)
        self.updateButtons(0x00)
        Thread.sleep(forTimeInterval: 0.3)

        // Double click
        print("🧪 [INPUT-POLISH] Double click (Button 1)...")
        self.updateButtons(0x01)
        Thread.sleep(forTimeInterval: 0.08)
        self.updateButtons(0x00)
        Thread.sleep(forTimeInterval: 0.08)
        self.updateButtons(0x01)
        Thread.sleep(forTimeInterval: 0.08)
        self.updateButtons(0x00)
        Thread.sleep(forTimeInterval: 0.3)

        // 4. Drag & Drag Outside Viewport + Release
        print("🧪 [INPUT-POLISH] 4. Drag & Drag Outside Viewport + Release")
        self.updatePosition(x: 16000, y: 16000)
        Thread.sleep(forTimeInterval: 0.1)
        self.updateButtons(0x01) // Left down
        Thread.sleep(forTimeInterval: 0.1)
        for step in 1...5 {
            self.updatePosition(x: UInt16(16000 + step * 1000), y: UInt16(16000 + step * 1000))
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Drag outside boundary (simulating pointer moving past viewport to negative coordinates)
        if let mapOutside = Self.mapPointToHID(viewPoint: CGPoint(x: -50, y: -50), viewSize: viewSize, fbWidth: fbW, fbHeight: fbH) {
            print("🧪 [INPUT-POLISH] Drag outside viewport: clamped to HID=(\(mapOutside.hidX), \(mapOutside.hidY))")
            self.updatePosition(x: mapOutside.hidX, y: mapOutside.hidY)
            Thread.sleep(forTimeInterval: 0.1)
        }
        // Release outside viewport
        print("🧪 [INPUT-POLISH] Releasing button outside viewport...")
        self.updateButtons(0x00)
        Thread.sleep(forTimeInterval: 0.3)

        // 5. Vertical Scroll Wheel: Up and Down
        print("🧪 [INPUT-POLISH] 5. Vertical Scroll Wheel Test")
        print("🧪 [INPUT-POLISH] Scrolling Up (+3 ticks)...")
        self.updateWheel(delta: 1)
        Thread.sleep(forTimeInterval: 0.1)
        self.updateWheel(delta: 2)
        Thread.sleep(forTimeInterval: 0.2)

        print("🧪 [INPUT-POLISH] Scrolling Down (-3 ticks)...")
        self.updateWheel(delta: -1)
        Thread.sleep(forTimeInterval: 0.1)
        self.updateWheel(delta: -2)
        Thread.sleep(forTimeInterval: 0.3)

        // 6. Fullscreen & Resize Coordinate Mapping Test
        print("🧪 [INPUT-POLISH] 6. Viewport Resize & Fullscreen Simulation")
        let simulatedFullscreenSize = CGSize(width: 1920, height: 1080)
        let centerPoint = CGPoint(x: 1920 / 2.0, y: 1080 / 2.0)
        if let mapFS = Self.mapPointToHID(viewPoint: centerPoint, viewSize: simulatedFullscreenSize, fbWidth: fbW, fbHeight: fbH) {
            print("🧪 [INPUT-POLISH] 1920x1080 Fullscreen center: view=(\(Int(centerPoint.x)), \(Int(centerPoint.y))) -> HID=(\(mapFS.hidX), \(mapFS.hidY)) guest=(\(mapFS.guestX), \(mapFS.guestY))")
            self.updatePosition(x: mapFS.hidX, y: mapFS.hidY)
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Move to Start Menu and click
        let startPoint = CGPoint(x: CGFloat(fbW) * 0.48, y: CGFloat(fbH) - 15)
        if let mapStart = Self.mapPointToHID(viewPoint: startPoint, viewSize: viewSize, fbWidth: fbW, fbHeight: fbH) {
            print("🧪 [INPUT-POLISH] Left-click Start Menu at HID=(\(mapStart.hidX), \(mapStart.hidY))")
            self.updatePosition(x: mapStart.hidX, y: mapStart.hidY)
            Thread.sleep(forTimeInterval: 0.2)
            self.updateButtons(0x01)
            Thread.sleep(forTimeInterval: 0.1)
            self.updateButtons(0x00)
            Thread.sleep(forTimeInterval: 0.8)
        }

        // 7. Keyboard Polish Tests
        print("🧪 [INPUT-POLISH] 7. Keyboard Polish Tests")
        // Type 'H', 'I'
        print("🧪 [INPUT-POLISH] Typing 'H' (HID 0x0B)...")
        FluxHIDKeyboard.shared.handleKeyDown(keyCode: 4, isRepeat: false) // H
        Thread.sleep(forTimeInterval: 0.1)
        FluxHIDKeyboard.shared.handleKeyUp(keyCode: 4)
        Thread.sleep(forTimeInterval: 0.1)

        // Shift + A (Key code 0, Shift modifier)
        print("🧪 [INPUT-POLISH] Shift + A...")
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: 56, rawFlags: 0x0002 | 0x20000) // Left Shift
        Thread.sleep(forTimeInterval: 0.05)
        FluxHIDKeyboard.shared.handleKeyDown(keyCode: 0, isRepeat: false) // A
        Thread.sleep(forTimeInterval: 0.1)
        FluxHIDKeyboard.shared.handleKeyUp(keyCode: 0)
        Thread.sleep(forTimeInterval: 0.05)
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: 56, rawFlags: 0) // Shift released
        Thread.sleep(forTimeInterval: 0.2)

        // Ctrl + A (Select All)
        print("🧪 [INPUT-POLISH] Ctrl + A...")
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: 59, rawFlags: 0x0001 | 0x40000) // Left Ctrl
        Thread.sleep(forTimeInterval: 0.05)
        FluxHIDKeyboard.shared.handleKeyDown(keyCode: 0, isRepeat: false) // A
        Thread.sleep(forTimeInterval: 0.1)
        FluxHIDKeyboard.shared.handleKeyUp(keyCode: 0)
        Thread.sleep(forTimeInterval: 0.05)
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: 59, rawFlags: 0) // Ctrl released
        Thread.sleep(forTimeInterval: 0.2)

        // Alt/Option key event
        print("🧪 [INPUT-POLISH] Alt/Option event...")
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: 58, rawFlags: 0x0020 | 0x80000) // Left Alt
        Thread.sleep(forTimeInterval: 0.1)
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: 58, rawFlags: 0) // Alt released
        Thread.sleep(forTimeInterval: 0.2)

        // Command key (Windows key) press & release
        print("🧪 [INPUT-POLISH] Command (Windows GUI) press & release...")
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: 55, rawFlags: 0x0008 | 0x100000) // Left Command
        Thread.sleep(forTimeInterval: 0.1)
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: 55, rawFlags: 0) // Command released
        Thread.sleep(forTimeInterval: 0.2)

        // Focus loss safety test: modifiers held while focus is lost
        print("🧪 [INPUT-POLISH] Focus loss safety test: holding Shift + Alt, then calling resetState()...")
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: 56, rawFlags: 0x0022 | 0xA0000) // Shift + Alt
        Thread.sleep(forTimeInterval: 0.1)
        FluxHIDKeyboard.shared.resetState()
        Thread.sleep(forTimeInterval: 0.2)

        // Capture screenshot of Windows desktop with pointer / menu state
        FluxVM.captureCurrentScreenshot()
        print("🧪 [INPUT-POLISH] Parallels-like Input Polish Validation complete!")
    }
}
