import Foundation
import simd

struct CameraWaypoint {
    var position: float3
    var target: float3
    var up: float3
}

/// Orbit camera for navigating 3D scenes.
/// Coordinate convention: right-handed, camera looks down -Z in view space.
class Camera {
    // World-space state
    var position: float3
    var target: float3
    var up: float3

    // Spherical coordinates (orbit mode)
    var distance: Float  = 5.0
    var azimuth: Float   = 0.0   // horizontal angle (radians)
    var elevation: Float = 0.0   // vertical angle (radians)

    // Projection
    var fovDegrees: Float  = 60.0
    var aspectRatio: Float = 1.0
    var nearZ: Float       = 0.1
    var farZ: Float        = 1000.0

    // Cached matrices
    private(set) var viewMatrix: float4x4           = .identity
    private(set) var projectionMatrix: float4x4     = .identity
    private(set) var viewProjectionMatrix: float4x4 = .identity

    // Interaction
    var isDragging = false
    var lastMousePosition: float2 = .zero

    // Sensitivity
    var rotationSensitivity: Float = 0.005
    var zoomSensitivity: Float     = 0.1
    var panSensitivity: Float      = 0.005

    // Cinematic path
    private var waypoints: [CameraWaypoint] = []
    private var interpolationTime: Float = 0
    private var isInterpolating = false
    private var currentSegment: Int = 0

    // MARK: - Init

    init(
        position: float3    = float3(0, 0, 5),
        target: float3      = .zero,
        up: float3          = float3(0, 1, 0),
        fovDegrees: Float   = 60,
        aspectRatio: Float  = 1,
        nearZ: Float        = 0.1,
        farZ: Float         = 1000
    ) {
        self.position    = position
        self.target      = target
        self.up          = up
        self.fovDegrees  = fovDegrees
        self.aspectRatio = aspectRatio
        self.nearZ       = nearZ
        self.farZ        = farZ

        // Initialise spherical coords from position
        let offset = position - target
        let dist   = simd_length(offset)
        self.distance  = max(dist, 0.001)
        self.azimuth   = atan2(offset.x, offset.z)
        let ratio      = offset.y / max(0.0001, dist)
        self.elevation = asin(max(-1.0, min(1.0, ratio)))

        updateMatrices()
    }

    // MARK: - Cinematic Path

    func addWaypoint(position: float3, target: float3, up: float3 = float3(0, 1, 0)) {
        waypoints.append(CameraWaypoint(position: position, target: target, up: up))
    }

    func startCinematic(duration: Float) {
        guard waypoints.count >= 4 else { return }
        isInterpolating   = true
        interpolationTime = 0
        currentSegment    = 1
    }

    func update(deltaTime: Float) {
        guard isInterpolating, waypoints.count >= 4 else { return }

        interpolationTime += deltaTime
        if interpolationTime >= 1.0 {
            interpolationTime = 0
            currentSegment   += 1
            if currentSegment >= waypoints.count - 2 {
                isInterpolating = false
                return
            }
        }

        let t  = interpolationTime
        let p0 = waypoints[currentSegment - 1]
        let p1 = waypoints[currentSegment]
        let p2 = waypoints[currentSegment + 1]
        let p3 = waypoints[currentSegment + 2]

        position = catmullRom(p0.position, p1.position, p2.position, p3.position, t: t)
        target   = catmullRom(p0.target,   p1.target,   p2.target,   p3.target,   t: t)
        up       = simd_normalize(catmullRom(p0.up, p1.up, p2.up, p3.up, t: t))

        let offset = position - target
        let dist   = simd_length(offset)
        distance   = dist
        azimuth    = atan2(offset.x, offset.z)
        let ratio  = offset.y / max(0.0001, dist)
        elevation  = asin(max(-1.0, min(1.0, ratio)))

        updateMatrices()
    }

    private func catmullRom(_ p0: float3, _ p1: float3, _ p2: float3, _ p3: float3, t: Float) -> float3 {
        let t2 = t * t, t3 = t2 * t
        return 0.5 * (
            2.0 * p1 +
            (p2 - p0) * t +
            (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
            (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3
        )
    }

    // MARK: - Matrix Update

    func updateMatrices() {
        if !isInterpolating {
            // Recompute position from spherical coordinates
            let x = distance * cos(elevation) * sin(azimuth)
            let y = distance * sin(elevation)
            let z = distance * cos(elevation) * cos(azimuth)
            position = target + float3(x, y, z)
        }

        viewMatrix       = float4x4.lookAt(eye: position, center: target, up: up)
        let fovRad       = fovDegrees * .pi / 180.0
        projectionMatrix = float4x4.perspective(
            fovRadians: fovRad,
            aspect: aspectRatio,
            nearZ: nearZ,
            farZ: farZ
        )
        viewProjectionMatrix = projectionMatrix * viewMatrix
    }

    // MARK: - Orbit Controls

    func rotate(deltaX: Float, deltaY: Float) {
        azimuth   += deltaX * rotationSensitivity
        let limit  = Float.pi / 2.0 - 0.01
        elevation  = max(-limit, min(limit, elevation + deltaY * rotationSensitivity))
        updateMatrices()
    }

    func zoom(delta: Float) {
        distance *= 1.0 - delta * zoomSensitivity
        distance  = max(nearZ * 2.0, min(farZ / 2.0, distance))
        updateMatrices()
    }

    func pan(deltaX: Float, deltaY: Float) {
        let right    = viewMatrix.right
        let upVec    = viewMatrix.up
        let panDelta = -(right * deltaX * panSensitivity * distance +
                         upVec * deltaY * panSensitivity * distance)
        target += panDelta
        updateMatrices()
    }

    func focus(on point: float3, radius: Float) {
        target   = point
        distance = radius * 3.0
        updateMatrices()
    }

    func reset() {
        distance  = 5.0
        azimuth   = 0.0
        elevation = 0.0
        target    = .zero
        updateMatrices()
    }

    // MARK: - GPU Uniforms

    func getUniforms(screenSize: float2) -> CameraUniforms {
        let fovRad     = fovDegrees * .pi / 180.0
        let tanHalfFov = tan(fovRad * 0.5)
        return CameraUniforms(
            viewMatrix:           viewMatrix,
            projectionMatrix:     projectionMatrix,
            viewProjectionMatrix: viewProjectionMatrix,
            modelMatrix:          matrix_identity_float4x4,
            cameraPosition:       position,
            padding:              0,
            screenSize:           screenSize,
            tanHalfFov:           float2(tanHalfFov * aspectRatio, tanHalfFov)
        )
    }

    // MARK: - Mouse / Scroll

    func mouseDown(at position: float2) {
        isDragging        = true
        lastMousePosition = position
    }

    func mouseDrag(to position: float2, button: MouseButton) {
        let delta         = position - lastMousePosition
        lastMousePosition = position
        switch button {
        case .left:
            rotate(deltaX: delta.x, deltaY: delta.y)
        case .middle, .right:
            pan(deltaX: delta.x, deltaY: -delta.y)
        }
    }

    func mouseUp() {
        isDragging = false
    }

    func scroll(deltaY: Float) {
        zoom(delta: deltaY)
    }
}

enum MouseButton {
    case left, middle, right
}
