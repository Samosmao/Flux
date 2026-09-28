import SwiftUI

struct ContentView: View {

    private let engine = FluxEngine()
    @ObservedObject private var framebuffer = FluxFramebuffer.shared
    @State private var engineStarted = false

    var body: some View {
        VStack(spacing: 0) {
            if framebuffer.isConfigured {
                // Header status bar
                HStack {
                    Label("Windows 11 ARM64", systemImage: "display")
                        .font(.headline)

                    Spacer()

                    Text("\(framebuffer.width) × \(framebuffer.height)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Live (Metal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                // Native Metal MTKView
                FluxDisplayView()
                    .aspectRatio(CGFloat(max(1, framebuffer.width)) / CGFloat(max(1, framebuffer.height)), contentMode: .fit)
                    .frame(minWidth: 800, minHeight: 600)
                    .background(Color.black)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "cpu")
                        .font(.system(size: 64))

                    Text("Flux")
                        .font(.largeTitle)
                        .fontWeight(.semibold)

                    Text("Native ARM64 Virtualization")
                        .foregroundStyle(.secondary)

                    if engineStarted {
                        ProgressView("Booting VM & initializing display...")
                            .padding(.top, 8)
                    } else {
                        Button("Start Flux Engine") {
                            startEngine()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(width: 600, height: 400)
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["FLUX_RESET_DISK_VALIDATION"] == "1" {
                DispatchQueue.global(qos: .userInitiated).async {
                    let passed = engine.runResetDiskValidation()
                    exit(passed ? 0 : 1)
                }
            } else if CommandLine.arguments.contains("--benchmark-nvme") ||
               ProcessInfo.processInfo.environment["FLUX_BENCHMARK_NVME"] == "1" {
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = engine.runNVMeBenchmark(targetMB: 100)
                    exit(0)
                }
            } else if ProcessInfo.processInfo.environment["FLUX_MSIX_STRESS"] == "1" {
                DispatchQueue.global(qos: .userInitiated).async {
                    // 256 MiB / 128 KiB = exactly 2,048 real NVMe reads,
                    // after a separate disposable-image write pass.
                    _ = engine.runNVMeBenchmark(targetMB: 256)
                    exit(0)
                }
            } else if CommandLine.arguments.contains("--validate-nvme") ||
               ProcessInfo.processInfo.environment["FLUX_VALIDATE_NVME"] == "1" {
                DispatchQueue.global(qos: .userInitiated).async {
                    let passed = engine.validateNVMe()
                    exit(passed ? 0 : 1)
                }
            } else if ProcessInfo.processInfo.environment["FLUX_AUTO_START"] == "1" ||
               CommandLine.arguments.contains("--auto-start") {
                startEngine()
            }
        }
    }

    private func startEngine() {
        guard !engineStarted else { return }
        engineStarted = true
        DispatchQueue.global(qos: .userInitiated).async {
            engine.testHypervisor()
        }
    }
}

#Preview {
    ContentView()
}
