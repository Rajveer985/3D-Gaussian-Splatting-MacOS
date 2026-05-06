import Foundation
import Metal
import MetalKit
import simd

class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    
    var computePipelineState: MTLComputePipelineState?
    var renderPipelineState: MTLRenderPipelineState?
    
    var cameraUniformsBuffer: MTLBuffer?
    var quadIndexBuffer: MTLBuffer?
    
    var scene: Scene?
    var camera: Camera

    /// Weak reference to the animation system. Injected after construction.
    /// When isAnimating is true, mouse/keyboard input is suppressed.
    weak var animationSystem: AnimationSystem?

    var viewportSize: float2 = float2(800, 600)
    var frameCount: UInt64 = 0
    
    init?(metalKitView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        let metalPath = Bundle.module.url(
            forResource: "GaussianSplat",
            withExtension: "metal",
            subdirectory: "Shaders"
        ) ?? URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("../Shaders/GaussianSplat.metal")
            .standardizedFileURL
        
        do {
            let source = try String(contentsOf: metalPath, encoding: .utf8)
            self.library = try device.makeLibrary(source: source, options: nil)
        } catch {
            print("Failed to compile Metal library: \(error)")
            return nil
        }
        
        self.camera = Camera(
            position: float3(0, 0, 5),
            target: .zero,
            aspectRatio: 1.0
        )
        
        super.init()
        
        metalKitView.device = device
        metalKitView.delegate = self
        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat = .depth32Float
        metalKitView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        
        self.scene = Scene(device: device)
        
        createComputePipeline()
        createRenderPipeline()
        createBuffers()
    }
    
    private func createComputePipeline() {
        guard let computeFunction = library.makeFunction(name: "projectGaussians") else { return }
        do {
            computePipelineState = try device.makeComputePipelineState(function: computeFunction)
        } catch {
            print("Failed to create compute pipeline: \(error)")
        }
    }
    
    private func createRenderPipeline() {
        guard let vertexFunction = library.makeFunction(name: "gaussianVertex"),
              let fragmentFunction = library.makeFunction(name: "gaussianFragment") else { return }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        
        let colorAttachment = pipelineDescriptor.colorAttachments[0]!
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        colorAttachment.sourceRGBBlendFactor = .sourceAlpha
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        
        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create render pipeline: \(error)")
        }
    }
    
    private func createBuffers() {
        cameraUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<CameraUniforms>.stride * 3,
            options: .storageModeShared
        )
        
        let indices: [UInt16] = [0, 1, 2, 2, 1, 3]
        quadIndexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt16>.stride,
            options: .storageModeShared
        )
    }
    
    func loadScene(from url: URL) {
        guard let scene = scene else { return }
        do {
            try scene.load(from: url)
            camera.focus(on: scene.center, radius: scene.radius)
            camera.aspectRatio = viewportSize.x / viewportSize.y
        } catch {
            print("Failed to load scene: \(error)")
        }
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = float2(Float(size.width), Float(size.height))
        camera.aspectRatio = Float(size.width) / Float(size.height)
    }
    
    func draw(in view: MTKView) {
        guard let renderPipelineState = renderPipelineState,
              let computePipelineState = computePipelineState,
              let scene = scene,
              scene.isLoaded,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }
        
        frameCount += 1
        updateCameraUniforms()
        
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            computeEncoder.setComputePipelineState(computePipelineState)
            
            if let splatBuffer = scene.splatBuffer,
               let projectedBuffer = scene.projectedBuffer {
                computeEncoder.setBuffer(splatBuffer, offset: 0, index: 0)
                computeEncoder.setBuffer(projectedBuffer, offset: 0, index: 1)
                
                let uniformOffset = Int(frameCount % 3) * MemoryLayout<CameraUniforms>.stride
                computeEncoder.setBuffer(cameraUniformsBuffer, offset: uniformOffset, index: 2)
                
                var count = UInt32(scene.splatCount)
                computeEncoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
                
                let threadGroupSize = MTLSize(width: 256, height: 1, depth: 1)
                let threadGroups = MTLSize(
                    width: (scene.splatCount + 255) / 256,
                    height: 1,
                    depth: 1
                )
                computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            }
            
            computeEncoder.endEncoding()
        }
        
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            renderEncoder.setRenderPipelineState(renderPipelineState)
            
            if let projectedBuffer = scene.projectedBuffer {
                renderEncoder.setVertexBuffer(projectedBuffer, offset: 0, index: 0)
                
                let uniformOffset = Int(frameCount % 3) * MemoryLayout<CameraUniforms>.stride
                renderEncoder.setVertexBuffer(cameraUniformsBuffer, offset: uniformOffset, index: 1)
            }
            
            if let indexBuffer = quadIndexBuffer {
                renderEncoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: 6,
                    indexType: .uint16,
                    indexBuffer: indexBuffer,
                    indexBufferOffset: 0,
                    instanceCount: scene.splatCount
                )
            }
            
            renderEncoder.endEncoding()
        }
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func updateCameraUniforms() {
        guard let buffer = cameraUniformsBuffer else { return }
        
        var uniforms = camera.getUniforms(screenSize: viewportSize)
        let offset = Int(frameCount % 3) * MemoryLayout<CameraUniforms>.stride
        
        memcpy(buffer.contents().advanced(by: offset), &uniforms, MemoryLayout<CameraUniforms>.stride)
    }
    
    func handleMouseDown(at point: NSPoint, button: MouseButton) {
        guard animationSystem?.isAnimating != true else { return }
        let pos = float2(Float(point.x), Float(point.y))
        camera.mouseDown(at: pos)
    }
    
    func handleMouseDrag(to point: NSPoint, button: MouseButton) {
        guard animationSystem?.isAnimating != true else { return }
        let pos = float2(Float(point.x), Float(point.y))
        camera.mouseDrag(to: pos, button: button)
    }
    
    func handleMouseUp() {
        camera.mouseUp()
    }
    
    func handleScroll(deltaY: CGFloat) {
        camera.scroll(deltaY: Float(deltaY))
    }
}
