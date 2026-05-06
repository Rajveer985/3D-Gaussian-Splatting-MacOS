import Foundation
import simd

/// Tangent handles for a cubic Hermite spline keyframe.
/// Coordinates are in (frame, value) space — i.e., time is measured in frames.
struct BezierHandle: Codable, Equatable {
    /// Tangent arriving at this keyframe (from the left).
    var inTangent: SIMD2<Float>   // (Δframe, Δvalue)
    /// Tangent leaving this keyframe (to the right).
    var outTangent: SIMD2<Float>  // (Δframe, Δvalue)

    /// Auto-tangent: smooth Catmull-Rom-style tangent computed from neighbors.
    /// When prev or next is nil (boundary keyframe), the tangent on that side is zeroed.
    static func autoTangent(prev: Keyframe?, current: Keyframe, next: Keyframe?) -> BezierHandle {
        // Catmull-Rom: tangent at current = 0.5 * (next.value - prev.value) / (next.frame - prev.frame)
        // expressed as a (Δframe, Δvalue) vector scaled to a reasonable handle length.

        let inTangent: SIMD2<Float>
        let outTangent: SIMD2<Float>

        if let prev = prev, let next = next {
            // Both neighbors exist — use full Catmull-Rom formula
            let frameDelta = Float(next.frame - prev.frame)
            let valueDelta = next.value - prev.value
            // Scale the handle to 1/3 of the distance to the respective neighbor
            let inFrameLen  = Float(current.frame - prev.frame) / 3.0
            let outFrameLen = Float(next.frame - current.frame) / 3.0
            let slope = frameDelta > 0 ? valueDelta / frameDelta : 0
            inTangent  = SIMD2<Float>(-inFrameLen,  -inFrameLen  * slope)
            outTangent = SIMD2<Float>( outFrameLen,  outFrameLen * slope)
        } else if let next = next {
            // No previous neighbor — flat tangent on the in side
            let outFrameLen = Float(next.frame - current.frame) / 3.0
            let slope = outFrameLen > 0 ? (next.value - current.value) / Float(next.frame - current.frame) : 0
            inTangent  = SIMD2<Float>(0, 0)
            outTangent = SIMD2<Float>(outFrameLen, outFrameLen * slope)
        } else if let prev = prev {
            // No next neighbor — flat tangent on the out side
            let inFrameLen = Float(current.frame - prev.frame) / 3.0
            let slope = inFrameLen > 0 ? (current.value - prev.value) / Float(current.frame - prev.frame) : 0
            inTangent  = SIMD2<Float>(-inFrameLen, -inFrameLen * slope)
            outTangent = SIMD2<Float>(0, 0)
        } else {
            // Isolated keyframe — zero tangents
            inTangent  = SIMD2<Float>(0, 0)
            outTangent = SIMD2<Float>(0, 0)
        }

        return BezierHandle(inTangent: inTangent, outTangent: outTangent)
    }
}
