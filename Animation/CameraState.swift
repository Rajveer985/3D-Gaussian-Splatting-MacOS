import Foundation
import simd

/// A snapshot of all eight AnimatableProperties at a given frame.
struct CameraState: Equatable {
    var azimuth:    Float
    var elevation:  Float
    var distance:   Float
    var targetX:    Float
    var targetY:    Float
    var targetZ:    Float
    var fovDegrees: Float
    var roll:       Float

    func apply(to camera: Camera) {
        camera.azimuth    = azimuth
        camera.elevation  = elevation
        camera.distance   = distance
        camera.target     = float3(targetX, targetY, targetZ)
        camera.fovDegrees = fovDegrees
        camera.roll       = roll
        camera.updateMatrices()
    }

    static func capture(from camera: Camera) -> CameraState {
        CameraState(
            azimuth:    camera.azimuth,
            elevation:  camera.elevation,
            distance:   camera.distance,
            targetX:    camera.target.x,
            targetY:    camera.target.y,
            targetZ:    camera.target.z,
            fovDegrees: camera.fovDegrees,
            roll:       camera.roll
        )
    }

    func value(for property: AnimatableProperty) -> Float {
        switch property {
        case .azimuth:    return azimuth
        case .elevation:  return elevation
        case .distance:   return distance
        case .targetX:    return targetX
        case .targetY:    return targetY
        case .targetZ:    return targetZ
        case .fovDegrees: return fovDegrees
        case .roll:       return roll
        }
    }

    func with(_ property: AnimatableProperty, value: Float) -> CameraState {
        var copy = self
        switch property {
        case .azimuth:    copy.azimuth    = value
        case .elevation:  copy.elevation  = value
        case .distance:   copy.distance   = value
        case .targetX:    copy.targetX    = value
        case .targetY:    copy.targetY    = value
        case .targetZ:    copy.targetZ    = value
        case .fovDegrees: copy.fovDegrees = value
        case .roll:       copy.roll       = value
        }
        return copy
    }
}
