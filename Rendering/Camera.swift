import Foundation
import simd

class Camera {
    var position:    float3
    var target:      float3
    var up:          float3 = float3(0,1,0)

    var distance:    Float = 5
    var azimuth:     Float = 0
    var elevation:   Float = 0

    var fovDegrees:  Float = 60
    var aspectRatio: Float = 1
    var nearZ:       Float = 0.1
    var farZ:        Float = 2000

    private(set) var viewMatrix:     float4x4 = .identity
    private(set) var projMatrix:     float4x4 = .identity
    private(set) var viewProjMatrix: float4x4 = .identity

    var isDragging = false
    var lastMousePosition: float2 = .zero

    let rotSens:  Float = 0.005
    let zoomSens: Float = 0.1
    let panSens:  Float = 0.005

    init(position: float3 = float3(0,0,5),
         target: float3   = .zero,
         aspectRatio: Float = 1) {
        self.position    = position
        self.target      = target
        let off          = position - target
        let d            = simd_length(off)
        self.distance    = max(d, 0.001)
        self.azimuth     = atan2(off.x, off.z)
        self.elevation   = asin(max(-1, min(1, off.y / max(d, 0.0001))))
        self.aspectRatio = aspectRatio
        updateMatrices()
    }

    func updateMatrices() {
        // Recompute position from spherical coords
        let x = distance * cos(elevation) * sin(azimuth)
        let y = distance * sin(elevation)
        let z = distance * cos(elevation) * cos(azimuth)
        position = target + float3(x, y, z)

        viewMatrix     = float4x4.lookAt(eye: position, center: target, up: up)
        projMatrix     = float4x4.perspective(
            fovY:   fovDegrees * .pi / 180,
            aspect: aspectRatio,
            near:   nearZ,
            far:    farZ)
        viewProjMatrix = projMatrix * viewMatrix
    }

    func getUniforms(screenSize: float2) -> CameraUniforms {
        let fovRad = fovDegrees * .pi / 180
        let thf    = tan(fovRad * 0.5)
        return CameraUniforms(
            viewMatrix:     viewMatrix,
            projMatrix:     projMatrix,
            viewProjMatrix: viewProjMatrix,
            modelMatrix:    matrix_identity_float4x4,
            camPos:         position,
            _pad:           0,
            screenSize:     screenSize,
            tanHalfFov:     float2(thf * aspectRatio, thf)
        )
    }

    // MARK: - Controls
    func rotate(dx: Float, dy: Float) {
        azimuth   += dx * rotSens
        elevation  = max(-.pi/2+0.01, min(.pi/2-0.01, elevation + dy * rotSens))
        updateMatrices()
    }

    func zoom(delta: Float) {
        distance = max(nearZ*2, min(farZ/2, distance * (1 - delta * zoomSens)))
        updateMatrices()
    }

    func pan(dx: Float, dy: Float) {
        let r = viewMatrix.right
        let u = viewMatrix.up
        target += -(r * dx + u * dy) * panSens * distance
        updateMatrices()
    }

    func mouseDown(at p: float2) { isDragging = true; lastMousePosition = p }

    func mouseDrag(to p: float2, button: MouseButton) {
        let d = p - lastMousePosition
        lastMousePosition = p
        switch button {
        case .left:          rotate(dx: d.x, dy: d.y)
        case .right, .middle: pan(dx: d.x, dy: -d.y)
        }
    }

    func mouseUp()            { isDragging = false }
    func scroll(deltaY: Float){ zoom(delta: deltaY) }
}

enum MouseButton { case left, middle, right }
