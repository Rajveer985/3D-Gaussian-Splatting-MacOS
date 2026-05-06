import Foundation

/// Stateless engine that evaluates interpolated scalar values.
/// All methods are pure functions with no side effects.
enum InterpolationEngine {

    // MARK: - Primitive interpolators

    /// Linear interpolation between two values.
    /// Formula: v0 + t * (v1 - v0)
    static func linear(t: Float, v0: Float, v1: Float) -> Float {
        return v0 + t * (v1 - v0)
    }

    /// Constant/step: holds v0 until t reaches 1.0, then returns v1.
    static func constant(t: Float, v0: Float, v1: Float) -> Float {
        return t < 1.0 ? v0 : v1
    }

    /// Cubic ease-in: slow start, fast end.
    /// Uses smoothstep polynomial with t' = t (zero derivative at t=0).
    /// Formula: v0 + (3t² - 2t³) * (v1 - v0)
    static func easeIn(t: Float, v0: Float, v1: Float) -> Float {
        let tPrime = t
        let s = (3.0 * tPrime * tPrime) - (2.0 * tPrime * tPrime * tPrime)
        return v0 + s * (v1 - v0)
    }

    /// Cubic ease-out: fast start, slow end.
    /// Mirror of easeIn — zero derivative at t=1.
    /// Uses t' = 1 - t, applies smoothstep with t', then mirrors:
    /// result = v0 + (1 - smoothstep(t')) * (v1 - v0)
    static func easeOut(t: Float, v0: Float, v1: Float) -> Float {
        let tPrime = 1.0 - t
        let s = (3.0 * tPrime * tPrime) - (2.0 * tPrime * tPrime * tPrime)
        return v0 + (1.0 - s) * (v1 - v0)
    }

    /// Cubic ease-in-out: slow start, slow end.
    /// Smoothstep: zero derivatives at both t=0 and t=1.
    /// Formula: v0 + (3t² - 2t³) * (v1 - v0)
    static func easeInOut(t: Float, v0: Float, v1: Float) -> Float {
        let s = (3.0 * t * t) - (2.0 * t * t * t)
        return v0 + s * (v1 - v0)
    }

    /// Cubic Hermite spline using tangent slopes.
    /// Basis polynomials:
    ///   h00(t) = 2t³ - 3t² + 1
    ///   h10(t) = t³ - 2t² + t
    ///   h01(t) = -2t³ + 3t²
    ///   h11(t) = t³ - t²
    /// Result: h00*v0 + h10*m0 + h01*v1 + h11*m1
    static func cubicHermite(t: Float, v0: Float, v1: Float, m0: Float, m1: Float) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        let h00 =  2.0 * t3 - 3.0 * t2 + 1.0
        let h10 =        t3 - 2.0 * t2 + t
        let h01 = -2.0 * t3 + 3.0 * t2
        let h11 =        t3 -       t2
        return h00 * v0 + h10 * m0 + h01 * v1 + h11 * m1
    }

    // MARK: - Normalized time

    /// Computes the normalized t ∈ [0, 1] for a frame within a segment.
    /// Clamps to [0, 1] to handle out-of-range frames gracefully.
    static func normalizedTime(frame: Double, startFrame: Int, endFrame: Int) -> Float {
        let start = Double(startFrame)
        let end   = Double(endFrame)
        guard end > start else { return 0.0 }
        let t = (frame - start) / (end - start)
        return Float(max(0.0, min(1.0, t)))
    }

    // MARK: - Evaluate single property

    /// Evaluates the interpolated value for a property at the given frame.
    /// - Parameters:
    ///   - frame: The frame to evaluate (may be fractional for sub-frame precision).
    ///   - keyframes: Sorted ascending by frame.
    /// - Returns: The interpolated scalar value, or 0 if keyframes is empty.
    static func evaluate(at frame: Double, keyframes: [Keyframe]) -> Float {
        // Empty: return 0 (defensive)
        guard !keyframes.isEmpty else { return 0.0 }

        // Single keyframe: return its value for all frames
        if keyframes.count == 1 {
            return keyframes[0].value
        }

        // Before first keyframe: clamp to first value (no extrapolation)
        if frame <= Double(keyframes.first!.frame) {
            return keyframes.first!.value
        }

        // After last keyframe: clamp to last value (no extrapolation)
        if frame >= Double(keyframes.last!.frame) {
            return keyframes.last!.value
        }

        // Find the segment: find the last keyframe whose frame <= current frame
        // Binary search for the right keyframe index
        var lo = 0
        var hi = keyframes.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if Double(keyframes[mid].frame) <= frame {
                lo = mid
            } else {
                hi = mid
            }
        }

        let kf0 = keyframes[lo]
        let kf1 = keyframes[hi]

        let t = normalizedTime(frame: frame, startFrame: kf0.frame, endFrame: kf1.frame)
        let v0 = kf0.value
        let v1 = kf1.value

        // Dispatch by the interpolation mode of the outgoing keyframe (kf0)
        switch kf0.interpolationMode {
        case .linear:
            return linear(t: t, v0: v0, v1: v1)

        case .constant:
            return constant(t: t, v0: v0, v1: v1)

        case .easeIn:
            return easeIn(t: t, v0: v0, v1: v1)

        case .easeOut:
            return easeOut(t: t, v0: v0, v1: v1)

        case .easeInOut:
            return easeInOut(t: t, v0: v0, v1: v1)

        case .bezier:
            // Extract tangent slopes from BezierHandles; fall back to linear if nil
            guard let handle0 = kf0.bezierHandle else {
                return linear(t: t, v0: v0, v1: v1)
            }

            let segmentFrameLength = Float(kf1.frame - kf0.frame)

            // m0: slope of outTangent of kf0, scaled by segment frame length
            // outTangent is (Δframe, Δvalue); slope = Δvalue / Δframe
            // Then scale by segmentFrameLength to get the tangent in normalized-t space
            let m0: Float
            if handle0.outTangent.x != 0 {
                let slope = handle0.outTangent.y / handle0.outTangent.x
                m0 = slope * segmentFrameLength
            } else {
                m0 = 0.0
            }

            // m1: slope of inTangent of kf1, scaled by segment frame length
            let m1: Float
            if let handle1 = kf1.bezierHandle, handle1.inTangent.x != 0 {
                let slope = handle1.inTangent.y / handle1.inTangent.x
                m1 = slope * segmentFrameLength
            } else {
                // Fall back to 0 tangent if kf1 has no bezier handle
                m1 = 0.0
            }

            return cubicHermite(t: t, v0: v0, v1: v1, m0: m0, m1: m1)
        }
    }

    // MARK: - Evaluate full CameraState

    /// Evaluates a full CameraState at the given frame across all properties.
    static func evaluate(at frame: Double, store: KeyframeStore) -> CameraState {
        return CameraState(
            azimuth:    evaluate(at: frame, keyframes: store.keyframes(for: .azimuth)),
            elevation:  evaluate(at: frame, keyframes: store.keyframes(for: .elevation)),
            distance:   evaluate(at: frame, keyframes: store.keyframes(for: .distance)),
            targetX:    evaluate(at: frame, keyframes: store.keyframes(for: .targetX)),
            targetY:    evaluate(at: frame, keyframes: store.keyframes(for: .targetY)),
            targetZ:    evaluate(at: frame, keyframes: store.keyframes(for: .targetZ)),
            fovDegrees: evaluate(at: frame, keyframes: store.keyframes(for: .fovDegrees)),
            roll:       evaluate(at: frame, keyframes: store.keyframes(for: .roll))
        )
    }
}
