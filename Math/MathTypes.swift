import simd
import Metal

// MARK: - Type Aliases
typealias float2 = SIMD2<Float>
typealias float3 = SIMD3<Float>
typealias float4 = SIMD4<Float>
typealias float4x4 = simd_float4x4

// MARK: - Gaussian Splat (CPU-side)

struct GaussianSplat {
    var position: float3
    var scale: float3
    var rotation: float4   // Quaternion (x, y, z, w)
    var color: float3
    var opacity: Float
    var shCoefficients: [Float]

    init(
        position: float3 = .zero,
        scale: float3 = float3(1, 1, 1),
        rotation: float4 = float4(0, 0, 0, 1),
        color: float3 = float3(1, 1, 1),
        opacity: Float = 1.0,
        shCoefficients: [Float]? = nil
    ) {
        self.position = position
        self.scale    = scale
        self.rotation = rotation
        self.color    = color
        self.opacity  = opacity
        self.shCoefficients = shCoefficients ?? Self.degree0SH(from: color)
    }

    private static func degree0SH(from color: float3) -> [Float] {
        let c0: Float = 0.2820948
        let dc = (color - float3(repeating: 0.5)) / c0
        var c = Array(repeating: Float(0), count: 48)
        c[0] = dc.x; c[16] = dc.y; c[32] = dc.z
        return c
    }
}

// MARK: - GPU Data Structures

/// Sent to the GPU for each Gaussian.
/// Uses float4 for position and scale so the layout is unambiguous on both
/// Swift (SIMD4<Float> = 16 bytes) and Metal (float4 = 16 bytes).
/// This matches GaussianGPUDataGPU in GaussianSplat.metal exactly.
struct GaussianGPUData {
    var position: float4    // xyz = position, w = 0 (padding)
    var scale: float4       // xyz = scale,    w = 0 (padding)
    var rotation: float4    // quaternion (x, y, z, w)
    var opacity: Float
    var shDegree: UInt32
    var padding3: SIMD2<UInt32> = .zero
    var shR0: float4; var shR1: float4; var shR2: float4; var shR3: float4
    var shG0: float4; var shG1: float4; var shG2: float4; var shG3: float4
    var shB0: float4; var shB1: float4; var shB2: float4; var shB3: float4

    init(from splat: GaussianSplat) {
        self.position = float4(splat.position.x, splat.position.y, splat.position.z, 0)
        self.scale    = float4(splat.scale.x,    splat.scale.y,    splat.scale.z,    0)
        self.rotation = splat.rotation
        self.opacity  = splat.opacity

        let c = splat.shCoefficients + Array(
            repeating: Float(0),
            count: max(0, 48 - splat.shCoefficients.count)
        )

        // Determine highest SH degree with non-zero coefficients
        var maxDeg: UInt32 = 0
        if c.count >= 48 {
            outer: for ch in stride(from: 0, to: 48, by: 16) {
                for i in 9..<16 where abs(c[ch + i]) > 1e-6 { maxDeg = 3; break outer }
                for i in 4..<9  where abs(c[ch + i]) > 1e-6 { maxDeg = max(maxDeg, 2) }
                for i in 1..<4  where abs(c[ch + i]) > 1e-6 { maxDeg = max(maxDeg, 1) }
            }
        }
        self.shDegree = maxDeg

        shR0 = float4(c[0],  c[1],  c[2],  c[3])
        shR1 = float4(c[4],  c[5],  c[6],  c[7])
        shR2 = float4(c[8],  c[9],  c[10], c[11])
        shR3 = float4(c[12], c[13], c[14], c[15])
        shG0 = float4(c[16], c[17], c[18], c[19])
        shG1 = float4(c[20], c[21], c[22], c[23])
        shG2 = float4(c[24], c[25], c[26], c[27])
        shG3 = float4(c[28], c[29], c[30], c[31])
        shB0 = float4(c[32], c[33], c[34], c[35])
        shB1 = float4(c[36], c[37], c[38], c[39])
        shB2 = float4(c[40], c[41], c[42], c[43])
        shB3 = float4(c[44], c[45], c[46], c[47])
    }
}

/// Camera uniforms — matches CameraUniforms in GaussianSplat.metal exactly.
struct CameraUniforms {
    var viewMatrix: float4x4
    var projectionMatrix: float4x4
    var viewProjectionMatrix: float4x4
    var modelMatrix: float4x4 = matrix_identity_float4x4
    var cameraPosition: float3
    var padding: Float = 0
    var screenSize: float2
    var tanHalfFov: float2
}

/// Per-Gaussian projected data written by the compute shader.
/// Uses float4 for conic and color (w=0) to avoid float3 alignment ambiguity
/// between Swift SIMD3 and Metal float3 inside structs.
/// Must match ProjectedGaussian in GaussianSplat.metal exactly.
struct ProjectedGaussian {
    var depth: Float
    var index: UInt32
    var uv: float2
    var conic: float4   // xyz = conic (A, B, C), w = 0
    var color: float4   // xyz = color (R, G, B), w = 0
    var opacity: Float
    var radius: Float
    var pad: float2     // padding to 16-byte align struct size
}

