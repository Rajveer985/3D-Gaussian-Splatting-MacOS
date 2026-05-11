import Foundation
import Metal
import MetalKit
import simd

enum TransformMode { case none, rotate, scale, translate }
enum RendererError: Error { case sceneNotInitialized }

class Renderer: NSObject, MTKViewDelegate {

    // MARK: - Metal objects
    let device:       MTLDevice
    let commandQueue: MTLCommandQueue
    let library:      MTLLibrary

    var projectPSO:      MTLComputePipelineState?
    var initIndexPSO:    MTLComputePipelineState?
    var radixCountPSO:   MTLComputePipelineState?
    var prefixSumPSO:    MTLComputePipelineState?
    var radixScatterPSO: MTLComputePipelineState?
    var renderPSO:       MTLRenderPipelineState?
    var depthStencilState: MTLDepthStencilState?

    // MARK: - Buffers
    var splatVertexBuffer: MTLBuffer?
    var depthKeyBuffer:    MTLBuffer?   // storageModeShared — CPU reads histogram
    var sortIndexBufA:     MTLBuffer?   // ping-pong A
    var sortIndexBufB:     MTLBuffer?   // ping-pong B
    var histogramBuffer:   MTLBuffer?   // 256 × uint32, storageModeShared
    var cameraBuffer:      MTLBuffer?
    var settingsBuffer:    MTLBuffer?
    var quadIndexBuffer:   MTLBuffer?

    // MARK: - State
    var scene:        Scene?
    var camera:       Camera
    var viewportSize: float2 = float2(800, 600)
    var frameCount:   UInt64 = 0
    var splatSettings = SplatSettings()

    /// Injected after construction. When isAnimating is true, mouse input is suppressed.
    weak var animationSystem: AnimationSystem?

    var activeTransformMode: TransformMode = .none
    private var sceneRotation:    float3 = .zero
    private var sceneScale:       Float  = 1.0
    private var sceneTranslation: float3 = .zero
    private var lastTransformMousePosition: float2 = .zero

    private var computeThreadgroupWidth = 512

    // Sort-skip optimisation: only re-sort when camera moves enough to matter.
    // Small epsilon = sort fires on every meaningful camera movement = less jitter.
    // Large epsilon = fewer sorts = better perf but more stale-order artifacts.
    private var lastSortCamPos:     float3 = float3(repeating: .infinity)
    private var lastSortCamForward: float3 = float3(0, 0, -1)
    private let sortEpsilon: Float = 0.0001  // tight epsilon — fat splats (0.6f LPF) need more frequent sorts during manual nav
    private var sortedIndexBuffer:  MTLBuffer?  // last sorted result buffer

    private var modelMatrix: float4x4 {
        float4x4.translation(sceneTranslation)
            * float4x4.rotationZ(sceneRotation.z)
            * float4x4.rotationY(sceneRotation.y)
            * float4x4.rotationX(sceneRotation.x)
            * float4x4.scale(float3(repeating: sceneScale))
    }

    // MARK: - Init

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

        metalKitView.device                   = dev
        metalKitView.delegate                 = self
        metalKitView.colorPixelFormat         = .bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat  = .depth32Float
        metalKitView.framebufferOnly          = false
        metalKitView.preferredFramesPerSecond = 60  // sort-skip means still frames are free

        buildPipelines()

