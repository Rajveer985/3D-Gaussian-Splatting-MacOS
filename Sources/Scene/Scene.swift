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
    var isLoaded: Bool { !splats.isEmpty }
    
    init(device: MTLDevice) {
        self.device = device
    }
    
    /// Load splats from a PLY file
    func load(from url: URL) throws {
        print("Loading PLY file: \(url.lastPathComponent)")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        splats = try PLYLoader.load(from: url)
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime
        
        print("Loaded \(splats.count) splats in \(String(format: "%.3f", loadTime))s")
        
        // Create GPU buffers
        try createGPUResources()
    }
    
    /// Load splats from data
    func load(from data: Data) throws {
        print("Loading PLY data...")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        splats = try PLYLoader.load(from: data)
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime
        
        print("Loaded \(splats.count) splats in \(String(format: "%.3f", loadTime))s")
        
        try createGPUResources()
    }
    
    /// Create GPU buffers for the loaded splats
    private func createGPUResources() throws {
        guard !splats.isEmpty else { return }
        
        // Create splat data buffer
        var gpuData = splats.map { GaussianGPUData(from: $0) }
        let splatBufferSize = MemoryLayout<GaussianGPUData>.stride * gpuData.count
        
        guard let buffer = device.makeBuffer(bytes: &gpuData, 
                                             length: splatBufferSize, 
                                             options: .storageModeShared) else {
            throw SceneError.failedToCreateBuffer
        }
        self.splatBuffer = buffer
        
        // Create projected data buffer (for compute shader output)
        let projectedBufferSize = MemoryLayout<ProjectedGaussian>.stride * splats.count
        guard let projBuffer = device.makeBuffer(length: projectedBufferSize, 
                                                  options: .storageModePrivate) else {
            throw SceneError.failedToCreateBuffer
        }
        self.projectedBuffer = projBuffer
        
        // Create index buffer for sorted indices
        let indexBufferSize = MemoryLayout<UInt32>.stride * splats.count
        guard let idxBuffer = device.makeBuffer(length: indexBufferSize,
                                                 options: .storageModePrivate) else {
            throw SceneError.failedToCreateBuffer
        }
        self.indexBuffer = idxBuffer
        
        print("Created GPU buffers:")
        print("  - Splat buffer: \(splatBufferSize / 1024 / 1024) MB")
        print("  - Projected buffer: \(projectedBufferSize / 1024) KB")
    }
    
    /// Clear all data
    func clear() {
        splats.removeAll()
        splatBuffer = nil
        projectedBuffer = nil
        indexBuffer = nil
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