struct RasterConfig {
    var screenWidth: UInt32
    var screenHeight: UInt32
    var tilesX: UInt32
    var tilesY: UInt32
    var tileSize: UInt32
    var maxGaussiansPerTile: UInt32
    var renderCount: UInt32
    var maxScreenRadius: Float
}

/// User-tunable splat rendering parameters — matches SplatSettings in GaussianSplat.metal.
struct SplatSettings {
    var scaleMultiplier: Float   = 1.0
    var opacityMultiplier: Float = 1.0
    var gaussianSharpness: Float = 1.0
    var saturation: Float        = 1.0
    var nearClip: Float          = 0.01
    var farClip: Float           = 1000.0
    var minOpacityCutoff: Float  = 1.0 / 255.0
    var shDegreeOverride: Int32  = -1
    var bgColorR: Float          = 0.1
    var bgColorG: Float          = 0.1
    var bgColorB: Float          = 0.1
    var covRegularization: Float = -1.0
    var maxScaleThreshold: Float = 10.0
}

// MARK: - Quaternion Extensions

extension float4 {
    static func fromAxisAngle(axis: float3, angle: Float) -> float4 {
        let h = angle * 0.5
        let s = sin(h)
        return float4(axis.x * s, axis.y * s, axis.z * s, cos(h))
    }

    var normalized: float4 {
        let l = simd_length(self)
        return l > 0 ? self / l : float4(0, 0, 0, 1)
    }

    var toRotationMatrix: float3x3 {
        let q = self.normalized
        let x = q.x, y = q.y, z = q.z, w = q.w
        return float3x3(
            float3(1 - 2*(y*y + z*z),  2*(x*y + z*w),        2*(x*z - y*w)),
            float3(2*(x*y - z*w),       1 - 2*(x*x + z*z),    2*(y*z + x*w)),
            float3(2*(x*z + y*w),       2*(y*z - x*w),         1 - 2*(x*x + y*y))
        )
    }
}

// MARK: - Matrix Extensions

extension float4x4 {
    static let identity = float4x4(diagonal: float4(1, 1, 1, 1))

    /// Perspective projection for Metal (depth range [0, 1], left-handed NDC).
    static func perspective(fovRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> float4x4 {
        let t = 1.0 / tan(fovRadians * 0.5)
        return float4x4(
            float4(t / aspect, 0,  0,                           0),
            float4(0,          t,  0,                           0),
            float4(0,          0,  farZ / (nearZ - farZ),      -1),
            float4(0,          0,  (nearZ * farZ) / (nearZ - farZ), 0)
        )
    }

    /// Look-at view matrix for Metal (camera looks down -Z, right-handed).
    static func lookAt(eye: float3, center: float3, up: float3) -> float4x4 {
        let f = normalize(eye - center)      // forward = eye - center (camera looks toward -Z)
        let r = normalize(cross(up, f))      // right
        let u = cross(f, r)                  // up (recomputed)

        return float4x4(
            float4(r.x,              u.x,              f.x,              0),
            float4(r.y,              u.y,              f.y,              0),
            float4(r.z,              u.z,              f.z,              0),
            float4(-dot(r, eye),    -dot(u, eye),     -dot(f, eye),      1)
        )
    }

    static func translation(_ t: float3) -> float4x4 {
        float4x4(
            float4(1, 0, 0, 0),
            float4(0, 1, 0, 0),
            float4(0, 0, 1, 0),
            float4(t.x, t.y, t.z, 1)
        )
    }

    static func scale(_ s: float3) -> float4x4 {
        float4x4(diagonal: float4(s.x, s.y, s.z, 1))
    }

    static func rotationX(_ a: Float) -> float4x4 {
        let c = cos(a), s = sin(a)
        return float4x4(
            float4(1,  0, 0, 0),
            float4(0,  c, s, 0),
            float4(0, -s, c, 0),
            float4(0,  0, 0, 1)
        )
    }

    static func rotationY(_ a: Float) -> float4x4 {
        let c = cos(a), s = sin(a)
        return float4x4(
            float4(c, 0, -s, 0),
            float4(0, 1,  0, 0),
            float4(s, 0,  c, 0),
            float4(0, 0,  0, 1)
        )
    }

    static func rotationZ(_ a: Float) -> float4x4 {
        let c = cos(a), s = sin(a)
        return float4x4(
            float4( c, s, 0, 0),
            float4(-s, c, 0, 0),
            float4( 0, 0, 1, 0),
            float4( 0, 0, 0, 1)
        )
    }

    var position: float3 { float3(columns.3.x, columns.3.y, columns.3.z) }
    var forward:  float3 { normalize(float3(columns.2.x, columns.2.y, columns.2.z)) }
    var right:    float3 { normalize(float3(columns.0.x, columns.0.y, columns.0.z)) }
    var up:       float3 { normalize(float3(columns.1.x, columns.1.y, columns.1.z)) }
}

// MARK: - Covariance

extension GaussianSplat {
    func computeCovariance() -> (Float, Float, Float, Float, Float, Float) {
        let S  = float3x3(diagonal: scale)
        let R  = rotation.toRotationMatrix
        let RS = R * S
        let Σ  = RS * RS.transpose
        return (Σ[0][0], Σ[0][1], Σ[0][2], Σ[1][1], Σ[1][2], Σ[2][2])
    }
}
