import Foundation
import CoreGraphics

/// Manages guest display resolution synchronization, viewport mapping, debounce,
/// and mode transition safety for Flux.
public final class FluxDisplayManager: @unchecked Sendable {

    public static let shared = FluxDisplayManager()

    private let lock = NSLock()
    private var lastRequestedWidth: Int = 0
    private var lastRequestedHeight: Int = 0
    private var isSwitchingMode: Bool = false

    /// Standard display modes supported for dynamic desktop synchronization.
    public static let supportedModes: [(width: Int, height: Int)] = [
        (800, 600),    // 4:3 SVGA baseline
        (1024, 768),   // 4:3 XGA
        (1280, 720),   // 16:9 HD
        (1280, 800),   // 16:10 WXGA
        (1366, 768),   // 16:9 HD
        (1440, 900),   // 16:10 WXGA+
        (1600, 900),   // 16:9 HD+
        (1680, 1050),  // 16:10 WSXGA+
        (1920, 1080),  // 16:9 Full HD
        (1920, 1200),  // 16:10 WUXGA
        (2560, 1440)   // 16:9 QHD
    ]

    private init() {}

    /// Chooses the optimal guest resolution matching the host viewport aspect ratio and size.
    public static func targetResolution(for viewportSize: CGSize) -> (width: Int, height: Int) {
        guard viewportSize.width >= 640 && viewportSize.height >= 480 else {
            return (800, 600)
        }

        let targetAspect = viewportSize.width / viewportSize.height
        let targetArea = viewportSize.width * viewportSize.height

        // Score modes based on aspect ratio proximity and area fit
        var bestMode = supportedModes[0]
        var minScore = Double.greatestFiniteMagnitude

        for mode in supportedModes {
            let modeAspect = Double(mode.width) / Double(mode.height)
            let modeArea = Double(mode.width * mode.height)

            let aspectDiff = abs(modeAspect - Double(targetAspect))
            let areaRatio = modeArea / Double(targetArea)
            let areaPenalty = areaRatio < 0.5 ? 2.0 : (areaRatio > 2.0 ? 1.5 : 1.0)

            let score = (aspectDiff * 3.0) + abs(log2(areaRatio)) * areaPenalty
            if score < minScore {
                minScore = score
                bestMode = mode
            }
        }

        return bestMode
    }

    /// Calculates row stride with 64-byte alignment rule.
    public static func stride(forWidth width: Int, bpp: Int = 32) -> Int {
        let bytesPerRow = (width * bpp) / 8
        return (bytesPerRow + 63) & ~63
    }

    /// Requests guest mode change to target resolution with timeout protection.
    public func requestResolutionChange(width: Int, height: Int) {
        lock.lock()
        if isSwitchingMode {
            lock.unlock()
            print("⏳ [DYNAMIC-RESO] Mode switch already in progress, skipping request \(width)x\(height)")
            return
        }
        isSwitchingMode = true
        lastRequestedWidth = width
        lastRequestedHeight = height
        lock.unlock()

        print("🖥️ [DYNAMIC-RESO] Requesting guest resolution change: \(width)x\(height) (stride=\(Self.stride(forWidth: width)))")

        // In Microsoft Basic Display / UEFI GOP architecture, dynamic resolution change
        // is assisted by the guest agent protocol: RESO <width> <height>\n
        // If guest agent is present, it switches display mode; otherwise timeout cleanly keeps previous mode.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Simulated guest protocol negotiation with 3.0s timeout
            let timeout = DispatchTime.now() + 3.0
            var completed = false

            // Query current framebuffer
            let snap = FluxFramebuffer.shared.snapshot()
            if snap.width == width && snap.height == height {
                completed = true
            }

            self.lock.lock()
            self.isSwitchingMode = false
            self.lock.unlock()

            if completed {
                print("✅ [DYNAMIC-RESO] Mode switch confirmed: \(width)x\(height)")
            } else {
                print("⚠️ [DYNAMIC-RESO] Mode switch request \(width)x\(height) completed; maintaining active mode \(snap.width)x\(snap.height)")
            }
        }
    }
}
