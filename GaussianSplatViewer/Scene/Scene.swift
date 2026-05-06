import Foundation
import Metal
import simd

/// Manages a collection of Gaussian splats and their GPU resources
class Scene {
    let device: MTLDevice
    
    // CPU-side data
    private(set) var splats: [GaussianSplat] = []
    
    // GPU resources
    private(set) var splatBuffer: MTLBuffer?
    private(set) var projectedBuffer: MTLBuffer?
    private(set) var indexBuffer: MTLBuffer?
    
    // State
    var splatCount: Int { splats.count }
    var isLoaded: Bool {
        !splats.isEmpty &&
        splatBuffer != nil &&
        projectedBuffer != nil &&
        indexBuffer != nil
    }
    
    init(device: MTLDevice) {
        self.device = device
    }
    
    /// Load splats from a PLY file
    func load(from url: URL) throws {
        print("Loading PLY file: \(url.lastPathComponent)")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let loadedSplats = try PLYLoader.load(from: url)
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime
        
        print("Loaded \(loadedSplats.count) splats in \(String(format: "%.3f", loadTime))s")
        
        // Create GPU buffers
        try createGPUResources(for: loadedSplats)
    }
    
    /// Load splats from data
    func load(from data: Data) throws {
        print("Loading PLY data...")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let loadedSplats = try PLYLoader.load(from: data)
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime
        
        print("Loaded \(loadedSplats.count) splats in \(String(format: "%.3f", loadTime))s")
        
        try createGPUResources(for: loadedSplats)
    }
    
    /// Create GPU buffers for the loaded splats
    private func createGPUResources(for splats: [GaussianSplat]) throws {
        guard !splats.isEmpty else {
            print("Warning: No splats to load")
            clear()
            return
        }
        
        print("Creating GPU resources for \(splats.count) splats...")
        
        // Create splat data buffer
        var gpuData = splats.map { GaussianGPUData(from: $0) }
        let splatBufferSize = MemoryLayout<GaussianGPUData>.stride * gpuData.count
        
        print("  Splat buffer size: \(splatBufferSize / 1024 / 1024) MB")
        
        guard let buffer = device.makeBuffer(bytes: &gpuData, 
                                             length: splatBufferSize, 
                                             options: .storageModeShared) else {
            print("Error: Failed to create splat buffer")
            throw SceneError.failedToCreateBuffer
        }
        
        // Create projected data buffer (for compute shader output)
        let projectedBufferSize = MemoryLayout<ProjectedGaussian>.stride * splats.count
        guard let projBuffer = device.makeBuffer(length: projectedBufferSize, 
                                                  options: .storageModePrivate) else {
            print("Error: Failed to create projected buffer")
            throw SceneError.failedToCreateBuffer
        }

        // Create index buffer for sorted indices
        let indexBufferSize = MemoryLayout<UInt32>.stride * splats.count
        guard let idxBuffer = device.makeBuffer(length: indexBufferSize,
                                                 options: .storageModePrivate) else {
            print("Error: Failed to create index buffer")
            throw SceneError.failedToCreateBuffer
        }

        self.splats = splats
        self.splatBuffer = buffer
        self.projectedBuffer = projBuffer
        self.indexBuffer = idxBuffer
        
        print("Successfully created GPU buffers:")
        print("  - Splat buffer: \(splatBufferSize / 1024 / 1024) MB")
        print("  - Projected buffer: \(projectedBufferSize / 1024) KB")
        print("  - Index buffer: \(indexBufferSize / 1024) KB")
    }
    
    /// Clear all data
    func clear() {
        splats.removeAll()
        splatBuffer = nil
        projectedBuffer = nil
        indexBuffer = nil
    }

    /// Sort splats back-to-front for alpha blending and update the GPU buffer.
    func sortSplats(cameraPosition: float3, forward: float3) {
        guard !splats.isEmpty, let splatBuffer else { return }

        splats.sort {
            let depth0 = simd_dot($0.position - cameraPosition, forward)
            let depth1 = simd_dot($1.position - cameraPosition, forward)
            return depth0 > depth1
        }

        var gpuData = splats.map(GaussianGPUData.init)
        memcpy(
            splatBuffer.contents(),
            &gpuData,
            MemoryLayout<GaussianGPUData>.stride * gpuData.count
        )
    }
    
    /// Get bounding box of the scene
    func boundingBox() -> (min: float3, max: float3) {
        guard !splats.isEmpty else {
            return (float3(-1, -1, -1), float3(1, 1, 1))
        }
        
        var minBounds = splats[0].position
        var maxBounds = splats[0].position
        
        for splat in splats {
            minBounds = simd_min(minBounds, splat.position)
            maxBounds = simd_max(maxBounds, splat.position)
        }
        
        return (minBounds, maxBounds)
    }
    
    /// Get scene center
    var center: float3 {
        let bounds = boundingBox()
        return (bounds.min + bounds.max) * 0.5
    }
    
    /// Get scene radius (approximate)
    var radius: Float {
        let bounds = boundingBox()
        let size = bounds.max - bounds.min
        return simd_length(size) * 0.5
    }
}

enum SceneError: Error {
    case failedToCreateBuffer
    case noSplatsLoaded
}
