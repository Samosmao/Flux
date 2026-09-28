import Foundation
import Combine

/// Represents the virtual display framebuffer shared between the VM guest and the macOS Metal renderer.
public final class FluxFramebuffer: ObservableObject, @unchecked Sendable {

    public static let shared = FluxFramebuffer()

    private let lock = NSLock()

    @Published public private(set) var isConfigured: Bool = false
    @Published public private(set) var width: Int = 0
    @Published public private(set) var height: Int = 0
    @Published public private(set) var stride: Int = 0

    public private(set) var fourcc: UInt32 = 0
    public private(set) var guestAddress: UInt64 = 0
    public private(set) var hostPointer: UnsafeMutableRawPointer? = nil
    public private(set) var version: UInt64 = 0

    private init() {}

    /// Configures the framebuffer parameters received from firmware (e.g. QemuRamfbDxe).
    public func configure(
        guestAddress: UInt64,
        fourcc: UInt32,
        flags: UInt32,
        width: UInt32,
        height: UInt32,
        stride: UInt32,
        hostPointer: UnsafeMutableRawPointer
    ) {
        lock.lock()
        self.guestAddress = guestAddress
        self.fourcc = fourcc
        self.width = Int(width)
        self.height = Int(height)
        self.stride = Int(stride)
        self.hostPointer = hostPointer
        self.isConfigured = true
        self.version &+= 1
        lock.unlock()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }

        print("🖥️ [FluxFramebuffer] Configured: \(width)x\(height), stride=\(stride), guestAddr=0x\(String(guestAddress, radix: 16)), hostPtr=\(hostPointer)")
    }

    /// Drops the guest-memory pointer before the VM backing allocation is released.
    /// The Metal view can outlive a stopped VM by one or more display frames.
    public func invalidate() {
        lock.lock()
        guestAddress = 0
        width = 0
        height = 0
        stride = 0
        hostPointer = nil
        isConfigured = false
        version &+= 1
        lock.unlock()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    /// Safely copies the current configuration for the Metal rendering thread.
    public func snapshot() -> (isConfigured: Bool, width: Int, height: Int, stride: Int, hostPointer: UnsafeMutableRawPointer?, version: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (isConfigured, width, height, stride, hostPointer, version)
    }
}
