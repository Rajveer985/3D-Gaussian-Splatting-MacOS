import Foundation
import Metal
import MetalKit
import simd

enum TransformMode {
    case none, rotate, scale, translate
}

enum RendererError: Error {
    case sceneNotInitialized
    case pipelineCreationFailed
}

class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    // Compute pipeline states
    var projectPSO: MTLComputePipelineState?
    var binningPSO: MTLComputePipelineState?
    var sortPSO:    MTLComputePipelineState?
    var renderPSO:  MTLComputePipelineState?

    // Buffers
    var cameraUniformsBuffer: MTLBuffer?
    let cameraUniformStride = ((MemoryLayout<CameraUniforms>.stride + 255) / 256) * 256
    var splatSettingsBuffer: MTLBuffer?
    var tileCountsBuffer: MTLBuffer?
    var tileListBuffer: MTLBuffer?

    // Scene & camera
    var scene: Scene?
    var camera: Camera
    var viewportSize: float2 = float2(800, 600)
    var frameCount: UInt64 = 0

    // Tile config
    let tileSize = 16
    let maxGaussiansPerTile = 1024

    // Scene transform
    var activeTransformMode: TransformMode = .none
    private var sceneRotation: float3    = .zero
    private var sceneScale: Float        = 1.0
    private var sceneTranslation: float3 = .zero
    private var lastTransformMousePos: float2 = .zero

    // User-facing splat settings (written to GPU every frame)
    var splatSettings = SplatSettings()

    // MARK: - Model Matrix

    private var modelMatrix: float4x4 {
        let T  = float4x4.translation(sceneTranslation)
        let Rx = float4x4.rotationX(sceneRotation.x)
        let Ry = float4x4.rotationY(sceneRotation.y)
        let Rz = float4x4.rotationZ(sceneRotation.z)
        let S  = float4x4.scale(float3(repeating: sceneScale))
        return T * Rz * Ry * Rx * S
    }

    // MARK: - Init

    init?(metalKitView: MTKView) {
        guard
            let device       = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else { return nil }

        self.device       = device
        self.commandQueue = commandQueue

        do {
            self.library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            print("Failed to load Metal library: \(error)")
            return nil
        }

        let aspect = Float(metalKitView.drawableSize.width) /
                     max(1, Float(metalKitView.drawableSize.height))
        self.camera = Camera(
            position: float3(0, 0, 5),
            target: .zero,
            aspectRatio: aspect
        )

        super.init()

        metalKitView.device       = device
        metalKitView.delegate     = self
        metalKitView.colorPixelFormat  = .bgra8Unorm_srgb
        metalKitView.framebufferOnly   = false   // required for compute write to drawable
        metalKitView.preferredFramesPerSecond = 60

        createPipelines()

        cameraUniformsBuffer = device.makeBuffer(
            length: cameraUniformStride * 3,
            options: .storageModeShared
        )
        splatSettingsBuffer = device.makeBuffer(
            length: MemoryLayout<SplatSettings>.stride,
            options: .storageModeShared
        )

        self.scene = Scene(device: device)

        viewportSize = float2(
            Float(metalKitView.drawableSize.width),
            Float(metalKitView.drawableSize.height)
        )
        if viewportSize.x > 0 && viewportSize.y > 0 {
            resizeTileBuffers()
        }
    }

    // MARK: - Pipeline Creation

    private func createPipelines() {
        do {
            guard
                let projectFn = library.makeFunction(name: "projectGaussians"),
                let binFn     = library.makeFunction(name: "binGaussians"),
                let sortFn    = library.makeFunction(name: "sortTiles"),
                let renderFn  = library.makeFunction(name: "renderTiles")
            else {
                print("Error: one or more Metal functions not found in library")
                return
            }
            projectPSO = try device.makeComputePipelineState(function: projectFn)
            binningPSO = try device.makeComputePipelineState(function: binFn)
            sortPSO    = try device.makeComputePipelineState(function: sortFn)
            renderPSO  = try device.makeComputePipelineState(function: renderFn)
            print("All compute pipelines created successfully")
        } catch {
            print("Pipeline creation error: \(error)")
        }
    }

    // MARK: - Scene Loading

    func loadScene(from url: URL) throws {
        guard let scene = scene else {
            throw RendererError.sceneNotInitialized
        }
        try scene.load(from: url)

        print("Scene loaded — center: \(scene.center), radius: \(scene.radius)")
        camera.focus(on: scene.center, radius: max(scene.radius, 0.1))
        print("Camera position: \(camera.position), distance: \(camera.distance)")

        resizeTileBuffers()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = float2(Float(size.width), Float(size.height))
        camera.aspectRatio = Float(size.width) / max(1, Float(size.height))
        camera.updateMatrices()
        resizeTileBuffers()
    }

    private func resizeTileBuffers() {
        guard viewportSize.x > 0 && viewportSize.y > 0 else { return }
        let tilesX     = (Int(viewportSize.x) + tileSize - 1) / tileSize
        let tilesY     = (Int(viewportSize.y) + tileSize - 1) / tileSize
        let tileCount  = tilesX * tilesY
        tileCountsBuffer = device.makeBuffer(
            length: tileCount * MemoryLayout<UInt32>.stride,
            options: .storageModePrivate
        )
        tileListBuffer = device.makeBuffer(
            length: tileCount * maxGaussiansPerTile * MemoryLayout<UInt32>.stride,
            options: .storageModePrivate
        )
        print("Tile buffers resized: \(Int(viewportSize.x))×\(Int(viewportSize.y)), tiles: \(tilesX)×\(tilesY)")
    }

    // MARK: - Draw

    func draw(in view: MTKView) {
        guard
            let scene           = scene,
            scene.isLoaded,
            let projectPSO      = projectPSO,
            let binningPSO      = binningPSO,
            let sortPSO         = sortPSO,
            let renderPSO       = renderPSO,
            let splatBuffer     = scene.splatBuffer,
            let projectedBuffer = scene.projectedBuffer,
            let tileCounts      = tileCountsBuffer,
            let tileList        = tileListBuffer,
            let camBuf          = cameraUniformsBuffer,
            let settingsBuf     = splatSettingsBuffer,
            let drawable        = view.currentDrawable,
            let commandBuffer   = commandQueue.makeCommandBuffer(),
            viewportSize.x > 0 && viewportSize.y > 0
        else { return }

        frameCount += 1
        updateCameraUniforms()

        var renderCount = UInt32(scene.splatCount)
        var config = RasterConfig(
            screenWidth:        UInt32(viewportSize.x),
            screenHeight:       UInt32(viewportSize.y),
            tilesX:             UInt32((Int(viewportSize.x) + tileSize - 1) / tileSize),
            tilesY:             UInt32((Int(viewportSize.y) + tileSize - 1) / tileSize),
            tileSize:           UInt32(tileSize),
            maxGaussiansPerTile: UInt32(maxGaussiansPerTile),
            renderCount:        renderCount,
            maxScreenRadius:    256
        )

        let camOffset = Int(frameCount % 3) * cameraUniformStride

        // Clear tile counts
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.fill(buffer: tileCounts, range: 0..<tileCounts.length, value: 0)
            blit.endEncoding()
        }

        // 1. Project Gaussians → screen space
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(projectPSO)
            enc.setBuffer(splatBuffer,     offset: 0,         index: 0)
            enc.setBuffer(projectedBuffer, offset: 0,         index: 1)
            enc.setBuffer(camBuf,          offset: camOffset, index: 2)
            enc.setBytes(&renderCount,     length: 4,         index: 3)
            var step = UInt32(1)
            enc.setBytes(&step,            length: 4,         index: 4)
            enc.setBytes(&config,          length: MemoryLayout<RasterConfig>.stride,  index: 5)
            enc.setBuffer(settingsBuf,     offset: 0,         index: 6)
            enc.dispatchThreadgroups(
                MTLSize(width: (Int(renderCount) + 255) / 256, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
            )
            enc.endEncoding()
        }

        // 2. Bin Gaussians into tiles
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(binningPSO)
            enc.setBuffer(projectedBuffer, offset: 0, index: 0)
            enc.setBuffer(tileCounts,      offset: 0, index: 1)
            enc.setBuffer(tileList,        offset: 0, index: 2)
            enc.setBytes(&config, length: MemoryLayout<RasterConfig>.stride, index: 3)
            enc.dispatchThreadgroups(
                MTLSize(width: (Int(renderCount) + 255) / 256, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
            )
            enc.endEncoding()
        }

        // 3. Sort each tile back-to-front
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(sortPSO)
            enc.setBuffer(projectedBuffer, offset: 0, index: 0)
            enc.setBuffer(tileCounts,      offset: 0, index: 1)
            enc.setBuffer(tileList,        offset: 0, index: 2)
            enc.setBytes(&config, length: MemoryLayout<RasterConfig>.stride, index: 3)
            let totalTiles = Int(config.tilesX * config.tilesY)
            enc.dispatchThreadgroups(
                MTLSize(width: (totalTiles + 31) / 32, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1)
            )
            enc.endEncoding()
        }

        // 4. Render tiles → drawable texture
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(renderPSO)
            enc.setBuffer(projectedBuffer, offset: 0, index: 0)
            enc.setBuffer(tileCounts,      offset: 0, index: 1)
            enc.setBuffer(tileList,        offset: 0, index: 2)
            enc.setBytes(&config,          length: MemoryLayout<RasterConfig>.stride, index: 3)
            enc.setBuffer(settingsBuf,     offset: 0, index: 4)
            enc.setTexture(drawable.texture, index: 0)
            enc.dispatchThreadgroups(
                MTLSize(width: Int(config.tilesX), height: Int(config.tilesY), depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            enc.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Camera Uniforms

    private func updateCameraUniforms() {
        guard let camBuf = cameraUniformsBuffer, let settingsBuf = splatSettingsBuffer else { return }

        // Build camera uniforms with current model matrix
        var uniforms = camera.getUniforms(screenSize: viewportSize)
        uniforms.modelMatrix = modelMatrix

        let offset = Int(frameCount % 3) * cameraUniformStride
        memcpy(camBuf.contents().advanced(by: offset),
               &uniforms,
               MemoryLayout<CameraUniforms>.stride)

        // Write the ACTUAL splatSettings (not hardcoded values)
        var settings = splatSettings
        memcpy(settingsBuf.contents(), &settings, MemoryLayout<SplatSettings>.stride)
    }

    // MARK: - Input Handling

    func handleMouseDown(at p: NSPoint, button: MouseButton) {
        let pos = float2(Float(p.x), Float(p.y))
        // Always record position for transform mode delta tracking
        lastTransformMousePos = pos
        camera.mouseDown(at: pos)
    }

    func handleMouseDrag(to p: NSPoint, button: MouseButton) {
        let pos   = float2(Float(p.x), Float(p.y))
        let delta = pos - lastTransformMousePos
        lastTransformMousePos = pos

        if activeTransformMode != .none {
            switch activeTransformMode {
            case .rotate:
                sceneRotation.y += delta.x * 0.005
                sceneRotation.x += delta.y * 0.005
            case .scale:
                sceneScale *= (1.0 + delta.y * 0.005)
                sceneScale = max(0.01, min(100.0, sceneScale))
            case .translate:
                sceneTranslation.x += delta.x * 0.01 * camera.distance
                sceneTranslation.y -= delta.y * 0.01 * camera.distance
            case .none:
                break
            }
            return
        }

        camera.mouseDrag(to: pos, button: button)
    }

    func handleMouseUp() {
        camera.mouseUp()
    }

    func handleScroll(deltaY: CGFloat) {
        camera.scroll(deltaY: Float(deltaY))
    }

    func resetSceneTransform() {
        sceneRotation    = .zero
        sceneScale       = 1.0
        sceneTranslation = .zero
    }
}
