import Foundation
import Metal
import MetalKit
import simd

enum TransformMode { case none, rotate, scale, translate }
enum RendererError: Error { case sceneNotInitialized }

class Renderer: NSObject, MTKViewDelegate {

    let device:       MTLDevice
    let commandQueue: MTLCommandQueue
    let library:      MTLLibrary

    var projectPSO: MTLComputePipelineState?
    var renderPSO:  MTLRenderPipelineState?

    var splatVertexBuffer:  MTLBuffer?
    var cameraBuffer:       MTLBuffer?
    var quadIndexBuffer:    MTLBuffer?

    var scene:        Scene?
    var camera:       Camera
    var viewportSize: float2 = float2(800, 600)
    var frameCount:   UInt64 = 0
    var splatSettings = SplatSettings()

    /// Injected after construction. When isAnimating, mouse input is suppressed.
    weak var animationSystem: AnimationSystem?

    var activeTransformMode: TransformMode = .none
    private var sceneRot:   float3 = .zero
    private var sceneScale: Float  = 1.0
    private var sceneTrans: float3 = .zero
    private var lastMouse:  float2 = .zero
    private var lastSortFrame: UInt64 = 0
    private let sortInterval: UInt64 = 2   // sort every 2 frames — good balance of quality vs CPU cost

    private var modelMatrix: float4x4 {
        float4x4.translation(sceneTrans)
            * float4x4.rotationZ(sceneRot.z)
            * float4x4.rotationY(sceneRot.y)
            * float4x4.rotationX(sceneRot.x)
            * float4x4.scale(float3(repeating: sceneScale))
    }

    init?(metalKitView: MTKView) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let cq  = dev.makeCommandQueue() else { return nil }
        device = dev; commandQueue = cq

        guard let lib = try? dev.makeDefaultLibrary(bundle: .main) else {
            print("ERROR: could not load Metal library"); return nil
        }
        library = lib

        let aspect = Float(metalKitView.drawableSize.width) /
                     max(1, Float(metalKitView.drawableSize.height))
        camera = Camera(position: float3(0,0,5), target: .zero, aspectRatio: aspect)
        super.init()

        metalKitView.device                  = dev
        metalKitView.delegate                = self
        metalKitView.colorPixelFormat        = .bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat = .depth32Float
        metalKitView.framebufferOnly         = false
        metalKitView.preferredFramesPerSecond = 60

        buildPipelines()

        cameraBuffer = dev.makeBuffer(
            length: MemoryLayout<CameraUniforms>.stride * 3,
            options: .storageModeShared)

        var idx: [UInt32] = [0,1,2, 2,1,3]
        quadIndexBuffer = dev.makeBuffer(
            bytes: &idx,
            length: idx.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared)

