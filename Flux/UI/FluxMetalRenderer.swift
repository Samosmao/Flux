import Foundation
import MetalKit

final class FluxMetalRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var uploadBuffer: UnsafeMutableRawPointer?
    private var uploadBufferSize = 0

    deinit {
        uploadBuffer?.deallocate()
    }

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue
        super.init()

        setupPipeline()
    }

    private func setupPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            print("❌ [FluxMetalRenderer] Failed to load default Metal library")
            return
        }

        let vertexFunction = library.makeFunction(name: "displayVertexShader")
        let fragmentFunction = library.makeFunction(name: "displayFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("❌ [FluxMetalRenderer] Failed to create pipeline state: \(error)")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // View size changed; Metal handles viewport scaling
    }

    func draw(in view: MTKView) {
        let snap = FluxFramebuffer.shared.snapshot()
        guard snap.isConfigured,
              let hostPtr = snap.hostPointer,
              snap.width > 0,
              snap.height > 0 else {
            return
        }

        let width = snap.width
        let height = snap.height
        let stride = snap.stride > 0 ? snap.stride : (width * 4)
        let uploadSize = stride * height
        guard uploadSize > 0 else { return }

        // Guest RAM is a high-address Hypervisor mapping.  Metal's Debug
        // capture layer does not accept it directly as a replaceRegion source,
        // so stage the current frame in ordinary process-owned memory.
        if uploadBufferSize != uploadSize {
            uploadBuffer?.deallocate()
            uploadBuffer = UnsafeMutableRawPointer.allocate(byteCount: uploadSize, alignment: 64)
            uploadBufferSize = uploadSize
        }
        guard let uploadBuffer else { return }
        memcpy(uploadBuffer, hostPtr, uploadSize)

        // (Re)create texture if needed
        if texture == nil || texture?.width != width || texture?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.storageMode = .shared
            desc.usage = [.shaderRead]
            self.texture = device.makeTexture(descriptor: desc)
        }

        guard let texture = self.texture,
              let pipelineState = self.pipelineState,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }

        // Upload guest framebuffer pixels into Metal texture
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: uploadBuffer, bytesPerRow: stride)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)

        let viewWidth = view.bounds.width
        let viewHeight = view.bounds.height
        let drawableWidth = view.drawableSize.width
        let drawableHeight = view.drawableSize.height

        if viewWidth > 0 && viewHeight > 0 && drawableWidth > 0 && drawableHeight > 0 {
            let fbAspect = CGFloat(width) / CGFloat(height)
            let viewAspect = viewWidth / viewHeight
            let renderWidth: CGFloat
            let renderHeight: CGFloat
            let offsetX: CGFloat
            let offsetY: CGFloat
            if viewAspect > fbAspect {
                renderHeight = viewHeight
                renderWidth = viewHeight * fbAspect
                offsetX = (viewWidth - renderWidth) / 2.0
                offsetY = 0
            } else {
                renderWidth = viewWidth
                renderHeight = viewWidth / fbAspect
                offsetX = 0
                offsetY = (viewHeight - renderHeight) / 2.0
            }
            let scaleX = drawableWidth / viewWidth
            let scaleY = drawableHeight / viewHeight
            let viewport = MTLViewport(
                originX: Double(offsetX * scaleX),
                originY: Double(offsetY * scaleY),
                width: Double(renderWidth * scaleX),
                height: Double(renderHeight * scaleY),
                znear: 0.0,
                zfar: 1.0
            )
            encoder.setViewport(viewport)
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
