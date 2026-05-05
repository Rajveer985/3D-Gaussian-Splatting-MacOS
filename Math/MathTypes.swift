import simd
import Metal

typealias float2 = SIMD2<Float>
typealias float3 = SIMD3<Float>
typealias float4 = SIMD4<Float>
typealias float4x4 = simd_float4x4

// MARK: - CPU splat
struct GaussianSplat {
    var position: float3
    var scale: float3
    var rotation: float4
    var color: float3
    var opacity: Float
    var shCoefficients: [Float]

    init(position: float3 = .zero, scale: float3 = float3(1,1,1),
         rotation: float4 = float4(0,0,0,1), color: float3 = float3(1,1,1),
         opacity: Float = 1, shCoefficients: [Float]? = nil) {
        self.position = position; self.scale = scale; self.rotation = rotation
        self.color = color; self.opacity = opacity
        self.shCoefficients = shCoefficients ?? Self.dc(color)
    }
    private static func dc(_ c: float3) -> [Float] {
        let k: Float = 0.2820948
        let d = (c - 0.5) / k
        var a = [Float](repeating: 0, count: 48)
        a[0]=d.x; a[16]=d.y; a[32]=d.z; return a
    }
}

// MARK: - GPU splat buffer  (matches GaussianGPUData in Metal exactly)
struct GaussianGPUData {
    var position: float4        // xyz pos,   w=0
    var scale:    float4        // xyz scale, w=0
    var rotation: float4
    var opacity:  Float
    var shDegree: UInt32
    var _pad0:    SIMD2<UInt32> = .zero
    var shR0, shR1, shR2, shR3: float4
    var shG0, shG1, shG2, shG3: float4
    var shB0, shB1, shB2, shB3: float4

    init(from s: GaussianSplat) {
        position = float4(s.position.x, s.position.y, s.position.z, 0)
        scale    = float4(s.scale.x,    s.scale.y,    s.scale.z,    0)
        rotation = s.rotation; opacity = s.opacity
        var c = s.shCoefficients; while c.count < 48 { c.append(0) }
        var deg: UInt32 = 0
        for ch in stride(from: 0, to: 48, by: 16) {
            if (9..<16).contains(where:{abs(c[ch+$0])>1e-6}){deg=3;break}
            if (4..<9 ).contains(where:{abs(c[ch+$0])>1e-6}){deg=max(deg,2)}
            if (1..<4 ).contains(where:{abs(c[ch+$0])>1e-6}){deg=max(deg,1)}
        }
        shDegree=deg
        shR0=float4(c[0],c[1],c[2],c[3]);   shR1=float4(c[4],c[5],c[6],c[7])
        shR2=float4(c[8],c[9],c[10],c[11]); shR3=float4(c[12],c[13],c[14],c[15])
        shG0=float4(c[16],c[17],c[18],c[19]);shG1=float4(c[20],c[21],c[22],c[23])
        shG2=float4(c[24],c[25],c[26],c[27]);shG3=float4(c[28],c[29],c[30],c[31])
        shB0=float4(c[32],c[33],c[34],c[35]);shB1=float4(c[36],c[37],c[38],c[39])
        shB2=float4(c[40],c[41],c[42],c[43]);shB3=float4(c[44],c[45],c[46],c[47])
    }
}

// MARK: - Camera uniforms  (matches CameraUniforms in Metal exactly)
struct CameraUniforms {
    var viewMatrix:     float4x4
    var projMatrix:     float4x4
    var viewProjMatrix: float4x4
    var modelMatrix:    float4x4 = matrix_identity_float4x4
    var camPos:         float3
    var _pad:           Float = 0
    var screenSize:     float2
    var tanHalfFov:     float2
}

// MARK: - Per-splat vertex  (matches SplatVertex in Metal exactly)
struct SplatVertex {
    var screenPos: float2
    var conic_xy:  float2
    var conic_z:   Float
    var opacity:   Float
    var radius:    Float
    var _pad:      Float = 0
    var color:     float4
}

