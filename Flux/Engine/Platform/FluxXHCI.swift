import Foundation
import Hypervisor

/// Small xHCI controller: bring-up, two fixed USB2 root ports, one ERST
/// segment and one MSI-X vector. Only the first standard EP0 device-descriptor
/// exchange is currently implemented; no HID or general USB transfer engine exists.
nonisolated final class FluxXHCI {
    /// Opt-in, bounded handoff telemetry for the installed-Windows xHCI probe.
    /// It observes PCI discovery and first endpoint activity only; it has no
    /// effect on controller, port, command-ring, or MSI-X behavior.
    private static let traceWindowsHandoff = ProcessInfo.processInfo.environment["FLUX_TRACE_XHCI_HANDOFF"] == "1"
    /// Opt-in root-port acceptance audit. This is telemetry only: it records
    /// the state Windows sees around root-port events without changing any
    /// register, event-ring, or interrupt behavior.
    private static let tracePortAudit = ProcessInfo.processInfo.environment["FLUX_TRACE_XHCI_PORT_AUDIT"] == "1"
    /// Bounded, read-only Address Device context audit. It copies no state and
    /// only emits the input and output contexts surrounding command completion.
    private static let traceAddressAudit = ProcessInfo.processInfo.environment["FLUX_TRACE_XHCI_ADDRESS_AUDIT"] == "1"
    /// Narrow, read-only trace for the first Windows EP0 decision after a
    /// successful Address Device completion. It never advances a ring or
    /// changes controller/guest state.
    private static let traceEP0Stop = ProcessInfo.processInfo.environment["FLUX_TRACE_EP0_STOP"] == "1"
    /// One-shot, read-only trace of the Port 1 reset which follows the first
    /// successful Configure Endpoint command.  It is deliberately inactive
    /// until that command has completed and self-disables at the next command
    /// TRB, so it cannot turn normal xHCI traffic into an MMIO log flood.
    private static let traceSecondReset = ProcessInfo.processInfo.environment["FLUX_TRACE_SECOND_RESET"] == "1"
    let bar0Size: UInt64 = 0x10000, bar2Size: UInt64 = 0x1000
    private let lock = NSLock()
    private var config = [UInt8](repeating: 0, count: 256)
    private var pciCommand: UInt16 = 0
    private var bar0Base: UInt64 = 0, bar2Base: UInt64 = 0
    private var bar0Sizing = false, bar2Sizing = false
    private let cap: UInt32 = 0x40, xcap: UInt32 = 0x100, dboff: UInt32 = 0x1000, rtoff: UInt32 = 0x2000
    private static let msixCap: UInt32 = 0x50
    private let halted: UInt32 = 1, hcrst: UInt32 = 2, cnr: UInt32 = 1 << 11
    private var usbcmd: UInt32 = 0, usbsts: UInt32 = 1, dnctrl: UInt32 = 0, configSlots: UInt32 = 0
    private var crcr: UInt64 = 0, dcbaap: UInt64 = 0, resetDeadline: UInt64?
    private var commandDequeue: UInt64 = 0, commandCycle: UInt32 = 1
    private static let implementedSlots = 2
    private struct Slot {
        var enabled = false
        /// Address Device with BSR=1 has initialized a Default-state device
        /// context for this slot.  This is deliberately distinct from the
        /// xHCI Slot State "Addressed" produced by BSR=0.
        var defaultContextReady = false
        var addressed = false
        var port: Int? = nil
        var usbAddress: UInt8 = 0
        var configurationValue: UInt8 = 0
        var idleDuration: UInt8 = 0
        var idleReportID: UInt8 = 0
        var keyboardLEDs: UInt8 = 0
    }
    private var slots = Array(repeating: Slot(), count: implementedSlots)
    private var iman: UInt32 = 0, imod: UInt32 = 0, erstsz: UInt32 = 0
    private var erstba: UInt64 = 0, erdp: UInt64 = 0
    private var eventIndex: UInt16 = 0, eventCycle: UInt32 = 1
    private var guestHost: UnsafeMutableRawPointer?, guestBase: UInt64 = 0, guestSize: Int = 0
    private struct Port { var connected = false; var enabled = false; var resetDeadline: UInt64?; var changes: UInt32 = 0; var eventQueued = false }
    private var ports = [Port(), Port()]
    private struct Table { var lo: UInt32 = 0, hi: UInt32 = 0, data: UInt32 = 0, control: UInt32 = 1; var address: UInt64 { UInt64(lo) | UInt64(hi) << 32 }; var masked: Bool { control & 1 != 0 } }
    private var msixControl: UInt16 = 0, table = Table(), pba: UInt64 = 0
    private struct Delivery { let address: hv_ipa_t; let data: UInt32 }
    // One-shot, read-only audit of the observed Windows post-HCRST path.
    // Windows arrives with PCI Command 0x0416; the next HCRST is captured
    // until its next reset request. Repeated polling reads are coalesced by
    // offset/value so telemetry cannot perturb the guest's timing.
    private var windowsAuditArmed = false, windowsAuditActive = false, windowsAuditComplete = false
    private var windowsAuditReads: [UInt32: UInt64] = [:]
    private var ep0TraceActive = false
    private var ep0TraceSequence: UInt64 = 0
    private var secondResetTraceArmed = false
    private var secondResetTraceActive = false
    private var secondResetTraceSequence: UInt64 = 0
    // Deliberately non-production identity for Flux's temporary fixed USB
    // device. This does not represent, or borrow, a USB-IF vendor assignment.
    private static let testUSBVendorID: UInt16 = 0xF1F0
    private static let testUSBProductID: UInt16 = 0x0001

    private static let instanceLock = NSLock()
    private static weak var currentInstance: FluxXHCI?

    static func notifyKeyboardEvent() {
        instanceLock.lock()
        let inst = currentInstance
        instanceLock.unlock()
        inst?.serviceEP3Transfer()
    }

    func serviceEP3Transfer() {
        var d: Delivery?
        lock.lock()
        d = processEP3InterruptTransferLocked()
        lock.unlock()
        send(d)
    }

    static func notifyPointerEvent() {
        instanceLock.lock()
        let inst = currentInstance
        instanceLock.unlock()
        inst?.serviceEP5Transfer()
    }

    func serviceEP5Transfer() {
        var d: Delivery?
        lock.lock()
        d = processEP5InterruptTransferLocked()
        lock.unlock()
        send(d)
    }

    init() {
        Self.instanceLock.lock()
        Self.currentInstance = self
        Self.instanceLock.unlock()

        config[0] = 0x36; config[1] = 0x1B; config[2] = 0x14; config[3] = 0
        // Type-0 Status: a nonzero capability pointer requires the immutable
        // Capabilities List status bit. Other status bits remain unadvertised.
        config[6] = 0x10
        config[9] = 0x30; config[10] = 0x03; config[11] = 0x0C; config[0x0E] = 0
        config[0x34] = UInt8(Self.msixCap); config[0x3C] = 0xFF
        config[Int(Self.msixCap)] = 0x11 // MSI-X, one vector
        config[Int(Self.msixCap + 4)] = 0x02 // table: BAR2 + 0
        config[Int(Self.msixCap + 8)] = 0x02; config[Int(Self.msixCap + 9)] = 0x08 // PBA + 0x800
    }

    deinit {
        Self.instanceLock.lock()
        if Self.currentInstance === self { Self.currentInstance = nil }
        Self.instanceLock.unlock()
    }
    func configure(guestRAM: UnsafeMutableRawPointer, guestBase: UInt64, guestSize: Int) { lock.lock(); defer { lock.unlock() }; guestHost = guestRAM; self.guestBase = guestBase; self.guestSize = guestSize }
    func containsMMIO(_ gpa: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return pciCommand & 2 != 0 && ((gpa >= bar0Base && gpa < bar0Base + bar0Size) || (gpa >= bar2Base && gpa < bar2Base + bar2Size)) }
    func readPCIConfig(offset: UInt32, size: Int) -> UInt64 { lock.lock(); defer { lock.unlock() }; var v: UInt64 = 0; for i in 0..<size { v |= UInt64(pciByte(Int(offset) + i)) << UInt64(8 * i) }; if offset == 0 || offset == 8 || offset == 0x10 || offset == Self.msixCap { print("PCI_CFG RD [xHCI]: reg=0x\(String(offset, radix: 16)) -> 0x\(String(v, radix: 16))") }; if Self.traceWindowsHandoff && (offset == 4 || offset == 0x10 || offset == 0x18 || offset == 0x34 || offset == Self.msixCap || offset == Self.msixCap + 2) { print("[XHCI-HANDOFF PCI RD] off=0x\(String(offset, radix: 16)) width=\(size) value=0x\(String(v, radix: 16))") }; if windowsAuditActive && (offset == 4 || offset == 6 || offset == 0x10 || offset == 0x18 || offset == 0x34 || offset == Self.msixCap || offset == Self.msixCap + 2 || offset == 0x3C) { auditRead("PCI", offset, size, v) }; return v }
    func writePCIConfig(offset: UInt32, value: UInt64, size: Int) {
        var d: Delivery?; lock.lock()
        if overlap(offset,size,Self.msixCap+2,2) { writeMSIXControl(offset,value,size); d = prepareMSILocked(); lock.unlock(); send(d); return }
        if overlap(offset,size,0x10,4) { writeBAR(&bar0Base, &bar0Sizing, offset, value, size, 0x10, 0xFFFF0000, "BAR0") }
        else if overlap(offset,size,0x18,4) { writeBAR(&bar2Base, &bar2Sizing, offset, value, size, 0x18, 0xFFFFF000, "MSI-X BAR2") }
        else if overlap(offset,size,4,2) { for i in 0..<size where offset+UInt32(i) < 6 { config[Int(offset)+i] = UInt8((value >> UInt64(8*i)) & 255) }; pciCommand = UInt16(config[4]) | UInt16(config[5]) << 8; if pciCommand == 0x416 && !windowsAuditComplete { windowsAuditArmed = true; print("[XHCI-WINDOWS-AUDIT] armed by PCI Command 0x0416") }; print("⚙️ FluxXHCI: PCI Command = 0x\(String(pciCommand,radix:16))") }
        lock.unlock()
    }
    func readMMIO(address: UInt64, size: Int) -> UInt64 {
        lock.lock()
        let completionDelivery = advance()
        let value: UInt64
        if address >= bar2Base && address < bar2Base+bar2Size {
            value = readMSIXLocked(address-bar2Base, size)
        } else if address < bar0Base || address >= bar0Base+bar0Size {
            value = 0
        } else {
            let off = UInt32(address-bar0Base)
            var v: UInt64 = 0
            for i in 0..<size { v |= UInt64(byte(off+UInt32(i))) << UInt64(8*i) }
            if Self.traceWindowsHandoff && (off == cap+0x400 || off == cap+0x410) { print("[XHCI-HANDOFF PORTSC RD] port=\(off == cap+0x400 ? 1 : 2) width=\(size) value=0x\(String(v, radix: 16))") }
            if Self.tracePortAudit && (off == cap + 4 || off == cap + 0x400 || off == cap + 0x410 || off == rtoff + 0x20 || off == rtoff + 0x38 || off == rtoff + 0x3c) { print("[XHCI-PORT-AUDIT RD] off=0x\(String(off, radix: 16)) width=\(size) value=0x\(String(v, radix: 16))") }
            if windowsAuditActive && (off < 0x20 || (off >= cap && off <= cap+0x38) || off == cap+0x400 || off == cap+0x410 || (off >= xcap && off < xcap+0x10)) { auditRead("MMIO", off, size, v) }
            if secondResetTraceActive && (off == cap + 4 || off == cap + 0x400 || off == rtoff + 0x20 || off == rtoff + 0x38 || off == rtoff + 0x3C) {
                traceSecondReset("RD off=0x\(String(off, radix: 16)) width=\(size) value=0x\(String(v, radix: 16))")
            }
            value = v
        }
        lock.unlock()
        send(completionDelivery)
        return value
    }
    func writeMMIO(address: UInt64, value: UInt64, size: Int) {
        var d:Delivery?; lock.lock(); d = advance()
        if address >= bar2Base && address < bar2Base+bar2Size { writeMSIXLocked(address-bar2Base,value,size); d=prepareMSILocked(); lock.unlock(); send(d); return }
        guard address >= bar0Base && address < bar0Base+bar0Size && size == 4 else { lock.unlock(); return }; let o=UInt32(address-bar0Base), w=UInt32(truncatingIfNeeded:value)
        switch o {
        case cap: if w & hcrst != 0 { if windowsAuditArmed && !windowsAuditActive { windowsAuditArmed = false; windowsAuditActive = true; windowsAuditReads.removeAll(); print("[XHCI-WINDOWS-AUDIT] first post-handoff HCRST entered") } else if windowsAuditActive { windowsAuditActive = false; windowsAuditComplete = true; print("[XHCI-WINDOWS-AUDIT] capture complete at next HCRST") }; reset(); trace(o,w,"USBCMD HCRST=1; controller reset entered") } else { usbcmd=w & 0xD; if usbcmd&1 != 0 { usbsts &= ~halted } else { usbsts |= halted }; trace(o,w,"USBCMD RunStop=\(usbcmd&1)") }
        case cap+4:
            let old = usbsts; usbsts &= ~(w & 0x1C); trace(o,w,"USBSTS W1C")
            if secondResetTraceActive { traceSecondReset("WR USBSTS old=0x\(String(old, radix: 16)) write=0x\(String(w, radix: 16)) new=0x\(String(usbsts, radix: 16))") }
        case cap+8: trace(o,w,"PAGESIZE read-only; ignored")
        case cap+0x14: dnctrl=w; trace(o,w,"DNCTRL")
        case cap+0x18: crcr=(crcr & 0xffffffff00000000)|UInt64(w); trace(o,w,"CRCR low base=0x\(String(crcr & ~UInt64(0x3f),radix:16)) RCS=\(crcr&1)")
        case cap+0x1C: crcr=(crcr & 0xffffffff)|UInt64(w)<<32; trace(o,w,"CRCR high")
        case cap+0x30: dcbaap=(dcbaap & 0xffffffff00000000)|UInt64(w & 0xffffffc0); trace(o,w,"DCBAAP low")
        case cap+0x34: dcbaap=(dcbaap & 0xffffffff)|UInt64(w)<<32; trace(o,w,"DCBAAP high")
        case cap+0x38: configSlots=w&255; trace(o,w,"CONFIG MaxSlotsEn=\(configSlots)")
        case rtoff+0x20:
            let old = iman; iman=(iman & ~2)|(w&2); if w&1 != 0 { iman &= ~1 }; trace(o,w,"IMAN IE=\((iman&2) != 0 ? 1:0)"); if Self.tracePortAudit { print("[XHCI-PORT-AUDIT IMAN] write=0x\(String(w, radix: 16)) now=0x\(String(iman, radix: 16))") }
            if secondResetTraceActive { traceSecondReset("WR IMAN old=0x\(String(old, radix: 16)) write=0x\(String(w, radix: 16)) new=0x\(String(iman, radix: 16))") }
        case rtoff+0x24: imod=w; trace(o,w,"IMOD")
        case rtoff+0x28: erstsz=w&0xffff; trace(o,w,"ERSTSZ=\(erstsz)")
        case rtoff+0x30: erstba=(erstba & 0xffffffff00000000)|UInt64(w&0xffffffc0); trace(o,w,"ERSTBA low")
        case rtoff+0x34: erstba=(erstba & 0xffffffff)|UInt64(w)<<32; trace(o,w,"ERSTBA high")
        case rtoff+0x38:
            let old = erdp; erdp=(erdp & 0xffffffff00000000)|UInt64(w&0xfffffff0); trace(o,w,"ERDP low"); if Self.tracePortAudit { print("[XHCI-PORT-AUDIT ERDP] write=0x\(String(w, radix: 16)) now=0x\(String(erdp, radix: 16)) EHB=\((w & 8) != 0 ? 1 : 0)") }
            if secondResetTraceActive { traceSecondReset("WR ERDP old=0x\(String(old, radix: 16)) write=0x\(String(w, radix: 16)) new=0x\(String(erdp, radix: 16))") }
        case rtoff+0x3C: erdp=(erdp & 0xffffffff)|UInt64(w)<<32; trace(o,w,"ERDP high"); if Self.tracePortAudit { print("[XHCI-PORT-AUDIT ERDP] write=0x\(String(w, radix: 16)) now=0x\(String(erdp, radix: 16))") }
        case dboff:
            if secondResetTraceActive { traceSecondReset("WR Doorbell0 raw=0x\(String(w, radix: 16))") }
            if ep0TraceActive { traceEP0("doorbell index=0 slot=0 raw=0x\(String(w, radix: 16)) target=\(w & 0xFF) stream=\(w >> 16)") }
            trace(o,w,"Doorbell 0 target=\(w&255)")
            if (w & 0xFF) == 0 {
                processCommandRingLocked()
                if d == nil { d = prepareMSILocked() }
            }
        case dboff+4...dboff+0xFF:
            let slot = (o - dboff) / 4, target = w & 0xFF
            print("🔔 FluxXHCI DOORBELL: slot=\(slot) target=\(target) stream=\(w >> 16) raw=0x\(String(w, radix: 16))")
            if ep0TraceActive {
                traceEP0("doorbell index=\(slot) slot=\(slot) raw=0x\(String(w, radix: 16)) target=\(target) stream=\(w >> 16)")
                if slot == 1 && target == 1 { traceEP0ContextAndRing() }
            }
            // The sole transfer path deliberately supported so far: Slot 1,
            // EP0, standard GET_DESCRIPTOR(Device). Every other doorbell is
            // left untouched for the next evidence-led milestone.
            if slot == 1 && target == 1 { d = processEP0DeviceDescriptorLocked() ?? d }
            if slot == 1 && target == 3 { d = processEP3InterruptTransferLocked() ?? d }
            if slot == 1 && target == 5 { d = processEP5InterruptTransferLocked() ?? d }
        case cap+0x400, cap+0x410: writePort(Int((o-(cap+0x400))/0x10),w)
        default: break
        }
        let portEventDelivery = postPortEventsLocked()
        if d == nil { d = portEventDelivery }
        lock.unlock(); send(d)
    }

    private func pciByte(_ o:Int)->UInt8 { guard o >= 0 && o < 256 else{return 0}; let v:UInt32; switch o { case 0x10...0x13:v=bar0Sizing ? 0xffff0000:UInt32(bar0Base); case 0x18...0x1b:v=bar2Sizing ? 0xfffff000:UInt32(bar2Base); case Int(Self.msixCap+2)...Int(Self.msixCap+3):v=UInt32(msixControl); return UInt8((v >> UInt32((o-Int(Self.msixCap+2))*8))&255); default:return config[o] }; return UInt8((v >> UInt32((o&3)*8))&255) }
    private func byte(_ o:UInt32)->UInt8 { let v:UInt32; switch o & ~3 { case 0: v=0x01100040; case 4:v=0x02000102; case 8,12:v=0; case 0x10:v=(xcap/4)<<16; case 0x14:v=dboff; case 0x18:v=rtoff; case cap:v=usbcmd; case cap+4:v=usbsts; case cap+8:v=1; case cap+0x14:v=dnctrl; case cap+0x18:v=UInt32(crcr); case cap+0x1c:v=UInt32(crcr>>32); case cap+0x30:v=UInt32(dcbaap); case cap+0x34:v=UInt32(dcbaap>>32); case cap+0x38:v=configSlots; case cap+0x400:v=portSC(0); case cap+0x410:v=portSC(1); case rtoff+0x20:v=iman; case rtoff+0x24:v=imod; case rtoff+0x28:v=erstsz; case rtoff+0x30:v=UInt32(erstba); case rtoff+0x34:v=UInt32(erstba>>32); case rtoff+0x38:v=UInt32(erdp); case rtoff+0x3c:v=UInt32(erdp>>32); case xcap:v=0x02000002; case xcap+4:v=0x20425355; case xcap+8:v=0x00000201; default:v=0 }; return UInt8((v >> ((o&3)*8))&255) }
    private func portSC(_ n:Int)->UInt32 { guard ports[n].connected else { return (4 << 5) | (1 << 9) }; var v:UInt32=1 | (1 << 9); if ports[n].enabled {v|=2|1<<10} else {v|=7<<5}; if ports[n].resetDeadline != nil {v|=1<<4}; return v|ports[n].changes }
    private func writePort(_ n:Int,_ w:UInt32) {
        let old = portSC(n)
        if Self.traceSecondReset && n == 0 && secondResetTraceArmed && !secondResetTraceActive && w & (1 << 4) != 0 {
            secondResetTraceArmed = false; secondResetTraceActive = true; secondResetTraceSequence = 0
            traceSecondReset("BEGIN Port1 second reset before=0x\(String(old, radix: 16)) PR-write=0x\(String(w, radix: 16))")
        }
        let w1c:UInt32=(1<<17)|(1<<18)|(1<<21)
        ports[n].changes &= ~(w&w1c)
        if w&(1<<4) != 0 && ports[n].resetDeadline == nil {
            ports[n].enabled=false; ports[n].resetDeadline=DispatchTime.now().uptimeNanoseconds+50_000; ports[n].eventQueued=false
            print("🔎 FluxXHCI PORT\(n+1): PR=1 reset entered")
        }
        let new=portSC(n)
        if secondResetTraceActive && n == 0 { traceSecondReset("WR PORTSC1 old=0x\(String(old, radix: 16)) write=0x\(String(w, radix: 16)) new=0x\(String(new, radix: 16))") }
        if Self.tracePortAudit { print("[XHCI-PORT-AUDIT PORTSC WR] port=\(n+1) old=0x\(String(old, radix: 16)) write=0x\(String(w, radix: 16)) new=0x\(String(new, radix: 16))") }
        trace(cap+0x400+UInt32(n*0x10),w,"PORTSC W1C CSC/PEC/PRC")
    }
    private func reset() { usbcmd=hcrst; usbsts=halted|cnr; dnctrl=0;crcr=0;dcbaap=0;configSlots=0;commandDequeue=0;commandCycle=1;slots=Array(repeating: Slot(), count: Self.implementedSlots);iman=0;imod=0;erstsz=0;erstba=0;erdp=0;eventIndex=0;eventCycle=1; for n in ports.indices { ports[n]=Port() }; resetDeadline=DispatchTime.now().uptimeNanoseconds+1_000_000 }
    private func advance() -> Delivery? {
        let now = DispatchTime.now().uptimeNanoseconds
        if let d = resetDeadline, now >= d {
            resetDeadline = nil; usbcmd = 0; usbsts = halted
            print("🔄 FluxXHCI: controller reset complete (HCRST=0 CNR=0 HCHalted=1)")
            if windowsAuditActive { print("[XHCI-WINDOWS-AUDIT RESET] USBCMD=0x\(String(usbcmd,radix:16)) USBSTS=0x\(String(usbsts,radix:16))") }
        }
        var delivery: Delivery?
        for n in ports.indices {
            guard let deadline = ports[n].resetDeadline, now >= deadline else { continue }
            // Make PRC visible only after its corresponding event/interrupt is pending.
            ports[n].resetDeadline = nil
            ports[n].enabled = true
            ports[n].changes |= 1 << 21
            ports[n].eventQueued = false
            print("🔎 FluxXHCI PORT\(n+1): reset complete CCS=1 PED=1 PR=0 PRC=1")
            if secondResetTraceActive && n == 0 { traceSecondReset("RESET-COMPLETE PORTSC1=0x\(String(portSC(n), radix: 16))") }
            guard usbcmd & 1 != 0, erstsz == 1, erstba != 0, iman & 2 != 0,
                  postPortEvent(n + 1) else { continue }
            ports[n].eventQueued = true
            print("🔎 FluxXHCI PORT\(n+1): reset completion event posted before PORTSC readback")
            if secondResetTraceActive && n == 0 { traceSecondReset("RESET-EVENT queued IMAN=0x\(String(iman, radix: 16)) USBSTS=0x\(String(usbsts, radix: 16))") }
            delivery = prepareMSILocked()
        }
        return delivery
    }
    private func postPortEventsLocked()->Delivery? {
        guard usbcmd&1 != 0, erstsz==1, erstba != 0, iman&2 != 0 else { return nil }
        // Windows must observe an actual disconnected-to-connected transition.
        // This one-shot experiment attaches only Port 1 after its complete
        // Windows-owned command/event/interrupt infrastructure is ready.
        if windowsAuditActive, !ports[0].connected, dcbaap != 0, crcr != 0,
           configSlots != 0, msixControl & 0x8000 != 0 {
            ports[0].connected = true
            ports[0].changes |= 1 << 17
            ports[0].eventQueued = false
            print("🔎 FluxXHCI PORT1: fresh physical attach CCS=0->1 CSC=1")
            if Self.tracePortAudit { print("[XHCI-PORT-AUDIT ATTACH] port=1 before=0x80 after=0x\(String(portSC(0), radix: 16))") }
        }
        for n in ports.indices where ports[n].changes != 0 && !ports[n].eventQueued { guard postPortEvent(n+1) else{return nil}; ports[n].eventQueued=true }
        return prepareMSILocked()
    }
    private func postPortEvent(_ port:Int)->Bool { guard let e=ptr(erstba) else {print("⚠️ FluxXHCI: invalid ERSTBA");return false}; let base=UInt64(littleEndian:e.loadUnaligned(as:UInt64.self)),count=UInt16(littleEndian:e.advanced(by:8).loadUnaligned(as:UInt16.self)); guard count>0,eventIndex<count,let t=ptr(base+UInt64(eventIndex)*16) else {print("⚠️ FluxXHCI: invalid ERST segment base=0x\(String(base,radix:16)) count=\(count)");return false}; let postedIndex=eventIndex, parameter=UInt64(port<<24),status:UInt32=0,control=(UInt32(34)<<10)|eventCycle;t.storeBytes(of:parameter.littleEndian,as:UInt64.self);t.advanced(by:8).storeBytes(of:status.littleEndian,as:UInt32.self);t.advanced(by:12).storeBytes(of:control.littleEndian,as:UInt32.self);print("🔎 FluxXHCI EVENT: Port Status Change port=\(port) ERST=0x\(String(base,radix:16)) index=\(eventIndex) cycle=\(eventCycle)"); if Self.tracePortAudit { print("[XHCI-PORT-AUDIT EVENT] port=\(port) parameter=0x\(String(parameter, radix: 16)) status=0x\(String(status, radix: 16)) control=0x\(String(control, radix: 16)) IMAN-before=0x\(String(iman, radix: 16)) USBSTS=0x\(String(usbsts, radix: 16))") };eventIndex+=1;if eventIndex==count {eventIndex=0;eventCycle^=1};iman|=1;usbsts|=1<<4;pba|=1;if secondResetTraceActive && port == 1 { traceSecondReset("EVENT PortStatusChange port=1 erst=0x\(String(base, radix: 16)) index=\(postedIndex) cycle=\(control & 1) IMAN=0x\(String(iman, radix: 16)) USBSTS=0x\(String(usbsts, radix: 16))") };if Self.tracePortAudit { print("[XHCI-PORT-AUDIT EVENT] IMAN-after=0x\(String(iman, radix: 16)) USBSTS=0x\(String(usbsts, radix: 16))") };return true }
    
    /// Consumes only the commands currently proven by EDK2: Enable Slot and
    /// Address Device. A mismatched-cycle or unsupported TRB remains queued.
    /// A mismatched-cycle or unsupported TRB remains unconsumed.
    private func processCommandRingLocked() {
        guard usbcmd & 1 != 0 else { print("⚠️ FluxXHCI CMD: Doorbell while controller stopped"); return }
        if commandDequeue == 0 {
            commandDequeue = crcr & ~UInt64(0x3F)
            commandCycle = UInt32(crcr & 1)
        }
        guard commandDequeue != 0, let trb = ptr(commandDequeue) else {
            print("⚠️ FluxXHCI CMD: invalid command ring GPA=0x\(String(commandDequeue, radix: 16))")
            return
        }
        let parameter = UInt64(littleEndian: trb.loadUnaligned(as: UInt64.self))
        let status = UInt32(littleEndian: trb.advanced(by: 8).loadUnaligned(as: UInt32.self))
        let control = UInt32(littleEndian: trb.advanced(by: 12).loadUnaligned(as: UInt32.self))
        let cycle = control & 1
        let type = (control >> 10) & 0x3F
        print("🔎 FluxXHCI CMD: TRB=0x\(String(commandDequeue, radix: 16)) type=\(type) cycle=\(cycle) parameter=0x\(String(parameter, radix: 16)) status=0x\(String(status, radix: 16)) control=0x\(String(control, radix: 16))")
        if secondResetTraceActive {
            traceSecondReset("NEXT-COMMAND trb=0x\(String(commandDequeue, radix: 16)) type=\(type) cycle=\(cycle) slot=\((control >> 24) & 0xFF) endpoint=\((control >> 16) & 0x1F) control=0x\(String(control, radix: 16)) parameter=0x\(String(parameter, radix: 16))")
            traceSecondResetContexts()
            secondResetTraceActive = false
            print("[XHCI-SECOND-RESET] complete at first command TRB")
        }
        guard cycle == commandCycle else {
            print("⚠️ FluxXHCI CMD: cycle mismatch expected=\(commandCycle) actual=\(cycle); not consumed")
            return
        }
        if type == 15 && ep0TraceActive {
            traceEP0ContextAndRing()
            traceEP0("Stop Endpoint command=0x\(String(commandDequeue, radix: 16)) raw=\(String(format: "%08x,%08x,%08x,%08x", UInt32(truncatingIfNeeded: parameter), UInt32(truncatingIfNeeded: parameter >> 32), status, control)) slot=\((control >> 24) & 0xFF) endpoint=\((control >> 16) & 0x1F) suspend=\(((control >> 23) & 1))")
            ep0TraceActive = false
        }
        // Link TRB is the one ring-management TRB allowed here, solely to
        // reach a following Enable Slot command without interpreting it.
        if type == 6 {
            commandDequeue = parameter & ~UInt64(0xF)
            if (control & 2) != 0 { commandCycle ^= 1 }
            print("🔎 FluxXHCI CMD: Link TRB -> 0x\(String(commandDequeue, radix: 16)) cycle=\(commandCycle)")
            processCommandRingLocked()
            return
        }
        guard type == 9 || type == 10 || type == 11 || type == 12 || type == 13 || type == 14 || type == 16 else {
            print("⚠️ FluxXHCI CMD: unsupported command type=\(type); not consumed")
            return
        }
        if type == 14 {
            let slotID = UInt8((control >> 24) & 0xFF)
            let endpointID = UInt8((control >> 16) & 0x1F)
            let tsp = (control & (1 << 9)) != 0
            let rawDW0 = UInt32(truncatingIfNeeded: parameter)
            let rawDW1 = UInt32(truncatingIfNeeded: parameter >> 32)
            print("[XHCI-CMD-TRB] Reset Endpoint GPA=0x\(String(commandDequeue, radix: 16)) raw=\(String(format: "%08x,%08x,%08x,%08x", rawDW0, rawDW1, status, control)) type=\(type) cycle=\(cycle) slot=\(slotID) ep=\(endpointID) tsp=\(tsp ? 1 : 0)")
            let index = Int(slotID) - 1
            guard slotID >= 1, slotID <= configSlots, index >= 0, index < slots.count, slots[index].enabled else {
                print("⚠️ FluxXHCI CMD: Reset Endpoint invalid slotID=\(slotID); returning TRB Error")
                let completedTRB = commandDequeue
                commandDequeue += 16
                _ = postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID, code: 5)
                return
            }
            guard endpointID == 1 || endpointID == 3 || endpointID == 5 else {
                print("⚠️ FluxXHCI CMD: Reset Endpoint unsupported endpointID=\(endpointID); returning TRB Error")
                let completedTRB = commandDequeue
                commandDequeue += 16
                _ = postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID, code: 5)
                return
            }
            guard dcbaap != 0, let dcbaa = ptr(dcbaap, bytes: Int(slotID + 1) * 8) else {
                print("⚠️ FluxXHCI CMD: Reset Endpoint invalid DCBAAP")
                return
            }
            let outputGPA = UInt64(littleEndian: dcbaa.advanced(by: Int(slotID) * 8).loadUnaligned(as: UInt64.self)) & ~UInt64(0x3F)
            guard let output = ptr(outputGPA, bytes: 0x200) else {
                print("⚠️ FluxXHCI CMD: Reset Endpoint invalid output context GPA=0x\(String(outputGPA, radix: 16))")
                return
            }
            let epCtx = output.advanced(by: Int(endpointID) * 0x20)
            var epDW0 = UInt32(littleEndian: epCtx.loadUnaligned(as: UInt32.self))
            let currentEPState = epDW0 & 7
            let epDW2 = UInt32(littleEndian: epCtx.advanced(by: 8).loadUnaligned(as: UInt32.self))
            let epDW3 = UInt32(littleEndian: epCtx.advanced(by: 12).loadUnaligned(as: UInt32.self))
            let currentTRDP = (UInt64(epDW2) | UInt64(epDW3 & 0xFFFFFFF0) << 32) & ~UInt64(0xF)
            let currentDCS = epDW2 & 1

            print("[XHCI-RESET-EP] before slot=\(slotID) ep=\(endpointID) state=\(currentEPState) trdp=0x\(String(currentTRDP, radix: 16)) dcs=\(currentDCS)")

            guard currentEPState == 2 else { // Must be Halted
                print("⚠️ FluxXHCI CMD: Reset Endpoint EP state not Halted (state=\(currentEPState)); returning Context State Error (19)")
                let completedTRB = commandDequeue
                commandDequeue += 16
                _ = postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID, code: 19)
                return
            }

            // Transition Endpoint State from Halted (2) to Stopped (3)
            // xHCI §4.6.8: TR Dequeue Pointer and DCS are preserved.
            epDW0 = (epDW0 & ~0x7) | 3 // Stopped = 3
            epCtx.storeBytes(of: epDW0.littleEndian, as: UInt32.self)

            print("[XHCI-RESET-EP] after slot=\(slotID) ep=\(endpointID) state=\(epDW0 & 7) trdp=0x\(String(currentTRDP, radix: 16)) dcs=\(currentDCS)")

            let completedTRB = commandDequeue
            commandDequeue += 16
            guard postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID, code: 1) else {
                epCtx.storeBytes(of: UInt32((epDW0 & ~0x7) | 2).littleEndian, as: UInt32.self)
                commandDequeue = completedTRB
                return
            }
            print("🔎 FluxXHCI CMD: Reset Endpoint success slot=\(slotID) ep=\(endpointID) dequeue=0x\(String(commandDequeue, radix: 16))")
            return
        }
        if type == 16 {
            let slotID = UInt8((control >> 24) & 0xFF)
            let endpointID = UInt8((control >> 16) & 0x1F)
            let sct = UInt8((parameter >> 1) & 0x7)
            let dcs = UInt32(parameter & 1)
            let newTRDP = parameter & ~UInt64(0xF)
            let rawDW0 = UInt32(truncatingIfNeeded: parameter)
            let rawDW1 = UInt32(truncatingIfNeeded: parameter >> 32)
            print("[XHCI-CMD-TRB] Set TR Dequeue Pointer GPA=0x\(String(commandDequeue, radix: 16)) raw=\(String(format: "%08x,%08x,%08x,%08x", rawDW0, rawDW1, status, control)) type=\(type) cycle=\(cycle) slot=\(slotID) ep=\(endpointID) newTRDP=0x\(String(newTRDP, radix: 16)) dcs=\(dcs) sct=\(sct)")
            let index = Int(slotID) - 1
            guard slotID >= 1, slotID <= configSlots, index >= 0, index < slots.count, slots[index].enabled else {
                print("⚠️ FluxXHCI CMD: Set TR Dequeue Pointer invalid slotID=\(slotID); returning TRB Error")
                let completedTRB = commandDequeue
                commandDequeue += 16
                _ = postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID, code: 5)
                return
            }
            guard endpointID == 1 || endpointID == 3 || endpointID == 5 else {
                print("⚠️ FluxXHCI CMD: Set TR Dequeue Pointer unsupported endpointID=\(endpointID); returning TRB Error")
                let completedTRB = commandDequeue
                commandDequeue += 16
                _ = postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID, code: 5)
                return
            }
            guard dcbaap != 0, let dcbaa = ptr(dcbaap, bytes: Int(slotID + 1) * 8) else {
                print("⚠️ FluxXHCI CMD: Set TR Dequeue Pointer invalid DCBAAP")
                return
            }
            let outputGPA = UInt64(littleEndian: dcbaa.advanced(by: Int(slotID) * 8).loadUnaligned(as: UInt64.self)) & ~UInt64(0x3F)
            guard let output = ptr(outputGPA, bytes: 0x200) else {
                print("⚠️ FluxXHCI CMD: Set TR Dequeue Pointer invalid output context GPA=0x\(String(outputGPA, radix: 16))")
                return
            }
            let epCtx = output.advanced(by: Int(endpointID) * 0x20)
            let epDW0 = UInt32(littleEndian: epCtx.loadUnaligned(as: UInt32.self))
            let currentEPState = epDW0 & 7
            let oldDW2 = UInt32(littleEndian: epCtx.advanced(by: 8).loadUnaligned(as: UInt32.self))
            let oldDW3 = UInt32(littleEndian: epCtx.advanced(by: 12).loadUnaligned(as: UInt32.self))
            let oldTRDP = (UInt64(oldDW2) | UInt64(oldDW3 & 0xFFFFFFF0) << 32) & ~UInt64(0xF)
            let oldDCS = oldDW2 & 1

            print("[XHCI-SET-TRDP] before slot=\(slotID) ep=\(endpointID) state=\(currentEPState) trdp=0x\(String(oldTRDP, radix: 16)) dcs=\(oldDCS)")

            guard currentEPState == 3 || currentEPState == 4 else { // Must be Stopped (3) or Error (4) per xHCI §4.6.9
                print("⚠️ FluxXHCI CMD: Set TR Dequeue Pointer EP state not Stopped/Error (state=\(currentEPState)); returning Context State Error (19)")
                let completedTRB = commandDequeue
                commandDequeue += 16
                _ = postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID, code: 19)
                return
            }

            // Update TR Dequeue Pointer and DCS in Endpoint Context DW2 and DW3.
            // EP State remains Stopped (3).
            let newDW2 = UInt32(truncatingIfNeeded: newTRDP) | dcs
            let newDW3 = (oldDW3 & 0xF) | UInt32(truncatingIfNeeded: newTRDP >> 32)
            epCtx.advanced(by: 8).storeBytes(of: newDW2.littleEndian, as: UInt32.self)
            epCtx.advanced(by: 12).storeBytes(of: newDW3.littleEndian, as: UInt32.self)

            print("[XHCI-SET-TRDP] after slot=\(slotID) ep=\(endpointID) state=\(currentEPState) trdp=0x\(String(newTRDP, radix: 16)) dcs=\(dcs)")

            let completedTRB = commandDequeue
            commandDequeue += 16
            guard postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID, code: 1) else {
                epCtx.advanced(by: 8).storeBytes(of: oldDW2.littleEndian, as: UInt32.self)
                epCtx.advanced(by: 12).storeBytes(of: oldDW3.littleEndian, as: UInt32.self)
                commandDequeue = completedTRB
                return
            }
            print("🔎 FluxXHCI CMD: Set TR Dequeue Pointer success slot=\(slotID) ep=\(endpointID) dequeue=0x\(String(commandDequeue, radix: 16))")
            return
        }
        if type == 10 {
            let slotID = UInt8((control >> 24) & 0xFF)
            let index = Int(slotID) - 1
            print("[XHCI-CMD-TRB] Disable Slot GPA=0x\(String(commandDequeue, radix: 16)) raw=\(String(format: "%08x,%08x,%08x,%08x", UInt32(truncatingIfNeeded: parameter), UInt32(truncatingIfNeeded: parameter >> 32), status, control)) type=\(type) cycle=\(cycle) slot=\(slotID)")
            guard slotID >= 1, slotID <= configSlots, index >= 0, index < slots.count else {
                print("⚠️ FluxXHCI CMD: Disable Slot invalid slotID=\(slotID); returning TRB Error")
                let completedTRB = commandDequeue
                commandDequeue += 16
                _ = postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID, code: 5)
                return
            }
            guard slots[index].enabled else {
                print("⚠️ FluxXHCI CMD: Disable Slot slot=\(slotID) not enabled; returning Slot Not Enabled Error")
                let completedTRB = commandDequeue
                commandDequeue += 16
                _ = postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID, code: 9)
                return
            }
            let oldSlot = slots[index]
            print("[XHCI-DISABLE-SLOT] before slot=\(slotID) enabled=\(oldSlot.enabled) defaultContextReady=\(oldSlot.defaultContextReady) addressed=\(oldSlot.addressed) usbAddress=\(oldSlot.usbAddress) port=\(oldSlot.port.map(String.init) ?? "nil")")
            slots[index] = Slot()
            print("[XHCI-DISABLE-SLOT] after slot=\(slotID) enabled=\(slots[index].enabled) defaultContextReady=\(slots[index].defaultContextReady) addressed=\(slots[index].addressed) usbAddress=\(slots[index].usbAddress) port=\(slots[index].port.map(String.init) ?? "nil")")
            let completedTRB = commandDequeue
            commandDequeue += 16
            guard postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID, code: 1) else {
                slots[index] = oldSlot
                commandDequeue = completedTRB
                return
            }
            print("🔎 FluxXHCI CMD: Disable Slot success slot=\(slotID) dequeue=0x\(String(commandDequeue, radix: 16))")
            return
        }
        if type == 12 || type == 13 {
            let cmdName = type == 12 ? "Configure Endpoint" : "Evaluate Context"
            let slotID = UInt8((control >> 24) & 0xFF)
            let deconfigure = (control & (1 << 9)) != 0
            let rawDW0 = UInt32(truncatingIfNeeded: parameter)
            let rawDW1 = UInt32(truncatingIfNeeded: parameter >> 32)
            print("[XHCI-CMD-TRB] \(cmdName) GPA=0x\(String(commandDequeue, radix: 16)) raw=\(String(format: "%08x,%08x,%08x,%08x", rawDW0, rawDW1, status, control)) type=\(type) cycle=\(cycle) slot=\(slotID) dc=\(deconfigure ? 1 : 0) inputGPA=0x\(String(parameter, radix: 16))")
            let index = Int(slotID) - 1
            guard !deconfigure, index >= 0, index < slots.count,
                  slots[index].enabled, slots[index].defaultContextReady,
                  parameter & 0xF == 0,
                  let input = ptr(parameter, bytes: 0x400),
                  dcbaap != 0, let dcbaa = ptr(dcbaap, bytes: Int(slotID + 1) * 8),
                  let output = ptr(UInt64(littleEndian: dcbaa.advanced(by: Int(slotID) * 8).loadUnaligned(as: UInt64.self)) & ~UInt64(0x3F), bytes: 0x400),
                  configureEndpointOutput(input: input, output: output, slotID: slotID) else {
                print("⚠️ FluxXHCI CMD: \(cmdName) validation failed slot=\(slotID) dc=\(deconfigure ? 1 : 0) input=0x\(String(parameter, radix: 16)); not consumed")
                return
            }
            let completedTRB = commandDequeue
            commandDequeue += 16
            guard postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID) else {
                commandDequeue = completedTRB
                return
            }
            print("🔎 FluxXHCI CMD: \(cmdName) success slot=\(slotID) dc=0 input=0x\(String(parameter, radix: 16)) dequeue=0x\(String(commandDequeue, radix: 16))")
            if Self.traceSecondReset {
                secondResetTraceArmed = true
                print("[XHCI-SECOND-RESET] armed after \(cmdName) completion")
            }
            return
        }
        if type == 11 {
            let slotID = UInt8((control >> 24) & 0xFF)
            let bsr = (control & (1 << 9)) != 0   // Block Set Address
            let index = Int(slotID) - 1
            guard index >= 0, index < slots.count, slots[index].enabled,
                  (bsr ? !slots[index].defaultContextReady : slots[index].defaultContextReady && !slots[index].addressed),
                  parameter & 0xF == 0,
                  dcbaap != 0, let dcbaa = ptr(dcbaap, bytes: Int(slotID + 1) * 8),
                  UInt64(littleEndian: dcbaa.advanced(by: Int(slotID) * 8).loadUnaligned(as: UInt64.self)) & ~UInt64(0x3F) != 0,
                  let input = ptr(parameter, bytes: 0x80),
                  (UInt32(littleEndian: input.advanced(by: 0x24).loadUnaligned(as: UInt32.self)) >> 16) & 0xFF >= 1,
                  (UInt32(littleEndian: input.advanced(by: 0x24).loadUnaligned(as: UInt32.self)) >> 16) & 0xFF <= UInt32(ports.count) else {
                print("⚠️ FluxXHCI CMD: Address Device validation failed slot=\(slotID) bsr=\(bsr ? 1 : 0) input=0x\(String(parameter, radix: 16)) DCBAAP=0x\(String(dcbaap, radix: 16)); not consumed")
                return
            }
            let outputGPA = UInt64(littleEndian: dcbaa.advanced(by: Int(slotID) * 8).loadUnaligned(as: UInt64.self)) & ~UInt64(0x3F)
            if Self.traceAddressAudit || windowsAuditActive { traceAddressContexts(inputGPA: parameter, outputGPA: outputGPA, slotID: slotID, bsr: bsr, cycle: cycle, phase: "before") }
            let rootPort = Int((UInt32(littleEndian: input.advanced(by: 0x24).loadUnaligned(as: UInt32.self)) >> 16) & 0xFF)
            guard !slots.enumerated().contains(where: { $0.offset != index && $0.element.port == rootPort }) else {
                print("⚠️ FluxXHCI CMD: Address Device root port \(rootPort) already assigned; not consumed")
                return
            }
            guard populateAddressDeviceOutput(input: input, outputGPA: outputGPA, bsr: bsr, slots: slots) else {
                print("⚠️ FluxXHCI CMD: Address Device output-context setup failed bsr=\(bsr ? 1 : 0); not consumed")
                return
            }
            // For BSR=0: assign a nonzero USB device address unique across active slots.
            // xHCI spec §4.6.5: controller assigns address 1..127; 0 is reserved.
            var assignedAddress: UInt8 = 0
            if !bsr {
                let usedAddresses = Set(slots.map { $0.usbAddress })
                guard let addr = (UInt8(1)...127).first(where: { !usedAddresses.contains($0) }) else {
                    print("⚠️ FluxXHCI CMD: Address Device no free USB address; not consumed")
                    return
                }
                assignedAddress = addr
                // Write assigned address into Output Slot Context DW3 [7:0]
                guard let output = ptr(outputGPA, bytes: 0x20) else {
                    print("⚠️ FluxXHCI CMD: Address Device cannot access output context; not consumed")
                    return
                }
                var slotDW3 = UInt32(littleEndian: output.advanced(by: 12).loadUnaligned(as: UInt32.self))
                // USB Device Address in DW3 [7:0], Slot State = Addressed (2) in DW3 [31:27]
                slotDW3 = (slotDW3 & ~(0xFF | (0x1F << 27))) | UInt32(assignedAddress) | (UInt32(2) << 27)
                output.advanced(by: 12).storeBytes(of: slotDW3.littleEndian, as: UInt32.self)
                print("[XHCI-ADDRESS-BSR0] slot=\(slotID) assigned USB address=\(assignedAddress) slotState=2 (Addressed)")
            }
            let completedTRB = commandDequeue
            commandDequeue += 16
            if bsr {
                slots[index].defaultContextReady = true
                slots[index].port = rootPort
                slots[index].usbAddress = 0
            } else {
                slots[index].addressed = true
                slots[index].usbAddress = assignedAddress
            }
            guard postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID) else {
                if bsr {
                    slots[index].defaultContextReady = false
                    slots[index].port = nil
                } else {
                    slots[index].addressed = false
                    slots[index].usbAddress = 0
                }
                commandDequeue = completedTRB
                return
            }
            if Self.traceAddressAudit || windowsAuditActive { traceAddressContexts(inputGPA: parameter, outputGPA: outputGPA, slotID: slotID, bsr: bsr, cycle: cycle, phase: "after") }
            print("🔎 FluxXHCI CMD: Address Device success slot=\(slotID) bsr=\(bsr ? 1 : 0) port=\(rootPort) usbAddr=\(assignedAddress) input=0x\(String(parameter, radix: 16)) dequeue=0x\(String(commandDequeue, radix: 16))")
            if Self.traceEP0Stop {
                ep0TraceActive = true
                ep0TraceSequence = 0
                traceEP0("Address Device completion slot=\(slotID) bsr=\(bsr ? 1 : 0) command=0x\(String(completedTRB, radix: 16)) output=0x\(String(outputGPA, radix: 16))")
            }
            return
        }
        guard let index = slots.firstIndex(where: { !$0.enabled }) else {
            print("⚠️ FluxXHCI CMD: Enable Slot has no free slot; not completed")
            return
        }
        let slotID = UInt8(index + 1)
        slots[index].enabled = true
        let completedTRB = commandDequeue
        commandDequeue += 16
        guard postCommandCompletionLocked(commandTRB: completedTRB, slotID: slotID) else {
            // Preserve the command until a valid event ring can accept it.
            slots[index].enabled = false
            commandDequeue = completedTRB
            return
        }
        print("🔎 FluxXHCI CMD: Enable Slot success slot=\(slotID) dequeue=0x\(String(commandDequeue, radix: 16))")
    }

    /// xHCI CSZ=0 means 32-byte contexts.
    /// BSR=1: Slot State=Default, USB Address=0, EP0=Running (no wire SET_ADDRESS).
    /// BSR=0: copies same fields; caller writes Slot State=Addressed + assigned USB address after.
    private func populateAddressDeviceOutput(input: UnsafeMutableRawPointer, outputGPA: UInt64, bsr: Bool, slots: [Slot]) -> Bool {
        guard let output = ptr(outputGPA, bytes: 0x40) else { return false }
        let addFlags = UInt32(littleEndian: input.advanced(by: 4).loadUnaligned(as: UInt32.self))
        guard addFlags & 0x3 == 0x3 else { return false } // Slot Context + EP0 both required

        // Dump input contexts for audit
        let inputSlotWords = (0..<8).map { UInt32(littleEndian: input.advanced(by: 0x20 + $0 * 4).loadUnaligned(as: UInt32.self)) }
        let inputEP0Words  = (0..<8).map { UInt32(littleEndian: input.advanced(by: 0x40 + $0 * 4).loadUnaligned(as: UInt32.self)) }
        print("[XHCI-ADDRESS-AUDIT] bsr=\(bsr ? 1 : 0) InputSlot raw=\(inputSlotWords.map { String(format: "%08x", $0) }.joined(separator: ",")) speed=\((inputSlotWords[0] >> 20) & 0xF) entries=\((inputSlotWords[0] >> 27) & 0x1F) rootPort=\((inputSlotWords[1] >> 16) & 0xFF)")
        print("[XHCI-ADDRESS-AUDIT] bsr=\(bsr ? 1 : 0) InputEP0 raw=\(inputEP0Words.map { String(format: "%08x", $0) }.joined(separator: ",")) type=\((inputEP0Words[1] >> 3) & 7) mps=\((inputEP0Words[1] >> 16) & 0xFFFF) cerr=\((inputEP0Words[1] >> 1) & 3) trdp=0x\(String((UInt64(inputEP0Words[2]) | UInt64(inputEP0Words[3] & 0xFFFFFFF0) << 32) & ~UInt64(0xF), radix: 16)) dcs=\(inputEP0Words[2] & 1)")

        let inputSlot = input.advanced(by: 0x20), inputEP0 = input.advanced(by: 0x40)
        let outputSlot = output, outputEP0 = output.advanced(by: 0x20)
        for word in 0..<8 {
            outputSlot.advanced(by: word * 4).storeBytes(of: inputSlot.advanced(by: word * 4).loadUnaligned(as: UInt32.self), as: UInt32.self)
            outputEP0.advanced(by: word * 4).storeBytes(of: inputEP0.advanced(by: word * 4).loadUnaligned(as: UInt32.self), as: UInt32.self)
        }
        // For both BSR=0 and BSR=1: clear address and set state=Default temporarily.
        // Caller will overwrite DW3 with Addressed + address for BSR=0.
        var slotDW3 = UInt32(littleEndian: outputSlot.advanced(by: 12).loadUnaligned(as: UInt32.self))
        slotDW3 &= ~(0xFF | (0x1F << 27)) // Clear USB address + Slot State
        slotDW3 |= 1 << 27                 // Slot State = Default (1)
        outputSlot.advanced(by: 12).storeBytes(of: slotDW3.littleEndian, as: UInt32.self)
        // EP0 must be Running in both BSR paths
        var ep0DW0 = UInt32(littleEndian: outputEP0.loadUnaligned(as: UInt32.self))
        ep0DW0 = (ep0DW0 & ~0x7) | 1 // Endpoint State = Running
        outputEP0.storeBytes(of: ep0DW0.littleEndian, as: UInt32.self)
        return true
    }

    /// Applies only the contexts selected by a Configure Endpoint (or Evaluate Context)
    /// Input Control Context. Context index 0 is the Slot Context; indexes 1...31
    /// are Endpoint Contexts (and equal the xHCI Endpoint ID).
    private func configureEndpointOutput(input: UnsafeMutableRawPointer,
                                         output: UnsafeMutableRawPointer,
                                         slotID: UInt8) -> Bool {
        let dropFlags = UInt32(littleEndian: input.loadUnaligned(as: UInt32.self))
        let addFlags = UInt32(littleEndian: input.advanced(by: 4).loadUnaligned(as: UInt32.self))
        // Bits above context 31 and a request with no selected context are not
        // meaningful for the fixed 32-byte-context controller model.
        guard addFlags != 0 else { return false }
        guard dropFlags & 1 == 0 else { return false }

        let iccWords = (0..<8).map { UInt32(littleEndian: input.advanced(by: $0 * 4).loadUnaligned(as: UInt32.self)) }
        print("[XHCI-CONFIGURE] slot=\(slotID) drop=0x\(String(dropFlags, radix: 16)) add=0x\(String(addFlags, radix: 16))")
        print("[XHCI-CONFIGURE-AUDIT] ICC raw=\(iccWords.map { String(format: "%08x", $0) }.joined(separator: ","))")

        if addFlags & 1 != 0 {
            let inSlotWords = (0..<8).map { UInt32(littleEndian: input.advanced(by: 0x20 + $0 * 4).loadUnaligned(as: UInt32.self)) }
            print("[XHCI-CONFIGURE-AUDIT] Input Slot raw=\(inSlotWords.map { String(format: "%08x", $0) }.joined(separator: ",")) route=0x\(String(inSlotWords[0] & 0xFFFFF, radix: 16)) speed=\((inSlotWords[0] >> 20) & 0xF) entries=\((inSlotWords[0] >> 27) & 0x1F) rootPort=\((inSlotWords[1] >> 16) & 0xFF)")
        }

        for context in 1..<32 where addFlags & (UInt32(1) << UInt32(context)) != 0 {
            let src = input.advanced(by: 0x20 + context * 0x20)
            let w = (0..<8).map { UInt32(littleEndian: src.advanced(by: $0 * 4).loadUnaligned(as: UInt32.self)) }
            let inState = w[0] & 7
            let interval = (w[0] >> 16) & 0xFF
            let cerr = (w[1] >> 1) & 3
            let epType = (w[1] >> 3) & 7
            let burst = (w[1] >> 8) & 0xFF
            let mps = (w[1] >> 16) & 0xFFFF
            let trdp = (UInt64(w[2]) | (UInt64(w[3] & 0xFFFFFFF0) << 32)) & ~UInt64(0xF)
            let dcs = w[2] & 1
            let avgTRB = w[4] & 0xFFFF
            let maxESITLo = (w[4] >> 16) & 0xFFFF
            let maxESITHi = (w[0] >> 24) & 0xFF
            let maxESIT = (maxESITHi << 16) | maxESITLo
            print("[XHCI-CONFIGURE-AUDIT] Input EP context=\(context) epID=\(context) raw=\(w.map { String(format: "%08x", $0) }.joined(separator: ",")) state=\(inState) type=\(epType) mps=\(mps) burst=\(burst) interval=\(interval) cerr=\(cerr) trdp=0x\(String(trdp, radix: 16)) dcs=\(dcs) avgTRB=\(avgTRB) maxESIT=\(maxESIT)")
        }

        // Drop selected endpoint contexts first. Dropping the Slot Context is
        // invalid for Configure Endpoint and is therefore rejected instead of
        // silently destroying device state.
        for context in 1..<32 where dropFlags & (UInt32(1) << UInt32(context)) != 0 {
            let destination = output.advanced(by: context * 0x20)
            destination.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
            print("[XHCI-CONFIGURE] drop context=\(context) endpoint=\(context)")
        }

        // Capture previous Slot Context values BEFORE copying into output context
        let previousSlotDW0 = UInt32(littleEndian: output.loadUnaligned(as: UInt32.self))
        let previousSlotDW1 = UInt32(littleEndian: output.advanced(by: 4).loadUnaligned(as: UInt32.self))
        let previousSlotDW3 = UInt32(littleEndian: output.advanced(by: 12).loadUnaligned(as: UInt32.self))
        let previousAddress = previousSlotDW3 & 0xFF
        let previousState = (previousSlotDW3 >> 27) & 0x1F

        var highestContext = 0
        for context in 0..<32 where addFlags & (UInt32(1) << UInt32(context)) != 0 {
            let source = input.advanced(by: 0x20 + context * 0x20)
            let destination = output.advanced(by: context * 0x20)
            for word in 0..<8 {
                destination.advanced(by: word * 4).storeBytes(of: source.advanced(by: word * 4).loadUnaligned(as: UInt32.self), as: UInt32.self)
            }
            highestContext = max(highestContext, context)
            if context == 0 {
                // Preserve controller-owned Speed (DW0 bits 23:20) and Root Hub Port (DW1 bits 23:16)
                // if the guest Input Slot Context leaves them zero.
                var slotDW0 = UInt32(littleEndian: destination.loadUnaligned(as: UInt32.self))
                if ((slotDW0 >> 20) & 0xF) == 0 {
                    slotDW0 |= (previousSlotDW0 & (0xF << 20))
                    destination.storeBytes(of: slotDW0.littleEndian, as: UInt32.self)
                }
                var slotDW1 = UInt32(littleEndian: destination.advanced(by: 4).loadUnaligned(as: UInt32.self))
                if ((slotDW1 >> 16) & 0xFF) == 0 {
                    slotDW1 |= (previousSlotDW1 & (0xFF << 16))
                    destination.advanced(by: 4).storeBytes(of: slotDW1.littleEndian, as: UInt32.self)
                }
                // Slot State and USB Address are controller-owned. Retain the
                // Address Device result while accepting the requested slot
                // attributes from its Input Context.
                var slotDW3 = UInt32(littleEndian: destination.advanced(by: 12).loadUnaligned(as: UInt32.self))
                let newState = (addFlags & ~UInt32(3)) != 0 ? UInt32(3) : previousState
                slotDW3 = (slotDW3 & ~(0xFF | (0x1F << 27))) | (newState << 27) | previousAddress
                destination.advanced(by: 12).storeBytes(of: slotDW3.littleEndian, as: UInt32.self)
                print("[XHCI-CONFIGURE] add Slot Context entries=\((UInt32(littleEndian: destination.loadUnaligned(as: UInt32.self)) >> 27) & 0x1F) state=\(newState) address=\(previousAddress)")
            } else {
                // A successfully configured endpoint transitions to Running;
                // all guest-requested type, dequeue, DCS, and CErr fields are
                // copied unchanged from the Input Context.
                var dw0 = UInt32(littleEndian: destination.loadUnaligned(as: UInt32.self))
                dw0 = (dw0 & ~7) | 1
                destination.storeBytes(of: dw0.littleEndian, as: UInt32.self)
                let dw1 = UInt32(littleEndian: destination.advanced(by: 4).loadUnaligned(as: UInt32.self))
                let dw2 = UInt32(littleEndian: destination.advanced(by: 8).loadUnaligned(as: UInt32.self))
                let dw3 = UInt32(littleEndian: destination.advanced(by: 12).loadUnaligned(as: UInt32.self))
                let dequeue = (UInt64(dw2) | UInt64(dw3 & 0xFFFFFFF0) << 32) & ~UInt64(0xF)
                print("[XHCI-CONFIGURE] add endpoint=\(context) state=1 type=\((dw1 >> 3) & 7) mps=\((dw1 >> 16) & 0xFFFF) interval=\((dw0 >> 16) & 0xFF) cerr=\((dw1 >> 1) & 3) trdp=0x\(String(dequeue, radix: 16)) dcs=\(dw2 & 1) avgTRB=\(UInt32(littleEndian: destination.advanced(by: 16).loadUnaligned(as: UInt32.self)) & 0xFFFF) maxESIT=\(UInt32(littleEndian: destination.advanced(by: 28).loadUnaligned(as: UInt32.self)))")
            }
        }

        // The Slot Context's Context Entries field must cover every enabled
        // endpoint context. Do not reduce it if the guest only updated EP0.
        let slot = output
        var slotDW0 = UInt32(littleEndian: slot.loadUnaligned(as: UInt32.self))
        let existingEntries = Int((slotDW0 >> 27) & 0x1F)
        let requestedEntries = max(existingEntries, highestContext)
        slotDW0 = (slotDW0 & ~(0x1F << 27)) | (UInt32(requestedEntries) << 27)
        slot.storeBytes(of: slotDW0.littleEndian, as: UInt32.self)

        if (addFlags & ~UInt32(3)) != 0 {
            var slotDW3 = UInt32(littleEndian: slot.advanced(by: 12).loadUnaligned(as: UInt32.self))
            slotDW3 = (slotDW3 & ~(0x1F << 27)) | (UInt32(3) << 27)
            slot.advanced(by: 12).storeBytes(of: slotDW3.littleEndian, as: UInt32.self)
        }

        // Dump Output Device Context after updates for Section 6 static validation
        let outSlotWords = (0..<8).map { UInt32(littleEndian: output.advanced(by: $0 * 4).loadUnaligned(as: UInt32.self)) }
        print("[XHCI-CONFIGURE-AUDIT] Output Slot raw=\(outSlotWords.map { String(format: "%08x", $0) }.joined(separator: ",")) entries=\((outSlotWords[0] >> 27) & 0x1F) state=\((outSlotWords[3] >> 27) & 0x1F) address=\(outSlotWords[3] & 0xFF)")
        for context in 1..<32 where addFlags & (UInt32(1) << UInt32(context)) != 0 {
            let dst = output.advanced(by: context * 0x20)
            let w = (0..<8).map { UInt32(littleEndian: dst.advanced(by: $0 * 4).loadUnaligned(as: UInt32.self)) }
            let outState = w[0] & 7
            let interval = (w[0] >> 16) & 0xFF
            let cerr = (w[1] >> 1) & 3
            let epType = (w[1] >> 3) & 7
            let burst = (w[1] >> 8) & 0xFF
            let mps = (w[1] >> 16) & 0xFFFF
            let trdp = (UInt64(w[2]) | (UInt64(w[3] & 0xFFFFFFF0) << 32)) & ~UInt64(0xF)
            let dcs = w[2] & 1
            print("[XHCI-CONFIGURE-AUDIT] Output EP context=\(context) epID=\(context) raw=\(w.map { String(format: "%08x", $0) }.joined(separator: ",")) state=\(outState) type=\(epType) mps=\(mps) burst=\(burst) interval=\(interval) cerr=\(cerr) trdp=0x\(String(trdp, radix: 16)) dcs=\(dcs)")
        }

        return true
    }


    private func traceEP0(_ message: String) {
        ep0TraceSequence &+= 1
        print("[XHCI-EP0-TRACE #\(ep0TraceSequence)] \(message)")
    }

    /// Reads guest-owned context/ring bytes only for the bounded EP0 trace.
    private func traceEP0ContextAndRing() {
        guard let dcbaa = ptr(dcbaap),
              let output = ptr(UInt64(littleEndian: dcbaa.advanced(by: 8).loadUnaligned(as: UInt64.self)) & ~UInt64(0x3F)) else {
            traceEP0("EP0 context unavailable dcbaap=0x\(String(dcbaap, radix: 16))")
            return
        }
        let ep = output.advanced(by: 0x20)
        let words = (0..<8).map { UInt32(littleEndian: ep.advanced(by: $0 * 4).loadUnaligned(as: UInt32.self)) }
        let dequeue = (UInt64(words[2]) | UInt64(words[3] & 0xFFFFFFF0) << 32) & ~UInt64(0xF)
        let dcs = words[2] & 1
        let state = words[0] & 7, cerr = (words[1] >> 1) & 3
        let epType = (words[1] >> 3) & 7, packet = (words[1] >> 16) & 0xFFFF
        let averageTRB = words[4] & 0xFFFF
        traceEP0("EP0 context raw=\(words.map { String(format: "%08x", $0) }.joined(separator: ",")) state=\(state) type=\(epType) mps=\(packet) cerr=\(cerr) averageTRB=\(averageTRB) trdp=0x\(String(dequeue, radix: 16)) dcs=\(dcs)")
        guard dequeue != 0 else { return }
        for index in 0..<8 {
            let gpa = dequeue + UInt64(index * 16)
            guard let trb = ptr(gpa) else { traceEP0("transfer TRB invalid gpa=0x\(String(gpa, radix: 16))"); return }
            let parameter = UInt64(littleEndian: trb.loadUnaligned(as: UInt64.self))
            let status = UInt32(littleEndian: trb.advanced(by: 8).loadUnaligned(as: UInt32.self))
            let control = UInt32(littleEndian: trb.advanced(by: 12).loadUnaligned(as: UInt32.self))
            let cycle = control & 1, type = (control >> 10) & 0x3F
            let chain = (control >> 4) & 1, ioc = (control >> 5) & 1, idt = (control >> 6) & 1
            traceEP0("transfer TRB gpa=0x\(String(gpa, radix: 16)) raw=\(String(format: "%08x,%08x,%08x,%08x", UInt32(truncatingIfNeeded: parameter), UInt32(truncatingIfNeeded: parameter >> 32), status, control)) type=\(type) cycle=\(cycle) chain=\(chain) ioc=\(ioc) idt=\(idt) parameter=0x\(String(parameter, radix: 16)) length=\(status & 0x1FFFF)")
            guard cycle == dcs else { traceEP0("transfer cycle mismatch expected=\(dcs) actual=\(cycle)"); return }
            if type == 2 {
                let bm = UInt8(parameter & 0xFF), req = UInt8((parameter >> 8) & 0xFF)
                let value = UInt16((parameter >> 16) & 0xFFFF), indexValue = UInt16((parameter >> 32) & 0xFFFF), length = UInt16((parameter >> 48) & 0xFFFF)
                traceEP0("Setup Stage bmRequestType=0x\(String(bm, radix: 16)) bRequest=0x\(String(req, radix: 16)) wValue=0x\(String(value, radix: 16)) wIndex=0x\(String(indexValue, radix: 16)) wLength=0x\(String(length, radix: 16)) trt=\((control >> 16) & 3)")
            } else if type == 3 {
                traceEP0("Data Stage direction=\(((control >> 16) & 1) != 0 ? "IN" : "OUT") buffer=0x\(String(parameter, radix: 16)) length=\(status & 0x1FFFF)")
            } else if type == 4 {
                traceEP0("Status Stage direction=\(((control >> 16) & 1) != 0 ? "IN" : "OUT")")
            }
            if type == 6 { traceEP0("Link TRB boundary"); return }
        }
    }

    /// Diagnostic only: xHCI Input Context is ICC + Slot + EP0 (three 32-byte
    /// contexts); an Output Device Context starts with Slot + EP0.
    private func traceAddressContexts(inputGPA: UInt64, outputGPA: UInt64, slotID: UInt8, bsr: Bool, cycle: UInt32, phase: String) {
        guard let input = ptr(inputGPA), let output = ptr(outputGPA) else { return }
        func words(_ p: UnsafeMutableRawPointer) -> [UInt32] { (0..<8).map { UInt32(littleEndian: p.advanced(by: $0 * 4).loadUnaligned(as: UInt32.self)) } }
        let icc = words(input), inputSlot = words(input.advanced(by: 0x20)), inputEP0 = words(input.advanced(by: 0x40))
        let outputSlot = words(output), outputEP0 = words(output.advanced(by: 0x20))
        let route = inputSlot[0] & 0xFFFFF, speed = (inputSlot[0] >> 20) & 0xF, mtt = (inputSlot[0] >> 25) & 1, hub = (inputSlot[0] >> 26) & 1, entries = (inputSlot[0] >> 27) & 0x1F
        let maxExit = inputSlot[1] & 0xFFFF, rootPort = (inputSlot[1] >> 16) & 0xFF, ports = (inputSlot[1] >> 24) & 0xFF
        let epState = inputEP0[0] & 7, mult = (inputEP0[0] >> 8) & 3, streams = (inputEP0[0] >> 10) & 0x1F, lsa = (inputEP0[0] >> 15) & 1, interval = (inputEP0[0] >> 16) & 0xFF
        let cerr = (inputEP0[1] >> 1) & 3, epType = (inputEP0[1] >> 3) & 7, hid = (inputEP0[1] >> 7) & 1, burst = (inputEP0[1] >> 8) & 0xFF, packet = (inputEP0[1] >> 16) & 0xFFFF
        let dequeue = (UInt64(inputEP0[2]) | UInt64(inputEP0[3] & 0xFFFFFFF0) << 32) & ~UInt64(0xF), dcs = inputEP0[2] & 1
        let slotState = (outputSlot[3] >> 27) & 0x1F, address = outputSlot[3] & 0xFF, outEPState = outputEP0[0] & 7
        let inputSlotRaw = inputSlot.map { String(format: "%08x", $0) }.joined(separator: ",")
        let inputEP0Raw = inputEP0.map { String(format: "%08x", $0) }.joined(separator: ",")
        let outputSlotRaw = outputSlot.map { String(format: "%08x", $0) }.joined(separator: ",")
        let outputEP0Raw = outputEP0.map { String(format: "%08x", $0) }.joined(separator: ",")
        print("[XHCI-ADDRESS-AUDIT \(phase)] trb=0x\(String(commandDequeue, radix: 16)) input=0x\(String(inputGPA, radix: 16)) dcbaa[\(slotID)]=0x\(String(outputGPA, radix: 16)) slot=\(slotID) bsr=\(bsr ? 1 : 0) cycle=\(cycle)")
        print("[XHCI-ADDRESS-AUDIT \(phase)] ICC drop=0x\(String(icc[0], radix: 16)) add=0x\(String(icc[1], radix: 16)) input-slot=\(inputSlotRaw) route=0x\(String(route, radix: 16)) speed=\(speed) mtt=\(mtt) hub=\(hub) entries=\(entries) maxExit=\(maxExit) rootPort=\(rootPort) ports=\(ports)")
        print("[XHCI-ADDRESS-AUDIT \(phase)] input-ep0=\(inputEP0Raw) state=\(epState) mult=\(mult) streams=\(streams) lsa=\(lsa) interval=\(interval) cerr=\(cerr) type=\(epType) hid=\(hid) burst=\(burst) mps=\(packet) trdp=0x\(String(dequeue, radix: 16)) dcs=\(dcs)")
        print("[XHCI-ADDRESS-AUDIT \(phase)] output-slot=\(outputSlotRaw) state=\(slotState) address=\(address) output-ep0=\(outputEP0Raw) state=\(outEPState)")
    }

    private func postCommandCompletionLocked(commandTRB: UInt64, slotID: UInt8, code: UInt8 = 1) -> Bool {
        guard let entry = ptr(erstba) else { return false }
        let base = UInt64(littleEndian: entry.loadUnaligned(as: UInt64.self))
        let count = UInt16(littleEndian: entry.advanced(by: 8).loadUnaligned(as: UInt16.self))
        guard count > 0, eventIndex < count, let event = ptr(base + UInt64(eventIndex) * 16) else { return false }
        event.storeBytes(of: commandTRB.littleEndian, as: UInt64.self)
        event.advanced(by: 8).storeBytes(of: (UInt32(code) << 24).littleEndian, as: UInt32.self)
        let control = ((UInt32(33) << 10) | (UInt32(slotID) << 24) | eventCycle).littleEndian
        event.advanced(by: 12).storeBytes(of: control, as: UInt32.self)
        print("🔎 FluxXHCI EVENT: Command Completion cmd=0x\(String(commandTRB, radix: 16)) code=\(code) slot=\(slotID) ERST=0x\(String(base, radix: 16)) index=\(eventIndex) cycle=\(eventCycle)")
        eventIndex += 1
        if eventIndex == count { eventIndex = 0; eventCycle ^= 1 }
        iman |= 1
        pba |= 1
        return true
    }

    private struct TransferTRB {
        let gpa: UInt64
        let parameter: UInt64
        let status: UInt32
        let control: UInt32
        var type: UInt32 { (control >> 10) & 0x3F }
        var cycle: UInt32 { control & 1 }
    }

    private func resolveTransferTRB(at gpa: UInt64, cycle: UInt32) -> (gpa: UInt64, cycle: UInt32, trb: TransferTRB)? {
        var curGPA = gpa
        var curCycle = cycle
        for _ in 0..<8 {
            guard let trb = transferTRB(curGPA) else { return nil }
            if trb.type == 6 { // Link TRB
                guard trb.cycle == curCycle else { return nil }
                if (trb.control & (1 << 1)) != 0 { // Toggle Cycle (TC)
                    curCycle ^= 1
                }
                curGPA = trb.parameter & ~UInt64(0xF)
            } else {
                return (curGPA, curCycle, trb)
            }
        }
        return nil
    }

    private func nextTransferTRB(after gpa: UInt64, cycle: UInt32) -> (gpa: UInt64, cycle: UInt32, trb: TransferTRB)? {
        return resolveTransferTRB(at: gpa + 16, cycle: cycle)
    }

    private func advanceTransferPointer(after gpa: UInt64, cycle: UInt32) -> (gpa: UInt64, cycle: UInt32) {
        if let resolved = resolveTransferTRB(at: gpa + 16, cycle: cycle) {
            return (resolved.gpa, resolved.cycle)
        }
        return (gpa + 16, cycle)
    }

    /// Fetches the one observed Windows EP0 transaction only. The Event Data
    /// TRBs are completion metadata for this TD, not a general transfer-ring
    /// implementation. Any other layout is intentionally left unconsumed.
    private func processEP0DeviceDescriptorLocked() -> Delivery? {
        guard let dcbaa = ptr(dcbaap, bytes: 16) else {
            print("⚠️ FluxXHCI EP0: invalid DCBAAP=0x\(String(dcbaap, radix: 16)); not consumed")
            return nil
        }
        let outputGPA = UInt64(littleEndian: dcbaa.advanced(by: 8).loadUnaligned(as: UInt64.self)) & ~UInt64(0x3F)
        guard let output = ptr(outputGPA, bytes: 64) else {
            print("⚠️ FluxXHCI EP0: invalid output context=0x\(String(outputGPA, radix: 16)); not consumed")
            return nil
        }
        let ep0 = output.advanced(by: 0x20)
        var epDW0 = UInt32(littleEndian: ep0.loadUnaligned(as: UInt32.self))
        let epDW1 = UInt32(littleEndian: ep0.advanced(by: 4).loadUnaligned(as: UInt32.self))
        let epDW2 = UInt32(littleEndian: ep0.advanced(by: 8).loadUnaligned(as: UInt32.self))
        let epDW3 = UInt32(littleEndian: ep0.advanced(by: 12).loadUnaligned(as: UInt32.self))
        let endpointState = epDW0 & 7
        let endpointType = (epDW1 >> 3) & 7
        let maxPacketSize = (epDW1 >> 16) & 0xFFFF
        let dcs = epDW2 & 1
        let dequeue = (UInt64(epDW2) | UInt64(epDW3 & 0xFFFFFFF0) << 32) & ~UInt64(0xF)
        guard (endpointState == 1 || endpointState == 3), endpointType == 4, maxPacketSize == 64, dequeue != 0 else {
            print("⚠️ FluxXHCI EP0: unsupported context state=\(endpointState) type=\(endpointType) mps=\(maxPacketSize) trdp=0x\(String(dequeue, radix: 16)); not consumed")
            return nil
        }
        if endpointState == 3 {
            epDW0 = (epDW0 & ~0x7) | 1 // xHCI §4.8.3 Table 12: Doorbell ring transitions Stopped -> Running
            ep0.storeBytes(of: epDW0.littleEndian, as: UInt32.self)
        }

        guard let (setupGPA, setupCycle, setup) = resolveTransferTRB(at: dequeue, cycle: dcs),
              setup.type == 2, setup.cycle == dcs,
              let (trb1GPA, trb1Cycle, trb1) = nextTransferTRB(after: setupGPA, cycle: setupCycle),
              trb1.cycle == trb1Cycle else {
            print("⚠️ FluxXHCI EP0: invalid Setup/TRB1 at 0x\(String(dequeue, radix: 16)); not consumed")
            return nil
        }

        func setEP0Dequeue(gpa: UInt64, cycle: UInt32) {
            ep0.advanced(by: 8).storeBytes(of: (UInt32(truncatingIfNeeded: gpa) | (cycle & 1)).littleEndian, as: UInt32.self)
            ep0.advanced(by: 12).storeBytes(of: UInt32(truncatingIfNeeded: gpa >> 32).littleEndian, as: UInt32.self)
        }

        let bmRequestType = UInt8(setup.parameter & 0xFF)
        let request = UInt8((setup.parameter >> 8) & 0xFF)
        let value = UInt16((setup.parameter >> 16) & 0xFFFF)
        let index = UInt16((setup.parameter >> 32) & 0xFFFF)
        let requestedLength = UInt16((setup.parameter >> 48) & 0xFFFF)

        if trb1.type == 4 {
            // Zero-data control transfer: Setup (2) -> Status (4) -> Event Data (7)
            guard let (statusEventGPA, statusEventCycle, statusEvent) = nextTransferTRB(after: trb1GPA, cycle: trb1Cycle),
                  statusEvent.cycle == statusEventCycle, statusEvent.type == 7 else {
                print("⚠️ FluxXHCI EP0: invalid zero-data TRB chain at 0x\(String(dequeue, radix: 16)); not consumed")
                return nil
            }
            let statusIsIn = (trb1.control & (1 << 16)) != 0
            print("[XHCI-EP0-SETUP-ZERODATA] GPA=0x\(String(setupGPA, radix: 16)) bmRequestType=0x\(String(bmRequestType, radix: 16)) req=0x\(String(request, radix: 16)) value=0x\(String(value, radix: 16)) index=0x\(String(index, radix: 16)) wLength=\(requestedLength) statusDir=\(statusIsIn ? "IN" : "OUT")")
            let finalPos = advanceTransferPointer(after: statusEventGPA, cycle: statusEventCycle)

            if bmRequestType == 0x00 && request == 0x09 && requestedLength == 0 {
                let configValue = UInt8(value & 0xFF)
                guard configValue == 1 else {
                    print("⚠️ FluxXHCI EP0: unsupported configuration value \(configValue); not consumed")
                    return nil
                }
                slots[0].configurationValue = configValue
                print("🔎 FluxXHCI EP0: SET_CONFIGURATION(\(configValue)) success; device configured")

                setEP0Dequeue(gpa: finalPos.gpa, cycle: finalPos.cycle)
                guard postTransferEventLocked(eventData: statusEvent.parameter, completionCode: 1,
                                              transferLength: 0, slotID: 1, endpointID: 1) else {
                    setEP0Dequeue(gpa: dequeue, cycle: dcs)
                    return nil
                }
                return prepareMSILocked()
            }
            if bmRequestType == 0x21 && request == 0x0A && requestedLength == 0 {
                let interface = UInt8(index & 0xFF)
                let duration = UInt8(value >> 8)
                let reportID = UInt8(value & 0xFF)
                guard (interface == 0 || interface == 1), reportID == 0 else {
                    print("⚠️ FluxXHCI EP0: unsupported SET_IDLE interface=\(interface) reportID=\(reportID); not consumed")
                    return nil
                }
                let oldDuration = slots[0].idleDuration
                let oldReportID = slots[0].idleReportID
                slots[0].idleDuration = duration
                slots[0].idleReportID = reportID
                print("[XHCI-HID-SET-IDLE] slot=1 interface=\(interface) duration=\(duration) reportID=\(reportID) before=(dur=\(oldDuration),rep=\(oldReportID)) after=(dur=\(duration),rep=\(reportID))")

                setEP0Dequeue(gpa: finalPos.gpa, cycle: finalPos.cycle)
                guard postTransferEventLocked(eventData: statusEvent.parameter, completionCode: 1,
                                              transferLength: 0, slotID: 1, endpointID: 1) else {
                    setEP0Dequeue(gpa: dequeue, cycle: dcs)
                    return nil
                }
                print("🔎 FluxXHCI EP0: SET_IDLE interface=\(interface) duration=\(duration) reportID=\(reportID) success")
                return prepareMSILocked()
            }
            if bmRequestType == 0x21 && request == 0x0B && requestedLength == 0 {
                let protocolValue = UInt8(value & 0xFF)
                let interface = UInt8(index & 0xFF)
                print("[XHCI-HID-SET-PROTOCOL] slot=1 interface=\(interface) protocol=\(protocolValue)")
                setEP0Dequeue(gpa: finalPos.gpa, cycle: finalPos.cycle)
                guard postTransferEventLocked(eventData: statusEvent.parameter, completionCode: 1,
                                              transferLength: 0, slotID: 1, endpointID: 1) else {
                    setEP0Dequeue(gpa: dequeue, cycle: dcs)
                    return nil
                }
                print("🔎 FluxXHCI EP0: SET_PROTOCOL interface=\(interface) protocol=\(protocolValue) success")
                return prepareMSILocked()
            }
            print("⚠️ FluxXHCI EP0: unsupported zero-data request bm=0x\(String(bmRequestType, radix: 16)) req=0x\(String(request, radix: 16)) value=0x\(String(value, radix: 16)); not consumed")
            return nil
        }

        let data = trb1
        let dataGPA = trb1GPA
        let dataCycle = trb1Cycle
        guard let (dataEventGPA, dataEventCycle, dataEvent) = nextTransferTRB(after: dataGPA, cycle: dataCycle),
              let (statusGPA, statusCycle, status) = nextTransferTRB(after: dataEventGPA, cycle: dataEventCycle),
              let (statusEventGPA, statusEventCycle, statusEvent) = nextTransferTRB(after: statusGPA, cycle: statusCycle),
              data.type == 3, dataEvent.type == 7,
              status.type == 4, statusEvent.type == 7 else {
            print("⚠️ FluxXHCI EP0: unsupported TRB chain at 0x\(String(dequeue, radix: 16)) types=\(setup.type),\(data.type); not consumed")
            return nil
        }
        let finalPos = advanceTransferPointer(after: statusEventGPA, cycle: statusEventCycle)

        let descriptorType = UInt8(value >> 8), descriptorIndex = UInt8(truncatingIfNeeded: value)
        let dataLength = data.status & 0x1FFFF
        let dataIsIn = (data.control & (1 << 16)) != 0
        let statusIsOut = (status.control & (1 << 16)) == 0
        print("[XHCI-EP0-SETUP] GPA=0x\(String(setupGPA, radix: 16)) bmRequestType=0x\(String(bmRequestType, radix: 16)) req=0x\(String(request, radix: 16)) descType=\(descriptorType) descIdx=\(descriptorIndex) wLength=\(requestedLength) dataBuf=0x\(String(data.parameter, radix: 16)) dataLen=\(dataLength)")
        let isUnsupportedStringEE = (descriptorType == 3 && descriptorIndex == 0xEE)
        let isUnsupportedDeviceQualifier = (descriptorType == 6 && descriptorIndex == 0)
        if bmRequestType == 0x80 && request == 0x06 && (isUnsupportedStringEE || isUnsupportedDeviceQualifier) {
            let reqName = isUnsupportedDeviceQualifier ? "GET_DESCRIPTOR(Device Qualifier)" : "GET_DESCRIPTOR(String 0xEE)"
            print("🔎 FluxXHCI EP0: \(reqName) unsupported (Full-Speed only / no MS OS); returning STALL")
            var epDW0 = UInt32(littleEndian: ep0.loadUnaligned(as: UInt32.self))
            epDW0 = (epDW0 & ~0x7) | 2 // Endpoint State = Halted (2)
            ep0.storeBytes(of: epDW0.littleEndian, as: UInt32.self)
            setEP0Dequeue(gpa: statusGPA, cycle: statusCycle)
            guard postTransferEventLocked(eventData: dataEvent.parameter, completionCode: 6,
                                          transferLength: dataLength, slotID: 1, endpointID: 1) else {
                return nil
            }
            return prepareMSILocked()
        }
        let isSetReport = (bmRequestType == 0x21 && request == 0x09 && requestedLength == 1 && !dataIsIn)
        if isSetReport {
            let reportType = UInt8(value >> 8)
            let reportID = UInt8(value & 0xFF)
            let interface = UInt8(index & 0xFF)
            guard reportType == 2, reportID == 0, interface == 0,
                  (status.control & (1 << 16)) != 0 else {
                print("⚠️ FluxXHCI EP0: invalid SET_REPORT parameters type=\(reportType) id=\(reportID) if=\(interface) len=\(requestedLength); not consumed")
                return nil
            }
            let isIDT = (data.control & (1 << 6)) != 0
            let payloadByte: UInt8
            if isIDT {
                payloadByte = UInt8(data.parameter & 0xFF)
            } else {
                guard let buf = ptr(data.parameter, bytes: 1) else {
                    print("⚠️ FluxXHCI EP0: invalid OUT data buffer 0x\(String(data.parameter, radix: 16)); not consumed")
                    return nil
                }
                payloadByte = buf.load(as: UInt8.self)
            }
            let numLock = (payloadByte & (1 << 0)) != 0
            let capsLock = (payloadByte & (1 << 1)) != 0
            let scrollLock = (payloadByte & (1 << 2)) != 0
            let compose = (payloadByte & (1 << 3)) != 0
            let kana = (payloadByte & (1 << 4)) != 0
            let padding = (payloadByte >> 5) & 0x7

            let oldLEDs = slots[0].keyboardLEDs
            slots[0].keyboardLEDs = payloadByte
            print("[XHCI-HID-SET-REPORT] raw=0x\(String(format: "%02x", payloadByte)) NumLock=\(numLock ? 1 : 0) CapsLock=\(capsLock ? 1 : 0) ScrollLock=\(scrollLock ? 1 : 0) Compose=\(compose ? 1 : 0) Kana=\(kana ? 1 : 0) padding=0x\(String(padding, radix: 16)) before=0x\(String(format: "%02x", oldLEDs)) after=0x\(String(format: "%02x", payloadByte)) IDT=\(isIDT ? 1 : 0)")

            setEP0Dequeue(gpa: statusGPA, cycle: statusCycle)
            guard postTransferEventLocked(eventData: dataEvent.parameter, completionCode: 1,
                                          transferLength: 1, slotID: 1, endpointID: 1) else {
                setEP0Dequeue(gpa: dequeue, cycle: dcs)
                return nil
            }
            setEP0Dequeue(gpa: finalPos.gpa, cycle: finalPos.cycle)
            guard postTransferEventLocked(eventData: statusEvent.parameter, completionCode: 1,
                                          transferLength: 0, slotID: 1, endpointID: 1) else {
                setEP0Dequeue(gpa: statusGPA, cycle: statusCycle)
                return nil
            }
            print("🔎 FluxXHCI EP0: SET_REPORT(Output) success byte=0x\(String(format: "%02x", payloadByte)) dataDequeue=0x\(String(dequeue, radix: 16))->0x\(String(statusGPA, radix: 16)) statusDequeue=0x\(String(statusGPA, radix: 16))->0x\(String(finalPos.gpa, radix: 16))")
            return prepareMSILocked()
        }
        let isDeviceDesc = (bmRequestType == 0x80 && request == 0x06 && descriptorType == 1 && descriptorIndex == 0 && index == 0)
        let isConfigDesc = (bmRequestType == 0x80 && request == 0x06 && descriptorType == 2 && descriptorIndex == 0 && index == 0)
        let isReportDesc = (bmRequestType == 0x81 && request == 0x06 && descriptorType == 0x22 && descriptorIndex == 0 && (index == 0 || index == 1))
        guard (isDeviceDesc || isConfigDesc || isReportDesc), dataIsIn, statusIsOut else {
            print("⚠️ FluxXHCI EP0: unsupported request bm=0x\(String(bmRequestType, radix: 16)) req=0x\(String(request, radix: 16)) value=0x\(String(value, radix: 16)) index=0x\(String(index, radix: 16)); not consumed")
            return nil
        }
        let descriptor: [UInt8]
        let descName: String
        if isDeviceDesc {
            descName = "GET_DESCRIPTOR(Device)"
            descriptor = [
                18, 1, 0x00, 0x02, 0, 0, 0, 64,
                UInt8(truncatingIfNeeded: Self.testUSBVendorID), UInt8(Self.testUSBVendorID >> 8),
                UInt8(truncatingIfNeeded: Self.testUSBProductID), UInt8(Self.testUSBProductID >> 8),
                0x00, 0x01, 0, 0, 0, 1,
            ]
        } else if isConfigDesc {
            descName = "GET_DESCRIPTOR(Configuration)"
            descriptor = [
                // Configuration Descriptor (9 bytes)
                0x09,       // bLength
                0x02,       // bDescriptorType = Configuration
                0x3B, 0x00, // wTotalLength = 59 bytes (9 + 25 + 25)
                0x02,       // bNumInterfaces = 2
                0x01,       // bConfigurationValue = 1
                0x00,       // iConfiguration = 0
                0xA0,       // bmAttributes = Bus-powered, Remote Wakeup
                0x32,       // bMaxPower = 100 mA (50 * 2mA)

                // Interface 0 Descriptor - Keyboard (9 bytes)
                0x09,       // bLength
                0x04,       // bDescriptorType = Interface
                0x00,       // bInterfaceNumber = 0
                0x00,       // bAlternateSetting = 0
                0x01,       // bNumEndpoints = 1
                0x03,       // bInterfaceClass = HID
                0x01,       // bInterfaceSubClass = Boot Interface
                0x01,       // bInterfaceProtocol = Keyboard
                0x00,       // iInterface = 0

                // HID Descriptor 0 (9 bytes)
                0x09,       // bLength
                0x21,       // bDescriptorType = HID
                0x11, 0x01, // bcdHID = 1.11
                0x00,       // bCountryCode = 0
                0x01,       // bNumDescriptors = 1
                0x22,       // bDescriptorType = Report
                0x3F, 0x00, // wDescriptorLength = 63 bytes (standard boot keyboard)

                // Endpoint Descriptor 0 (7 bytes)
                0x07,       // bLength
                0x05,       // bDescriptorType = Endpoint
                0x81,       // bEndpointAddress = EP1 IN (0x80 | 1)
                0x03,       // bmAttributes = Interrupt
                0x08, 0x00, // wMaxPacketSize = 8 bytes
                0x0A,       // bInterval = 10 ms

                // Interface 1 Descriptor - Absolute Pointer (9 bytes)
                0x09,       // bLength
                0x04,       // bDescriptorType = Interface
                0x01,       // bInterfaceNumber = 1
                0x00,       // bAlternateSetting = 0
                0x01,       // bNumEndpoints = 1
                0x03,       // bInterfaceClass = HID
                0x00,       // bInterfaceSubClass = None
                0x00,       // bInterfaceProtocol = None
                0x00,       // iInterface = 0

                // HID Descriptor 1 (9 bytes)
                0x09,       // bLength
                0x21,       // bDescriptorType = HID
                0x11, 0x01, // bcdHID = 1.11
                0x00,       // bCountryCode = 0
                0x01,       // bNumDescriptors = 1
                0x22,       // bDescriptorType = Report
                0x3F, 0x00, // wDescriptorLength = 63 bytes (0x003F)

                // Endpoint Descriptor 1 (7 bytes)
                0x07,       // bLength
                0x05,       // bDescriptorType = Endpoint
                0x82,       // bEndpointAddress = EP2 IN (0x80 | 2)
                0x03,       // bmAttributes = Interrupt
                0x08, 0x00, // wMaxPacketSize = 8 bytes
                0x0A,       // bInterval = 10 ms
            ]
        } else if index == 0 {
            descName = "GET_DESCRIPTOR(HID Report Keyboard)"
            descriptor = [
                0x05, 0x01, // Usage Page (Generic Desktop)
                0x09, 0x06, // Usage (Keyboard)
                0xA1, 0x01, // Collection (Application)
                0x05, 0x07, //   Usage Page (Key Codes)
                0x19, 0xE0, //   Usage Minimum (224) - LeftControl
                0x29, 0xE7, //   Usage Maximum (231) - Right GUI
                0x15, 0x00, //   Logical Minimum (0)
                0x25, 0x01, //   Logical Maximum (1)
                0x75, 0x01, //   Report Size (1)
                0x95, 0x08, //   Report Count (8)
                0x81, 0x02, //   Input (Data, Variable, Absolute) - Modifier byte (Byte 0)
                0x95, 0x01, //   Report Count (1)
                0x75, 0x08, //   Report Size (8)
                0x81, 0x01, //   Input (Constant) - Reserved byte (Byte 1)
                0x95, 0x05, //   Report Count (5)
                0x75, 0x01, //   Report Size (1)
                0x05, 0x08, //   Usage Page (LEDs)
                0x19, 0x01, //   Usage Minimum (1) - Num Lock
                0x29, 0x05, //   Usage Maximum (5) - Kana
                0x91, 0x02, //   Output (Data, Variable, Absolute) - LED report (5 bits)
                0x95, 0x01, //   Report Count (1)
                0x75, 0x03, //   Report Size (3)
                0x91, 0x01, //   Output (Constant) - LED report padding (3 bits)
                0x95, 0x06, //   Report Count (6)
                0x75, 0x08, //   Report Size (8)
                0x15, 0x00, //   Logical Minimum (0)
                0x25, 0x65, //   Logical Maximum (101)
                0x05, 0x07, //   Usage Page (Key Codes)
                0x19, 0x00, //   Usage Minimum (0)
                0x29, 0x65, //   Usage Maximum (101)
                0x81, 0x00, //   Input (Data, Array) - 6 key codes (Bytes 2..7)
                0xC0,       // End Collection
            ]
        } else {
            descName = "GET_DESCRIPTOR(HID Report Pointer)"
            descriptor = [
                0x05, 0x01, // Usage Page (Generic Desktop)
                0x09, 0x02, // Usage (Mouse)
                0xA1, 0x01, // Collection (Application)
                0x09, 0x01, //   Usage (Pointer)
                0xA1, 0x00, //   Collection (Physical)
                0x05, 0x09, //     Usage Page (Button)
                0x19, 0x01, //     Usage Minimum (1) - Button 1 (Left)
                0x29, 0x03, //     Usage Maximum (3) - Button 3 (Middle)
                0x15, 0x00, //     Logical Minimum (0)
                0x25, 0x01, //     Logical Maximum (1)
                0x95, 0x03, //     Report Count (3)
                0x75, 0x01, //     Report Size (1)
                0x81, 0x02, //     Input (Data, Variable, Absolute) - 3 buttons
                0x95, 0x01, //     Report Count (1)
                0x75, 0x05, //     Report Size (5)
                0x81, 0x01, //     Input (Constant) - Padding (5 bits)
                0x05, 0x01, //     Usage Page (Generic Desktop)
                0x09, 0x30, //     Usage (X)
                0x09, 0x31, //     Usage (Y)
                0x15, 0x00, //     Logical Minimum (0)
                0x26, 0xFF, 0x7F, // Logical Maximum (32767)
                0x75, 0x10, //     Report Size (16)
                0x95, 0x02, //     Report Count (2)
                0x81, 0x02, //     Input (Data, Variable, Absolute) - X, Y
                0x09, 0x38, //     Usage (Wheel)
                0x15, 0x81, //     Logical Minimum (-127)
                0x25, 0x7F, //     Logical Maximum (127)
                0x75, 0x08, //     Report Size (8)
                0x95, 0x01, //     Report Count (1)
                0x81, 0x06, //     Input (Data, Variable, Relative) - Vertical Wheel
                0xC0,       //   End Collection
                0xC0,       // End Collection
            ]
        }
        let payloadLength = min(descriptor.count, Int(requestedLength), Int(dataLength))
        guard payloadLength > 0,
              let buffer = ptr(data.parameter, bytes: payloadLength) else {
            print("⚠️ FluxXHCI EP0: invalid/short IN buffer=0x\(String(data.parameter, radix: 16)) requested=\(requestedLength) trbLength=\(dataLength); not consumed")
            return nil
        }
        descriptor.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: payloadLength) }

        // The observed control transfer has two TDs. The short IN Data Stage
        // terminates at its Event Data TRB, then the zero-length Status Stage
        // terminates at its own Event Data TRB. Event Data Transfer Events use
        // actual transferred length, rather than a Data Stage residual.
        setEP0Dequeue(gpa: statusGPA, cycle: statusCycle)
        let dataCode: UInt32 = (payloadLength < Int(dataLength)) ? 13 : 1
        guard postTransferEventLocked(eventData: dataEvent.parameter, completionCode: dataCode,
                                      transferLength: UInt32(payloadLength), slotID: 1, endpointID: 1) else {
            setEP0Dequeue(gpa: dequeue, cycle: dcs)
            return nil
        }
        setEP0Dequeue(gpa: finalPos.gpa, cycle: finalPos.cycle)
        guard postTransferEventLocked(eventData: statusEvent.parameter, completionCode: 1,
                                      transferLength: 0, slotID: 1, endpointID: 1) else {
            // The first Event Data completion is already visible, so retain
            // its consumed Data TD and leave EP0 at the Status Stage for a
            // later retry rather than silently skipping it.
            setEP0Dequeue(gpa: statusGPA, cycle: statusCycle)
            return nil
        }
        print("🔎 FluxXHCI EP0: \(descName) buffer=0x\(String(data.parameter, radix: 16)) bytes=\(payloadLength)/\(descriptor.count) wLength=\(requestedLength) dataDequeue=0x\(String(dequeue, radix: 16))->0x\(String(statusGPA, radix: 16)) statusDequeue=0x\(String(statusGPA, radix: 16))->0x\(String(finalPos.gpa, radix: 16))")
        return prepareMSILocked()
    }

    private func processEP3InterruptTransferLocked() -> Delivery? {
        guard slots[0].enabled, slots[0].configurationValue != 0 else {
            return nil
        }
        guard dcbaap != 0, let dcbaa = ptr(dcbaap, bytes: 32) else {
            print("⚠️ FluxXHCI EP3: invalid DCBAAP=0x\(String(dcbaap, radix: 16)); not consumed")
            return nil
        }
        let outputGPA = UInt64(littleEndian: dcbaa.advanced(by: 8).loadUnaligned(as: UInt64.self)) & ~UInt64(0x3F)
        guard let output = ptr(outputGPA, bytes: 0x80) else {
            print("⚠️ FluxXHCI EP3: invalid output context=0x\(String(outputGPA, radix: 16)); not consumed")
            return nil
        }
        // Endpoint 3 Context is at offset 0x20 * 3 = 0x60 in Output Device Context
        let ep3 = output.advanced(by: 0x60)
        var epDW0 = UInt32(littleEndian: ep3.loadUnaligned(as: UInt32.self))
        let epDW1 = UInt32(littleEndian: ep3.advanced(by: 4).loadUnaligned(as: UInt32.self))
        let epDW2 = UInt32(littleEndian: ep3.advanced(by: 8).loadUnaligned(as: UInt32.self))
        let epDW3 = UInt32(littleEndian: ep3.advanced(by: 12).loadUnaligned(as: UInt32.self))
        let epDW4 = UInt32(littleEndian: ep3.advanced(by: 16).loadUnaligned(as: UInt32.self))

        let endpointState = epDW0 & 7
        let interval = (epDW0 >> 16) & 0xFF
        let epType = (epDW1 >> 3) & 7
        let mps = (epDW1 >> 16) & 0xFFFF
        let dcs = epDW2 & 1
        let dequeue = (UInt64(epDW2 & ~0xF) | (UInt64(epDW3) << 32))
        let avgTRBLength = epDW4 & 0xFFFF
        let maxESITPayload = ((epDW0 >> 24) << 16) | (epDW4 >> 16)

        guard endpointState == 1 || endpointState == 3 else {
            print("⚠️ FluxXHCI EP3: invalid state=\(endpointState); not consumed")
            return nil
        }
        if endpointState == 3 {
            epDW0 = (epDW0 & ~7) | 1
            ep3.storeBytes(of: epDW0.littleEndian, as: UInt32.self)
        }

        // Fetch TRB at dequeue, following Link TRBs if present
        guard let (curGPA, curCycle, trb) = resolveTransferTRB(at: dequeue, cycle: dcs) else {
            print("⚠️ FluxXHCI EP3: invalid TRB at 0x\(String(dequeue, radix: 16)); not consumed")
            return nil
        }

        let trbGPA = curGPA
        let trbType = trb.type
        let trbCycle = trb.cycle
        let trbParam = trb.parameter
        let trbStatus = trb.status
        let trbControl = trb.control
        let reqLen = trbStatus & 0x1FFFF
        let ent = (trbControl & (1 << 1)) != 0
        let isp = (trbControl & (1 << 2)) != 0
        let ch = (trbControl & (1 << 4)) != 0
        let ioc = (trbControl & (1 << 5)) != 0
        let idt = (trbControl & (1 << 6)) != 0

        guard trbCycle == curCycle else {
            return nil
        }
        guard trbType == 1 else {
            print("⚠️ FluxXHCI EP3: unsupported TRB type=\(trbType); not consumed")
            return nil
        }

        // Check if there is a keyboard report to deliver
        guard let report = FluxHIDKeyboard.shared.peekReport() else {
            print("🔔 FluxXHCI EP3: Doorbell armed ring at 0x\(String(curGPA, radix: 16)) cycle=\(curCycle); waiting for key event")
            FluxHIDKeyboard.shared.notifyEP3Armed()
            return nil
        }

        print("[XHCI-EP3-CONTEXT] state=\(endpointState) type=\(epType) mps=\(mps) interval=\(interval) trdp=0x\(String(curGPA, radix: 16)) dcs=\(curCycle) avgTRB=\(avgTRBLength) maxESIT=\(maxESITPayload)")
        print("[XHCI-EP3-TRB] GPA=0x\(String(trbGPA, radix: 16)) type=\(trbType) cycle=\(trbCycle) dcs=\(curCycle) param=0x\(String(trbParam, radix: 16)) reqLen=\(reqLen) ENT=\(ent ? 1 : 0) ISP=\(isp ? 1 : 0) CH=\(ch ? 1 : 0) IOC=\(ioc ? 1 : 0) IDT=\(idt ? 1 : 0)")

        // Check if there is a chained Event Data TRB
        var isEventData = false
        var eventDataToken = trbGPA
        var finalPos = advanceTransferPointer(after: curGPA, cycle: curCycle)
        if ch {
            if let (nextGPA, nextCycle, nextTRB) = nextTransferTRB(after: curGPA, cycle: curCycle),
               nextTRB.cycle == nextCycle, nextTRB.type == 7 {
                isEventData = true
                eventDataToken = nextTRB.parameter
                finalPos = advanceTransferPointer(after: nextGPA, cycle: nextCycle)
                print("[XHCI-EP3-EVENTDATA] token=0x\(String(eventDataToken, radix: 16)) finalDequeue=0x\(String(finalPos.gpa, radix: 16)) cycle=\(finalPos.cycle)")
            }
        }

        let writeLen = min(report.count, Int(reqLen))
        guard writeLen > 0, let buf = ptr(trbParam, bytes: writeLen) else {
            print("⚠️ FluxXHCI EP3: invalid buffer GPA=0x\(String(trbParam, radix: 16)) len=\(writeLen); not consumed")
            return nil
        }
        report.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress!, byteCount: writeLen) }
        _ = FluxHIDKeyboard.shared.popReport()
        print("[XHCI-EP3-REPORT] wrote \(writeLen) bytes to buffer GPA=0x\(String(trbParam, radix: 16)) [\(report.map { String(format: "%02x", $0) }.joined(separator: " "))]")

        // Update TR Dequeue Pointer in Endpoint 3 Context
        let newDW2 = UInt32(truncatingIfNeeded: finalPos.gpa) | finalPos.cycle
        let newDW3 = UInt32(truncatingIfNeeded: finalPos.gpa >> 32)
        ep3.advanced(by: 8).storeBytes(of: newDW2.littleEndian, as: UInt32.self)
        ep3.advanced(by: 12).storeBytes(of: newDW3.littleEndian, as: UInt32.self)

        // Completion Code: Short Packet (13) if writeLen < reqLen, else Success (1)
        let compCode: UInt32 = (writeLen < Int(reqLen)) ? 13 : 1
        guard postTransferEventLocked(eventData: eventDataToken, completionCode: compCode,
                                      transferLength: UInt32(writeLen), slotID: 1, endpointID: 3,
                                      isEventData: isEventData) else {
            ep3.advanced(by: 8).storeBytes(of: epDW2.littleEndian, as: UInt32.self)
            ep3.advanced(by: 12).storeBytes(of: epDW3.littleEndian, as: UInt32.self)
            return nil
        }
        print("🔎 FluxXHCI EP3: Transfer complete code=\(compCode) len=\(writeLen) trdp=0x\(String(curGPA, radix: 16))->0x\(String(finalPos.gpa, radix: 16))")
        return prepareMSILocked()
    }

    private func processEP5InterruptTransferLocked() -> Delivery? {
        guard slots[0].enabled, slots[0].configurationValue != 0 else {
            return nil
        }
        guard dcbaap != 0, let dcbaa = ptr(dcbaap, bytes: 32) else {
            print("⚠️ FluxXHCI EP5: invalid DCBAAP=0x\(String(dcbaap, radix: 16)); not consumed")
            return nil
        }
        let outputGPA = UInt64(littleEndian: dcbaa.advanced(by: 8).loadUnaligned(as: UInt64.self)) & ~UInt64(0x3F)
        guard let output = ptr(outputGPA, bytes: 0xC0) else {
            print("⚠️ FluxXHCI EP5: invalid output context=0x\(String(outputGPA, radix: 16)); not consumed")
            return nil
        }
        // Endpoint 5 Context is at offset 0x20 * 5 = 0xA0 in Output Device Context
        let ep5 = output.advanced(by: 0xA0)
        var epDW0 = UInt32(littleEndian: ep5.loadUnaligned(as: UInt32.self))
        let epDW1 = UInt32(littleEndian: ep5.advanced(by: 4).loadUnaligned(as: UInt32.self))
        let epDW2 = UInt32(littleEndian: ep5.advanced(by: 8).loadUnaligned(as: UInt32.self))
        let epDW3 = UInt32(littleEndian: ep5.advanced(by: 12).loadUnaligned(as: UInt32.self))
        let epDW4 = UInt32(littleEndian: ep5.advanced(by: 16).loadUnaligned(as: UInt32.self))

        let endpointState = epDW0 & 7
        let interval = (epDW0 >> 16) & 0xFF
        let epType = (epDW1 >> 3) & 7
        let mps = (epDW1 >> 16) & 0xFFFF
        let dcs = epDW2 & 1
        let dequeue = (UInt64(epDW2 & ~0xF) | (UInt64(epDW3) << 32))
        let avgTRBLength = epDW4 & 0xFFFF
        let maxESITPayload = ((epDW0 >> 24) << 16) | (epDW4 >> 16)

        guard endpointState == 1 || endpointState == 3 else {
            print("⚠️ FluxXHCI EP5: invalid state=\(endpointState); not consumed")
            return nil
        }
        if endpointState == 3 {
            epDW0 = (epDW0 & ~7) | 1
            ep5.storeBytes(of: epDW0.littleEndian, as: UInt32.self)
        }

        // Fetch TRB at dequeue, following Link TRBs if present
        guard let (curGPA, curCycle, trb) = resolveTransferTRB(at: dequeue, cycle: dcs) else {
            print("⚠️ FluxXHCI EP5: invalid TRB at 0x\(String(dequeue, radix: 16)); not consumed")
            return nil
        }

        let trbGPA = curGPA
        let trbType = trb.type
        let trbCycle = trb.cycle
        let trbParam = trb.parameter
        let trbStatus = trb.status
        let trbControl = trb.control
        let reqLen = trbStatus & 0x1FFFF
        let ent = (trbControl & (1 << 1)) != 0
        let isp = (trbControl & (1 << 2)) != 0
        let ch = (trbControl & (1 << 4)) != 0
        let ioc = (trbControl & (1 << 5)) != 0
        let idt = (trbControl & (1 << 6)) != 0

        guard trbCycle == curCycle else {
            return nil
        }
        guard trbType == 1 else {
            print("⚠️ FluxXHCI EP5: unsupported TRB type=\(trbType); not consumed")
            return nil
        }

        // Check if there is a pointer report to deliver
        guard let report = FluxHIDPointer.shared.peekReport() else {
            print("🔔 FluxXHCI EP5: Doorbell armed ring at 0x\(String(curGPA, radix: 16)) cycle=\(curCycle); waiting for pointer event")
            FluxHIDPointer.shared.notifyEP5Armed()
            return nil
        }

        print("[XHCI-EP5-CONTEXT] state=\(endpointState) type=\(epType) mps=\(mps) interval=\(interval) trdp=0x\(String(curGPA, radix: 16)) dcs=\(curCycle) avgTRB=\(avgTRBLength) maxESIT=\(maxESITPayload)")
        print("[XHCI-EP5-TRB] GPA=0x\(String(trbGPA, radix: 16)) type=\(trbType) cycle=\(trbCycle) dcs=\(curCycle) param=0x\(String(trbParam, radix: 16)) reqLen=\(reqLen) ENT=\(ent ? 1 : 0) ISP=\(isp ? 1 : 0) CH=\(ch ? 1 : 0) IOC=\(ioc ? 1 : 0) IDT=\(idt ? 1 : 0)")

        // Check if there is a chained Event Data TRB
        var isEventData = false
        var eventDataToken = trbGPA
        var finalPos = advanceTransferPointer(after: curGPA, cycle: curCycle)
        if ch {
            if let (nextGPA, nextCycle, nextTRB) = nextTransferTRB(after: curGPA, cycle: curCycle),
               nextTRB.cycle == nextCycle, nextTRB.type == 7 {
                isEventData = true
                eventDataToken = nextTRB.parameter
                finalPos = advanceTransferPointer(after: nextGPA, cycle: nextCycle)
                print("[XHCI-EP5-EVENTDATA] token=0x\(String(eventDataToken, radix: 16)) finalDequeue=0x\(String(finalPos.gpa, radix: 16)) cycle=\(finalPos.cycle)")
            }
        }

        let writeLen = min(report.count, Int(reqLen))
        guard writeLen > 0, let buf = ptr(trbParam, bytes: writeLen) else {
            print("⚠️ FluxXHCI EP5: invalid buffer GPA=0x\(String(trbParam, radix: 16)) len=\(writeLen); not consumed")
            return nil
        }
        report.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress!, byteCount: writeLen) }
        _ = FluxHIDPointer.shared.popReport()
        print("[XHCI-EP5-REPORT] wrote \(writeLen) bytes to buffer GPA=0x\(String(trbParam, radix: 16)) [\(report.map { String(format: "%02x", $0) }.joined(separator: " "))]")

        // Update TR Dequeue Pointer in Endpoint 5 Context
        let newDW2 = UInt32(truncatingIfNeeded: finalPos.gpa) | finalPos.cycle
        let newDW3 = UInt32(truncatingIfNeeded: finalPos.gpa >> 32)
        ep5.advanced(by: 8).storeBytes(of: newDW2.littleEndian, as: UInt32.self)
        ep5.advanced(by: 12).storeBytes(of: newDW3.littleEndian, as: UInt32.self)

        // Completion Code: Short Packet (13) if writeLen < reqLen, else Success (1)
        let compCode: UInt32 = (writeLen < Int(reqLen)) ? 13 : 1
        guard postTransferEventLocked(eventData: eventDataToken, completionCode: compCode,
                                      transferLength: UInt32(writeLen), slotID: 1, endpointID: 5,
                                      isEventData: isEventData) else {
            ep5.advanced(by: 8).storeBytes(of: epDW2.littleEndian, as: UInt32.self)
            ep5.advanced(by: 12).storeBytes(of: epDW3.littleEndian, as: UInt32.self)
            return nil
        }
        print("🔎 FluxXHCI EP5: Transfer complete code=\(compCode) len=\(writeLen) trdp=0x\(String(curGPA, radix: 16))->0x\(String(finalPos.gpa, radix: 16))")
        return prepareMSILocked()
    }

    private func transferTRB(_ gpa: UInt64) -> TransferTRB? {
        guard let trb = ptr(gpa, bytes: 16) else { return nil }
        return TransferTRB(gpa: gpa,
                           parameter: UInt64(littleEndian: trb.loadUnaligned(as: UInt64.self)),
                           status: UInt32(littleEndian: trb.advanced(by: 8).loadUnaligned(as: UInt32.self)),
                           control: UInt32(littleEndian: trb.advanced(by: 12).loadUnaligned(as: UInt32.self)))
    }

    /// Event Data Transfer Events report the Event Data token and the bytes
    /// actually transferred since the preceding Event Data boundary.
    private func postTransferEventLocked(eventData: UInt64, completionCode: UInt32,
                                         transferLength: UInt32, slotID: UInt8, endpointID: UInt8,
                                         isEventData: Bool = true) -> Bool {
        guard let entry = ptr(erstba, bytes: 16) else { return false }
        let base = UInt64(littleEndian: entry.loadUnaligned(as: UInt64.self))
        let count = UInt16(littleEndian: entry.advanced(by: 8).loadUnaligned(as: UInt16.self))
        guard count > 0, eventIndex < count,
              let event = ptr(base + UInt64(eventIndex) * 16, bytes: 16) else { return false }
        event.storeBytes(of: eventData.littleEndian, as: UInt64.self)
        event.advanced(by: 8).storeBytes(of: (transferLength | (completionCode << 24)).littleEndian, as: UInt32.self)
        let edBit: UInt32 = isEventData ? (1 << 2) : 0
        let control = ((UInt32(32) << 10) | edBit | (UInt32(endpointID) << 16) | (UInt32(slotID) << 24) | eventCycle).littleEndian
        event.advanced(by: 12).storeBytes(of: control, as: UInt32.self)
        print("🔎 FluxXHCI EVENT: Transfer eventData=0x\(String(eventData, radix: 16)) code=\(completionCode) length=\(transferLength) slot=\(slotID) endpoint=\(endpointID) ERST=0x\(String(base, radix: 16)) index=\(eventIndex) cycle=\(eventCycle)")
        eventIndex += 1
        if eventIndex == count { eventIndex = 0; eventCycle ^= 1 }
        iman |= 1
        pba |= 1
        return true
    }

    private func ptr(_ g: UInt64, bytes: Int) -> UnsafeMutableRawPointer? {
        guard bytes > 0, let host = guestHost, g >= guestBase else { return nil }
        let end = guestBase + UInt64(guestSize)
        guard g <= end, UInt64(bytes) <= end - g else { return nil }
        return host.advanced(by: Int(g - guestBase))
    }
    private func ptr(_ g:UInt64)->UnsafeMutableRawPointer? {guard let h=guestHost,g>=guestBase,g<guestBase+UInt64(guestSize) else{return nil};return h.advanced(by:Int(g-guestBase))}
    private func readMSIXLocked(_ o:UInt64,_ s:Int)->UInt64 {var r:UInt64=0;for i in 0..<s {r|=UInt64(msixByte(o+UInt64(i)))<<UInt64(i*8)};return r}
    private func msixByte(_ o:UInt64)->UInt8 {let v:UInt32;switch o {case 0..<4:v=table.lo;case 4..<8:v=table.hi;case 8..<12:v=table.data;case 12..<16:v=table.control;case 0x800..<0x808:return UInt8((pba>>((o-0x800)*8))&255);default:return 0};return UInt8((v>>UInt32((o&3)*8))&255)}
    private func writeMSIXLocked(_ o:UInt64,_ value:UInt64,_ s:Int){for i in 0..<s {let b=o+UInt64(i),x=UInt32((value>>UInt64(i*8))&255),sh=UInt32((b&3)*8);switch b {case 0..<4:table.lo=(table.lo & ~(255<<sh))|(x<<sh);case 4..<8:table.hi=(table.hi & ~(255<<sh))|(x<<sh);case 8..<12:table.data=(table.data & ~(255<<sh))|(x<<sh);case 12..<16:table.control=(table.control & ~(255<<sh))|(x<<sh);default:break}}}
    private func writeMSIXControl(_ o:UInt32,_ v:UInt64,_ s:Int){var c=msixControl;for i in 0..<s where o+UInt32(i)==Self.msixCap+2 || o+UInt32(i)==Self.msixCap+3 {let sh=UInt16((o+UInt32(i)-Self.msixCap-2)*8);c=(c & ~(UInt16(255)<<sh)) | (UInt16((v>>UInt64(i*8))&255)<<sh)};msixControl=c&0xc000;print("🔎 FluxXHCI MSI-X: enable=\(msixControl&0x8000 != 0) functionMask=\(msixControl&0x4000 != 0)")}
    private func prepareMSILocked()->Delivery? {guard msixControl&0x8000 != 0,msixControl&0x4000 == 0,!table.masked,pba&1 != 0 else{return nil};let a=hv_ipa_t(table.address);guard FluxGIC.validMSI(address:a,intid:table.data) else{return nil};pba &= ~1;return Delivery(address:a,data:table.data)}
    private func send(_ d:Delivery?){guard let d else{return};let r=hv_gic_send_msi(d.address,d.data);print("⚡️ FluxXHCI MSI-X: addr=0x\(String(d.address,radix:16)) data=\(d.data) -> \(r)");if secondResetTraceActive { traceSecondReset("MSI-X address=0x\(String(d.address, radix: 16)) data=\(d.data) result=\(r)") }}
    private func writeBAR(_ base:inout UInt64,_ sizing:inout Bool,_ o:UInt32,_ v:UInt64,_ s:Int,_ start:UInt32,_ mask:UInt32,_ name:String){if o==start && s==4 && UInt32(truncatingIfNeeded:v)==0xffffffff{sizing=true;return};sizing=false;var x=UInt32(base);for i in 0..<s where o+UInt32(i)<start+4 {let sh=UInt32((Int(o-start)+i)*8);x=(x & ~(255<<sh))|(UInt32((v>>UInt64(i*8))&255)<<sh)};base=UInt64(x&mask);print("📍 FluxXHCI: \(name) set to 0x\(String(base,radix:16))")}
    private func overlap(_ o:UInt32,_ s:Int,_ start:UInt32,_ len:UInt32)->Bool{o<start+len && o+UInt32(s)>start}
    private func trace(_ o:UInt32,_ v:UInt32,_ text:String){print("🔎 FluxXHCI MMIO WR: off=0x\(String(o,radix:16)) width=4 value=0x\(String(v,radix:16)) \(text)")}
    private func auditRead(_ space: String, _ offset: UInt32, _ size: Int, _ value: UInt64) { guard windowsAuditReads[offset] != value else { return }; windowsAuditReads[offset] = value; print("[XHCI-WINDOWS-AUDIT RD] \(space) off=0x\(String(offset,radix:16)) width=\(size) value=0x\(String(value,radix:16))") }
    private func traceSecondReset(_ message: String) {
        secondResetTraceSequence &+= 1
        print("[XHCI-SECOND-RESET #\(secondResetTraceSequence)] \(message)")
    }
    private func traceSecondResetContexts() {
        guard let dcbaa = ptr(dcbaap, bytes: 16) else {
            traceSecondReset("CONTEXT unavailable: DCBAAP=0x\(String(dcbaap, radix: 16))")
            return
        }
        let outputGPA = UInt64(littleEndian: dcbaa.advanced(by: 8).loadUnaligned(as: UInt64.self)) & ~UInt64(0x3F)
        guard let output = ptr(outputGPA, bytes: 64) else {
            traceSecondReset("CONTEXT unavailable: DCBAA[1]=0x\(String(outputGPA, radix: 16))")
            return
        }
        let slot = (0..<8).map { UInt32(littleEndian: output.advanced(by: $0 * 4).loadUnaligned(as: UInt32.self)) }
        let ep0 = (0..<8).map { UInt32(littleEndian: output.advanced(by: 0x20 + $0 * 4).loadUnaligned(as: UInt32.self)) }
        let trdp = (UInt64(ep0[2]) | UInt64(ep0[3] & 0xFFFFFFF0) << 32) & ~UInt64(0xF)
        let slotRaw = slot.map { String(format: "%08x", $0) }.joined(separator: ",")
        let ep0Raw = ep0.map { String(format: "%08x", $0) }.joined(separator: ",")
        traceSecondReset("OUTPUT slotRaw=\(slotRaw) state=\((slot[3] >> 27) & 0x1F) address=\(slot[3] & 0xFF) rootPort=\((slot[1] >> 16) & 0xFF) speed=\((slot[0] >> 20) & 0xF) entries=\((slot[0] >> 27) & 0x1F)")
        traceSecondReset("OUTPUT ep0Raw=\(ep0Raw) state=\(ep0[0] & 7) mps=\((ep0[1] >> 16) & 0xFFFF) trdp=0x\(String(trdp, radix: 16)) dcs=\(ep0[2] & 1) cerr=\((ep0[1] >> 1) & 3)")
        let slotState = slots[0]
        let portDescription = slotState.port.map(String.init) ?? "nil"
        traceSecondReset("HOST slot1 enabled=\(slotState.enabled) defaultContextReady=\(slotState.defaultContextReady) addressed=\(slotState.addressed) usbAddress=\(slotState.usbAddress) port=\(portDescription) PORTSC1=0x\(String(portSC(0), radix: 16))")
    }
}
