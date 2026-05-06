import Foundation
import simd

/// Tangent handles for a cubic Hermite spline keyframe.
/// Coordinates are in (frame, value) space.
struct BezierHandle: Codable, Equatable {
    var inTangent:  SIMD2<Float>
    var outTangent: SIMD2<Float>

    static func autoTangent(prev: Keyframe?, current: Keyframe, next: Keyframe?) -> BezierHandle {
        let inTangent: SIMD2<Float>
        let outTangent: SIMD2<Float>

        if let prev = prev, let next = next {
            let frameDelta = Float(next.frame - prev.frame)
            let valueDelta = next.value - prev.value
            let inFrameLen  = Float(current.frame - prev.frame) / 3.0
            let outFrameLen = Float(next.frame - current.frame) / 3.0
            let slope = frameDelta > 0 ? valueDelta / frameDelta : 0
            inTangent  = SIMD2<Float>(-inFrameLen,  -inFrameLen  * slope)
            outTangent = SIMD2<Float>( outFrameLen,  outFrameLen * slope)
        } else if let next = next {
            let outFrameLen = Float(next.frame - current.frame) / 3.0
            let slope = outFrameLen > 0 ? (next.value - current.value) / Float(next.frame - current.frame) : 0
            inTangent  = SIMD2<Float>(0, 0)
            outTangent = SIMD2<Float>(outFrameLen, outFrameLen * slope)
        } else if let prev = prev {
            let inFrameLen = Float(current.frame - prev.frame) / 3.0
            let slope = inFrameLen > 0 ? (current.value - prev.value) / Float(current.frame - prev.frame) : 0
            inTangent  = SIMD2<Float>(-inFrameLen, -inFrameLen * slope)
            outTangent = SIMD2<Float>(0, 0)
        } else {
            inTangent  = SIMD2<Float>(0, 0)
            outTangent = SIMD2<Float>(0, 0)
        }

        return BezierHandle(inTangent: inTangent, outTangent: outTangent)
    }
}
