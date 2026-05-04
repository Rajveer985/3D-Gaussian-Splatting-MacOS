import Foundation
import simd

/// Orbit camera controller for navigating 3D scenes
class Camera {
    // Camera parameters
    var position: float3
    var target: float3
    var up: float3
    
    // Spherical coordinates (for orbit mode)
    var distance: Float
    var azimuth: Float    // Horizontal angle (radians)
    var elevation: Float  // Vertical angle (radians)
    
    // Projection parameters
    var fovDegrees: Float
    var aspectRatio: Float
    var nearZ: Float
    var farZ: Float
    
    // Cached matrices
    private(set) var viewMatrix: float4x4 = .identity
    private(set) var projectionMatrix: float4x4 = .identity
    private(set) var viewProjectionMatrix: float4x4 = .identity
    
    // Interaction state
    var isDragging = false
    var lastMousePosition: float2 = .zero
    
    // Sensitivity
    var rotationSensitivity: Float = 0.005
    var zoomSensitivity: Float = 0.1
    var panSensitivity: Float = 0.01
    
    init(
        position: float3 = float3(0, 0, 5),
        target: float3 = .zero,
        up: float3 = float3(0, 1, 0),
        fovDegrees: Float = 60,
        aspectRatio: Float = 1,
        nearZ: Float = 0.1,
        farZ: Float = 1000
    ) {
        self.position = position
        self.target = target
        self.up = up
        self.fovDegrees = fovDegrees
        self.aspectRatio = aspectRatio
        self.nearZ = nearZ
        self.farZ = farZ
        
        // Initialize spherical coordinates from position
        let offset = position - target
        self.distance = length(offset)
        self.azimuth = atan2(offset.x, offset.z)
        self.elevation = asin(offset.y / distance)
        
        updateMatrices()
    }
    
    /// Update view and projection matrices
    func updateMatrices() {
        // Update position from spherical coordinates
        let x = distance * cos(elevation) * sin(azimuth)
        let y = distance * sin(elevation)
        let z = distance * cos(elevation) * cos(azimuth)
        position = target + float3(x, y, z)
        
        // Build view matrix
        viewMatrix = float4x4.lookAt(eye: position, center: target, up: up)
        
        // Build projection matrix
        let fovRadians = fovDegrees * .pi / 180
        projectionMatrix = float4x4.perspective(
            fovRadians: fovRadians,
            aspect: aspectRatio,
            nearZ: nearZ,
            farZ: farZ
        )
        
        // Combined matrix
        viewProjectionMatrix = projectionMatrix * viewMatrix
    }
    
    /// Handle mouse drag for rotation
    func rotate(deltaX: Float, deltaY: Float) {
        azimuth -= deltaX * rotationSensitivity
        elevation -= deltaY * rotationSensitivity
        
        // Clamp elevation to avoid gimbal lock
        let limit = Float.pi / 2 - 0.01
        elevation = max(-limit, min(limit, elevation))
        
        updateMatrices()
    }
    
    /// Handle zoom (scroll)
    func zoom(delta: Float) {
        distance *= 1.0 - delta * zoomSensitivity
        distance = max(nearZ * 2, min(farZ / 2, distance))
        updateMatrices()
    }
    
    /// Handle pan (middle mouse drag)
    func pan(deltaX: Float, deltaY: Float) {
        let right = viewMatrix.right
        let up = viewMatrix.up
        
        let panDelta = right * deltaX * panSensitivity * distance +
                      up * deltaY * panSensitivity * distance
        
        target += panDelta
        updateMatrices()
    }
    
    /// Focus camera on a specific point with given radius
    func focus(on point: float3, radius: Float) {
        target = point
        distance = radius * 3  // Start at 3x the object radius
        updateMatrices()
    }
    
    /// Reset to default position
    func reset() {
        distance = 5
        azimuth = 0
        elevation = 0
        target = .zero
        updateMatrices()
    }
    
    /// Get camera uniforms for GPU
    func getUniforms(screenSize: float2) -> CameraUniforms {
        let fovRadians = fovDegrees * .pi / 180
        let tanHalfFov = tan(fovRadians * 0.5)
        
        return CameraUniforms(
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            viewProjectionMatrix: viewProjectionMatrix,
            cameraPosition: position,
            padding: 0,
            screenSize: screenSize,
            tanHalfFov: float2(tanHalfFov * aspectRatio, tanHalfFov)
        )
    }
    
    /// Handle mouse down
    func mouseDown(at position: float2) {
        isDragging = true
        lastMousePosition = position
    }
    
    /// Handle mouse drag
    func mouseDrag(to position: float2, button: MouseButton) {
        let delta = position - lastMousePosition
        lastMousePosition = position
        
        switch button {
        case .left:
            rotate(deltaX: delta.x, deltaY: delta.y)
        case .middle, .right:
            pan(deltaX: delta.x, deltaY: -delta.y)
        }
    }
    
    /// Handle mouse up
    func mouseUp() {
        isDragging = false
    }
    
    /// Handle scroll
    func scroll(deltaY: Float) {
        zoom(delta: deltaY)
    }
}

enum MouseButton {
    case left
    case middle
    case right
}