        scene = Scene(device: dev)
        viewportSize = float2(Float(metalKitView.drawableSize.width),
                              Float(metalKitView.drawableSize.height))
    }

    private func buildPipelines() {
        // Compute: project splats
        if let fn = library.makeFunction(name: "projectSplats") {
            projectPSO = try? device.makeComputePipelineState(function: fn)
            print(projectPSO != nil ? "projectSplats PSO OK" : "ERROR: projectSplats PSO failed")
        } else {
            print("ERROR: projectSplats function not found in Metal library")
        }

        // Render: vertex + fragment
        guard let vfn = library.makeFunction(name: "splatVertex"),
              let ffn = library.makeFunction(name: "splatFragment") else {
            print("ERROR: splatVertex/splatFragment not found in Metal library"); return
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction   = vfn
        d.fragmentFunction = ffn
        d.colorAttachments[0].pixelFormat    = .bgra8Unorm_srgb
        d.depthAttachmentPixelFormat         = .depth32Float

        // Premultiplied-alpha blending
        let ca = d.colorAttachments[0]!
        ca.isBlendingEnabled           = true
        ca.rgbBlendOperation           = .add
        ca.alphaBlendOperation         = .add
        ca.sourceRGBBlendFactor        = .one
        ca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor      = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        renderPSO = try? device.makeRenderPipelineState(descriptor: d)
        print(renderPSO != nil ? "Render PSO OK" : "ERROR: Render PSO failed")
    }

    func loadScene(from url: URL) throws {
        guard let scene else { throw RendererError.sceneNotInitialized }
        try scene.load(from: url)

        let r = max(scene.radius, 0.5)
        print("Scene loaded — center: \(scene.center), radius: \(r)")

        camera.target    = scene.center
        camera.distance  = r * 2.5
        camera.azimuth   = 0
        camera.elevation = 0.3
        camera.updateMatrices()
        print("Camera distance set to: \(camera.distance)")

        splatVertexBuffer = device.makeBuffer(
            length: MemoryLayout<SplatVertex>.stride * scene.splatCount,
            options: .storageModePrivate)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize       = float2(Float(size.width), Float(size.height))
        camera.aspectRatio = Float(size.width) / max(1, Float(size.height))
        camera.updateMatrices()
    }

    func draw(in view: MTKView) {
        guard let scene, scene.isLoaded,
              let splatBuf  = scene.splatBuffer,
              let vertBuf   = splatVertexBuffer,
              let camBuf    = cameraBuffer,
              let idxBuf    = quadIndexBuffer,
              let rpd       = view.currentRenderPassDescriptor,
              let drawable  = view.currentDrawable,
              let cb        = commandQueue.makeCommandBuffer()
        else { return }

        frameCount += 1

        // Upload camera uniforms
        var uni = camera.getUniforms(screenSize: viewportSize)
        uni.modelMatrix = modelMatrix
        let off = Int(frameCount % 3) * MemoryLayout<CameraUniforms>.stride
        memcpy(camBuf.contents().advanced(by: off), &uni, MemoryLayout<CameraUniforms>.stride)

        // Sort splats back-to-front every frame for correct alpha blending.
        // Splat positions are stored in model-local space, so we must bring the
        // camera into that same space via the inverse model matrix.
        if frameCount - lastSortFrame >= sortInterval {
            let mm = modelMatrix
            let invModel = mm.inverse

            // Camera position in model-local space
            let camPosLocal = (invModel * float4(camera.position.x,
                                                 camera.position.y,
                                                 camera.position.z, 1)).xyz

            // Camera forward in model-local space (no translation needed for direction)
            let vm = camera.viewMatrix
            let fwdWorld = normalize(-float3(vm.columns.2.x, vm.columns.2.y, vm.columns.2.z))
            let fwdLocal = normalize((invModel * float4(fwdWorld.x, fwdWorld.y, fwdWorld.z, 0)).xyz)

            scene.sortSplats(cameraPosition: camPosLocal, forward: fwdLocal)
            lastSortFrame = frameCount
        }

        let count = UInt32(scene.splatCount)

        // Pass 1: project (compute)
        if let pso = projectPSO, let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pso)
            enc.setBuffer(splatBuf, offset: 0,   index: 0)
            enc.setBuffer(vertBuf,  offset: 0,   index: 1)
            enc.setBuffer(camBuf,   offset: off, index: 2)
            var n = count
            enc.setBytes(&n, length: 4, index: 3)
            enc.dispatchThreadgroups(
                MTLSize(width: (Int(count)+255)/256, height:1, depth:1),
                threadsPerThreadgroup: MTLSize(width:256, height:1, depth:1))
            enc.endEncoding()
        }

        // Pass 2: render quads
        let bg = splatSettings
        rpd.colorAttachments[0].clearColor  = MTLClearColor(
            red: Double(bg.bgColorR), green: Double(bg.bgColorG),
            blue: Double(bg.bgColorB), alpha: 1)
        rpd.colorAttachments[0].loadAction  = .clear
        rpd.colorAttachments[0].storeAction = .store

        if let pso = renderPSO, let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(pso)
            enc.setVertexBuffer(vertBuf, offset: 0,   index: 0)
            enc.setVertexBuffer(camBuf,  offset: off, index: 1)
            enc.drawIndexedPrimitives(
                type: .triangle, indexCount: 6, indexType: .uint32,
                indexBuffer: idxBuf, indexBufferOffset: 0,
                instanceCount: Int(count))
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()
    }

    func handleMouseDown(at p: NSPoint, button: MouseButton) {
        guard animationSystem?.isAnimating != true else { return }
        lastMouse = float2(Float(p.x), Float(p.y))
        camera.mouseDown(at: lastMouse)
    }
    func handleMouseDrag(to p: NSPoint, button: MouseButton) {
        guard animationSystem?.isAnimating != true else { return }
        let pos = float2(Float(p.x), Float(p.y))
        let d   = pos - lastMouse; lastMouse = pos
        if activeTransformMode != .none {
            switch activeTransformMode {
            case .rotate:    sceneRot.y += d.x*0.005; sceneRot.x += d.y*0.005
            case .scale:     sceneScale = max(0.01,min(100,sceneScale*(1+d.y*0.005)))
            case .translate: sceneTrans.x += d.x*0.01*camera.distance
                             sceneTrans.y -= d.y*0.01*camera.distance
            case .none: break
            }
            return
        }
        camera.mouseDrag(to: pos, button: button)
    }
    func handleMouseUp()               { camera.mouseUp() }
    func handleScroll(deltaY: CGFloat) { camera.scroll(deltaY: Float(deltaY)) }
    func resetSceneTransform()         { sceneRot = .zero; sceneScale = 1; sceneTrans = .zero }
}