        cameraBuffer = dev.makeBuffer(
            length: MemoryLayout<CameraUniforms>.stride * 3,
            options: .storageModeShared)
        settingsBuffer = dev.makeBuffer(
            length: MemoryLayout<SplatSettings>.stride,
            options: .storageModeShared)
        histogramBuffer = dev.makeBuffer(
            length: 256 * MemoryLayout<UInt32>.stride,
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

    // MARK: - Pipeline setup

    private func buildPipelines() {
        func makePSO(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: name) else {
                print("✗ Metal function '\(name)' not found"); return nil
            }
            guard let pso = try? device.makeComputePipelineState(function: fn) else {
                print("✗ PSO failed for '\(name)'"); return nil
            }
            print("✓ \(name)")
            return pso
        }

        projectPSO      = makePSO("projectSplats")
        initIndexPSO    = makePSO("initSortIndices")
        radixCountPSO   = makePSO("radixCount")
        prefixSumPSO    = makePSO("prefixSum")
        radixScatterPSO = makePSO("radixScatter")

        if let pso = projectPSO {
            computeThreadgroupWidth = min(pso.maxTotalThreadsPerThreadgroup, 1024)
        }

        guard let vfn = library.makeFunction(name: "splatVertex"),
              let ffn = library.makeFunction(name: "splatFragment") else {
            print("✗ splatVertex/splatFragment not found"); return
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction             = vfn
        d.fragmentFunction           = ffn
        d.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        d.depthAttachmentPixelFormat      = .depth32Float

        let ca = d.colorAttachments[0]!
        ca.isBlendingEnabled           = true
        ca.rgbBlendOperation           = .add
        ca.alphaBlendOperation         = .add
        // Premultiplied alpha blending — fragment shader outputs color*alpha in RGB.
        // out.rgb = src.rgb + dst.rgb * (1 - src.a)  — correct over-compositing.
        ca.sourceRGBBlendFactor        = .one
        ca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor      = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        renderPSO = try? device.makeRenderPipelineState(descriptor: d)
        print(renderPSO != nil ? "✓ Render PSO" : "✗ Render PSO failed")

        // Depth stencil: NEVER write depth (splats are transparent, sorted back-to-front).
        // Compare = always (all fragments pass — sorting handles draw order).
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.isDepthWriteEnabled  = false
        dsDesc.depthCompareFunction = .always
        depthStencilState = device.makeDepthStencilState(descriptor: dsDesc)
        print(depthStencilState != nil ? "✓ Depth stencil state (write=off)" : "✗ Depth stencil state failed")
    }

    // MARK: - Scene loading

    func loadScene(from url: URL) throws {
        guard let scene else { throw RendererError.sceneNotInitialized }
        try scene.load(from: url)

        let r = max(scene.radius, 0.5)
        print("Scene loaded — center: \(scene.center), radius: \(r)")

        camera.target    = scene.center
        // Use a clamped distance — don't let sky dome splats push the camera
        // hundreds of units away. Cap at 20 units for initial view.
        camera.distance  = min(r * 2.5, 20.0)
        camera.azimuth   = 0
        camera.elevation = 0.3
        camera.updateMatrices()

        // Auto-set maxScaleThreshold based on the scene's actual scale distribution.
        // Use a partial sort (O(n) nth_element equivalent) — avoid full sort on 1M splats.
        // Strategy: sample 10k splats randomly, find p99 of that sample.
        // This is fast (microseconds) and accurate enough for threshold setting.
        let allSplats = scene.splats
        let sampleSize = min(10_000, allSplats.count)
        let stride = max(1, allSplats.count / sampleSize)
        var sample = [Float]()
        sample.reserveCapacity(sampleSize)
        var i = 0
        while i < allSplats.count {
            let s = allSplats[i].scale
            sample.append(max(s.x, max(s.y, s.z)))
            i += stride
        }
        sample.sort()
        if !sample.isEmpty {
            let p99 = sample[Int(Float(sample.count) * 0.99)]
            // Use p99 * 3 for outdoor scenes (sky dome needs more headroom).
            // The soft fade in the shader handles the transition gracefully.
            splatSettings.maxScaleThreshold = p99 * 3.0
            print("Scale threshold auto-set: p99=\(p99), threshold=\(splatSettings.maxScaleThreshold)")
        }

        allocatePerSceneBuffers(count: scene.splatCount)
        // Reset sort state so first frame always sorts
        sortedIndexBuffer  = nil
        lastSortCamPos     = float3(repeating: .infinity)
        lastSortCamForward = float3(0, 0, -1)
    }

    private func allocatePerSceneBuffers(count: Int) {
        splatVertexBuffer = device.makeBuffer(
            length: MemoryLayout<SplatVertex>.stride * count,
            options: .storageModePrivate)
        // Shared so CPU can read depth keys for histogram prefix sums
        depthKeyBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride * count,
            options: .storageModeShared)
        sortIndexBufA = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride * count,
            options: .storageModeShared)
        sortIndexBufB = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride * count,
            options: .storageModeShared)
        print("Per-scene GPU buffers allocated for \(count) splats")
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize       = float2(Float(size.width), Float(size.height))
        camera.aspectRatio = Float(size.width) / max(1, Float(size.height))
        camera.updateMatrices()
    }

    // MARK: - Draw

    func draw(in view: MTKView) {
        guard let scene, scene.isLoaded,
              let splatBuf  = scene.splatBuffer,
              let vertBuf   = splatVertexBuffer,
              let depthBuf  = depthKeyBuffer,
              let bufA      = sortIndexBufA,
              let bufB      = sortIndexBufB,
              let histBuf   = histogramBuffer,
              let camBuf    = cameraBuffer,
              let setsBuf   = settingsBuffer,
              let idxBuf    = quadIndexBuffer,
              let rpd       = view.currentRenderPassDescriptor,
              let drawable  = view.currentDrawable
        else { return }

        frameCount += 1
        let count = UInt32(scene.splatCount)

        // Upload camera uniforms (triple-buffered)
        var uni = camera.getUniforms(screenSize: viewportSize)
        uni.modelMatrix = modelMatrix

        splatSettings.farClip  = min(max(camera.distance * 20.0, 50.0), 2000.0)
        splatSettings.nearClip = 0.01

        let camOff = Int(frameCount % 3) * MemoryLayout<CameraUniforms>.stride
        memcpy(camBuf.contents().advanced(by: camOff), &uni, MemoryLayout<CameraUniforms>.stride)
        var settings = splatSettings
        memcpy(setsBuf.contents(), &settings, MemoryLayout<SplatSettings>.stride)

        // Decide if we need to sort this frame
        let camForward = -float3(uni.viewMatrix[0].z, uni.viewMatrix[1].z, uni.viewMatrix[2].z)
        let posDelta   = simd_length(camera.position - lastSortCamPos)
        let dirDelta   = 1.0 - simd_dot(camForward, lastSortCamForward)
        let isAnimating = animationSystem?.engine.isPlaying == true
        let needsSort   = isAnimating
                       || sortedIndexBuffer == nil
                       || posDelta > sortEpsilon
                       || dirDelta > sortEpsilon

        // ── Single command buffer for the entire frame ────────────────────────
        // Metal automatically synchronizes resources between encoders in the
        // same command buffer — no waitUntilCompleted() needed between passes.
        guard let cb = commandQueue.makeCommandBuffer() else { return }

        // ── Pass 1: Project splats → SplatVertex[] + depth keys ──────────────
        if let pso = projectPSO, let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pso)
            enc.setBuffer(splatBuf, offset: 0,      index: 0)
            enc.setBuffer(vertBuf,  offset: 0,      index: 1)
            enc.setBuffer(camBuf,   offset: camOff, index: 2)
            var n = count
            enc.setBytes(&n, length: 4,             index: 3)
            enc.setBuffer(setsBuf,  offset: 0,      index: 4)
            enc.setBuffer(depthBuf, offset: 0,      index: 5)
            enc.dispatchThreads(
                MTLSize(width: Int(count), height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: computeThreadgroupWidth, height: 1, depth: 1))
            enc.endEncoding()
        }

        // ── Pass 2: Radix sort (4 passes, fully on GPU) ───────────────────────
        if needsSort {
            lastSortCamPos     = camera.position
            lastSortCamForward = camForward

            // Init sort indices
            if let pso = initIndexPSO, let enc = cb.makeComputeCommandEncoder() {
                enc.setComputePipelineState(pso)
                enc.setBuffer(bufA, offset: 0, index: 0)
                var n = count
                enc.setBytes(&n, length: 4, index: 1)
                enc.dispatchThreads(
                    MTLSize(width: Int(count), height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: computeThreadgroupWidth, height: 1, depth: 1))
                enc.endEncoding()
            }

            var pingIn  = bufA
            var pingOut = bufB

            // 4 passes × 8 bits = 32-bit sort, fully GPU, zero CPU stalls
            for pass in 0..<4 {
                let shift = UInt32(pass * 8)

                // Clear histogram
                if let blit = cb.makeBlitCommandEncoder() {
                    blit.fill(buffer: histBuf, range: 0..<histBuf.length, value: 0)
                    blit.endEncoding()
                }

                // Count
                if let pso = radixCountPSO, let enc = cb.makeComputeCommandEncoder() {
                    enc.setComputePipelineState(pso)
                    enc.setBuffer(depthBuf, offset: 0, index: 0)
                    enc.setBuffer(pingIn,   offset: 0, index: 1)
                    enc.setBuffer(histBuf,  offset: 0, index: 2)
                    var n = count; enc.setBytes(&n, length: 4, index: 3)
                    var s = shift; enc.setBytes(&s, length: 4, index: 4)
                    enc.dispatchThreads(
                        MTLSize(width: Int(count), height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: computeThreadgroupWidth, height: 1, depth: 1))
                    enc.endEncoding()
                }

                // GPU prefix sum — serial scan by 1 thread, foolproof correctness
                if let pso = prefixSumPSO, let enc = cb.makeComputeCommandEncoder() {
                    enc.setComputePipelineState(pso)
                    enc.setBuffer(histBuf, offset: 0, index: 0)
                    // 1 thread — serial scan over 256 buckets
                    enc.dispatchThreadgroups(
                        MTLSize(width: 1, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
                    enc.endEncoding()
                }

                // Scatter
                if let pso = radixScatterPSO, let enc = cb.makeComputeCommandEncoder() {
                    enc.setComputePipelineState(pso)
                    enc.setBuffer(depthBuf, offset: 0, index: 0)
                    enc.setBuffer(pingIn,   offset: 0, index: 1)
                    enc.setBuffer(pingOut,  offset: 0, index: 2)
                    enc.setBuffer(histBuf,  offset: 0, index: 3)
                    var n = count; enc.setBytes(&n, length: 4, index: 4)
                    var s = shift; enc.setBytes(&s, length: 4, index: 5)
                    enc.dispatchThreads(
                        MTLSize(width: Int(count), height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: computeThreadgroupWidth, height: 1, depth: 1))
                    enc.endEncoding()
                }

                swap(&pingIn, &pingOut)
            }
            sortedIndexBuffer = pingIn
        }

        let sortedBuf = sortedIndexBuffer ?? bufA

        // ── Pass 3: Render quads in sorted order ──────────────────────────────
        rpd.colorAttachments[0].clearColor = MTLClearColor(
            red:   Double(splatSettings.bgColorR),
            green: Double(splatSettings.bgColorG),
            blue:  Double(splatSettings.bgColorB),
            alpha: 1)
        rpd.colorAttachments[0].loadAction  = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.loadAction  = .clear
        rpd.depthAttachment.storeAction = .dontCare   // never read depth back → don't waste bandwidth

        if let pso = renderPSO, let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(pso)
            if let dss = depthStencilState {
                enc.setDepthStencilState(dss)
            }
            enc.setVertexBuffer(sortedBuf, offset: 0,      index: 0)
            enc.setVertexBuffer(vertBuf,   offset: 0,      index: 1)
            enc.setVertexBuffer(camBuf,    offset: camOff, index: 2)
            enc.setVertexBuffer(setsBuf,   offset: 0,      index: 3)
            enc.drawIndexedPrimitives(
                type: .triangle, indexCount: 6, indexType: .uint32,
                indexBuffer: idxBuf, indexBufferOffset: 0,
                instanceCount: Int(count))
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()
    }

    // MARK: - Input handling

    func handleMouseDown(at p: NSPoint, button: MouseButton) {
        guard animationSystem?.isAnimating != true else { return }
        let pos = float2(Float(p.x), Float(p.y))
        lastTransformMousePosition = pos
        camera.mouseDown(at: pos)
    }

    func handleMouseDrag(to p: NSPoint, button: MouseButton) {
        guard animationSystem?.isAnimating != true else { return }
        let pos   = float2(Float(p.x), Float(p.y))
        let delta = pos - lastTransformMousePosition
        lastTransformMousePosition = pos

        if activeTransformMode != .none {
            switch activeTransformMode {
            case .rotate:
                sceneRotation.y += delta.x * 0.005
                sceneRotation.x += delta.y * 0.005
            case .scale:
                sceneScale = max(0.01, min(100, sceneScale * (1 + delta.y * 0.005)))
            case .translate:
                // Original move tool math — unchanged.
                sceneTranslation.x += delta.x * 0.01 * camera.distance
                sceneTranslation.y -= delta.y * 0.01 * camera.distance
                // Silently sync camera.target so AnimationSystem can keyframe the position.
                // This does NOT change how the move tool feels — it only keeps targetX/Y/Z
                // in sync so "Set All" captures the translated position correctly.
                camera.target.x -= delta.x * 0.01 * camera.distance
                camera.target.y += delta.y * 0.01 * camera.distance
                camera.updateMatrices()
            case .none: break
            }
            return
        }
        camera.mouseDrag(to: pos, button: button)
    }

    func handleMouseUp()               { camera.mouseUp() }
    func handleScroll(deltaY: CGFloat) { camera.scroll(deltaY: Float(deltaY)) }

    func resetSceneTransform() {
        sceneRotation    = .zero
        sceneScale       = 1.0
        sceneTranslation = .zero
        // Reset camera target back to scene center
        if let scene = scene {
            camera.target = scene.center
            camera.updateMatrices()
        }
    }
}
