import Foundation

enum InterpolationEngine {

    static func linear(t: Float, v0: Float, v1: Float) -> Float {
        v0 + t * (v1 - v0)
    }

    static func constant(t: Float, v0: Float, v1: Float) -> Float {
        t < 1.0 ? v0 : v1
    }

    static func easeIn(t: Float, v0: Float, v1: Float) -> Float {
        let s = 3*t*t - 2*t*t*t
        return v0 + s * (v1 - v0)
    }

    static func easeOut(t: Float, v0: Float, v1: Float) -> Float {
        let tp = 1.0 - t
        let s  = 3*tp*tp - 2*tp*tp*tp
        return v0 + (1.0 - s) * (v1 - v0)
    }

    static func easeInOut(t: Float, v0: Float, v1: Float) -> Float {
        let s = 3*t*t - 2*t*t*t
        return v0 + s * (v1 - v0)
    }

    static func cubicHermite(t: Float, v0: Float, v1: Float, m0: Float, m1: Float) -> Float {
        let t2 = t*t, t3 = t2*t
        let h00 =  2*t3 - 3*t2 + 1
        let h10 =    t3 - 2*t2 + t
        let h01 = -2*t3 + 3*t2
        let h11 =    t3 -   t2
        return h00*v0 + h10*m0 + h01*v1 + h11*m1
    }

    static func normalizedTime(frame: Double, startFrame: Int, endFrame: Int) -> Float {
        let s = Double(startFrame), e = Double(endFrame)
        guard e > s else { return 0 }
        return Float(max(0, min(1, (frame - s) / (e - s))))
    }

    static func evaluate(at frame: Double, keyframes: [Keyframe]) -> Float {
        guard !keyframes.isEmpty else { return 0 }
        if keyframes.count == 1 { return keyframes[0].value }
        if frame <= Double(keyframes.first!.frame) { return keyframes.first!.value }
        if frame >= Double(keyframes.last!.frame)  { return keyframes.last!.value }

        var lo = 0, hi = keyframes.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if Double(keyframes[mid].frame) <= frame { lo = mid } else { hi = mid }
        }

        let kf0 = keyframes[lo], kf1 = keyframes[hi]
        let t  = normalizedTime(frame: frame, startFrame: kf0.frame, endFrame: kf1.frame)
        let v0 = kf0.value, v1 = kf1.value

        switch kf0.interpolationMode {
        case .linear:    return linear(t: t, v0: v0, v1: v1)
        case .constant:  return constant(t: t, v0: v0, v1: v1)
        case .easeIn:    return easeIn(t: t, v0: v0, v1: v1)
        case .easeOut:   return easeOut(t: t, v0: v0, v1: v1)
        case .easeInOut: return easeInOut(t: t, v0: v0, v1: v1)
        case .bezier:
            guard let h0 = kf0.bezierHandle else { return linear(t: t, v0: v0, v1: v1) }
            let len = Float(kf1.frame - kf0.frame)
            let m0 = h0.outTangent.x != 0 ? (h0.outTangent.y / h0.outTangent.x) * len : 0
            let m1: Float
            if let h1 = kf1.bezierHandle, h1.inTangent.x != 0 {
                m1 = (h1.inTangent.y / h1.inTangent.x) * len
            } else { m1 = 0 }
            return cubicHermite(t: t, v0: v0, v1: v1, m0: m0, m1: m1)
        }
    }

    static func evaluate(at frame: Double, store: KeyframeStore) -> CameraState {
        CameraState(
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