// MARK: - Settings (CPU-side only)
struct SplatSettings {
    var scaleMultiplier:   Float = 1.0
    var opacityMultiplier: Float = 1.0
    var gaussianSharpness: Float = 1.0
    var saturation:        Float = 1.0
    var nearClip:          Float = 0.01
    var farClip:           Float = 1000.0
    var minOpacityCutoff:  Float = 1.0/255.0
    var shDegreeOverride:  Int32 = -1
    var bgColorR:          Float = 0.1
    var bgColorG:          Float = 0.1
    var bgColorB:          Float = 0.1
    var covRegularization: Float = -1.0
    var maxScaleThreshold: Float = 10.0
}

// MARK: - Quaternion
extension float4 {
    var normalized: float4 { let l=simd_length(self); return l>0 ? self/l : float4(0,0,0,1) }
}

// MARK: - Matrices
extension float4x4 {
    static let identity = float4x4(diagonal: float4(1,1,1,1))

    /// Metal perspective: depth [0,1], right-handed, -Z forward
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let t = 1 / tan(fovY * 0.5)
        return float4x4(
            float4(t/aspect, 0,  0,                    0),
            float4(0,        t,  0,                    0),
            float4(0,        0,  far/(near-far),       -1),
            float4(0,        0,  (near*far)/(near-far), 0)
        )
    }

    /// Right-handed look-at (-Z forward)
    static func lookAt(eye: float3, center: float3, up: float3) -> float4x4 {
        let f = normalize(eye - center)
        let r = normalize(cross(up, f))
        let u = cross(f, r)
        return float4x4(
            float4(r.x, u.x, f.x, 0),
            float4(r.y, u.y, f.y, 0),
            float4(r.z, u.z, f.z, 0),
            float4(-dot(r,eye), -dot(u,eye), -dot(f,eye), 1)
        )
    }

    static func translation(_ t: float3) -> float4x4 {
        var m = float4x4.identity; m.columns.3 = float4(t.x,t.y,t.z,1); return m
    }
    static func scale(_ s: float3) -> float4x4 { float4x4(diagonal: float4(s.x,s.y,s.z,1)) }
    static func rotationX(_ a: Float) -> float4x4 {
        let c=cos(a),s=sin(a)
        return float4x4(float4(1,0,0,0),float4(0,c,s,0),float4(0,-s,c,0),float4(0,0,0,1))
    }
    static func rotationY(_ a: Float) -> float4x4 {
        let c=cos(a),s=sin(a)
        return float4x4(float4(c,0,-s,0),float4(0,1,0,0),float4(s,0,c,0),float4(0,0,0,1))
    }
    static func rotationZ(_ a: Float) -> float4x4 {
        let c=cos(a),s=sin(a)
        return float4x4(float4(c,s,0,0),float4(-s,c,0,0),float4(0,0,1,0),float4(0,0,0,1))
    }
    var right:   float3 { normalize(float3(columns.0.x,columns.0.y,columns.0.z)) }
    var up:      float3 { normalize(float3(columns.1.x,columns.1.y,columns.1.z)) }
    var forward: float3 { normalize(float3(columns.2.x,columns.2.y,columns.2.z)) }
}

// Stubs so Scene.swift compiles without changes
struct ProjectedGaussian {
    var depth:Float=0; var index:UInt32=0; var uv:float2 = .zero
    var conic:float4 = .zero; var color:float4 = .zero
    var opacity:Float=0; var radius:Float=0; var pad:float2 = .zero
}
struct RasterConfig {
    var screenWidth:UInt32=0; var screenHeight:UInt32=0
    var tilesX:UInt32=0; var tilesY:UInt32=0; var tileSize:UInt32=16
    var maxGaussiansPerTile:UInt32=0; var renderCount:UInt32=0; var maxScreenRadius:Float=256
}
