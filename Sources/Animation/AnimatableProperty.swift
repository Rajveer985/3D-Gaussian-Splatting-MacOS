import Foundation
import simd

/// The eight scalar camera properties that can be keyframed.
enum AnimatableProperty: String, CaseIterable, Codable {
    case azimuth    = "azimuth"
    case elevation  = "elevation"
    case distance   = "distance"
    case targetX    = "targetX"
    case targetY    = "targetY"
    case targetZ    = "targetZ"
    case fovDegrees = "fovDegrees"
    case roll       = "roll"

    /// Human-readable display name for the timeline track label.
    var displayName: String {
        switch self {
        case .azimuth:    return "Azimuth"
        case .elevation:  return "Elevation"
        case .distance:   return "Distance"
        case .targetX:    return "Target X"
        case .targetY:    return "Target Y"
        case .targetZ:    return "Target Z"
        case .fovDegrees: return "FOV"
        case .roll:       return "Roll"
        }
    }

    /// Reads the current value of this property from a Camera instance.
    func currentValue(from camera: Camera) -> Float {
        switch self {
        case .azimuth:    return camera.azimuth
        case .elevation:  return camera.elevation
        case .distance:   return camera.distance
        case .targetX:    return camera.target.x
        case .targetY:    return camera.target.y
        case .targetZ:    return camera.target.z
        case .fovDegrees: return camera.fovDegrees
        case .roll:       return camera.roll
        }
    }

    /// Writes a value for this property to a Camera instance.
    /// Does NOT call updateMatrices — the caller is responsible for that.
    func apply(_ value: Float, to camera: Camera) {
        switch self {
        case .azimuth:    camera.azimuth    = value
        case .elevation:  camera.elevation  = value
        case .distance:   camera.distance   = value
        case .targetX:    camera.target.x   = value
        case .targetY:    camera.target.y   = value
        case .targetZ:    camera.target.z   = value
        case .fovDegrees: camera.fovDegrees = value
        case .roll:       camera.roll       = value
        }
    }
}
