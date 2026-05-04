import simd
import Metal

// MARK: - Type Aliases for Clarity
typealias float2 = SIMD2<Float>
typealias float3 = SIMD3<Float>
typealias float4 = SIMD4<Float>
typealias float4x4 = simd_float4x4

// MARK: - Gaussian Data Structure
/// Represents a single 3D Gaussian splat
struct GaussianSplat {
    var position: float3
    var scale: float3
    var rotation: float4  // Quaternion (x, y, z, w)
    var color: float3     // RGB (from SH coefficients, view-dependent in full impl)
    var opacity: Float
    
    init(position: float3 = .zero, 
         scale: float3 = float3(1, 1, 1),
         rotation: float4 = float4(0, 0, 0, 1),
         color: float3 = float3(1, 1, 1),
         opacity: Float = 1.0) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.color = color
        self.opacity = opacity
    }
}

// MARK: - GPU-Compatible Structures

/// Structure sent to GPU for each Gaussian
struct GaussianGPUData {
    var position: float3
    var padding1: Float = 0
    var scale: float3
    var padding2: Float = 0
    var rotation: float4
    var color: float3
    var opacity: Float
    
    init(from splat: GaussianSplat) {
        self.position = splat.position
        self.scale = splat.scale
        self.rotation = splat.rotation
        self.color = splat.color
        self.opacity = splat.opacity
    }
}

/// Camera uniform buffer structure
struct CameraUniforms {
    var viewMatrix: float4x4
    var projectionMatrix: float4x4
    var viewProjectionMatrix: float4x4
    var cameraPosition: float3
    var padding: Float = 0
    var screenSize: float2
    var tanHalfFov: float2
}

/// Per-Gaussian data after projection (for sorting)
struct ProjectedGaussian {
    var depth: Float
    var index: UInt32
    var uv: float2
    var conic: float3  // 2D covariance inverse (conic matrix: A, B, C)
    var color: float3
    var opacity: Float
    var radius: Float
}

// MARK: - Quaternion Math
extension float4 {
    /// Create quaternion from axis-angle
    static func fromAxisAngle(axis: float3, angle: Float) -> float4 {
        let halfAngle = angle * 0.5
        let s = sin(halfAngle)
        return float4(axis.x * s, axis.y * s, axis.z * s, cos(halfAngle))
    }
    
    /// Normalize quaternion
    var normalized: float4 {
        let len = length(self)
        return len > 0 ? self / len : float4(0, 0, 0, 1)
    }
    
    /// Convert quaternion to rotation matrix
    var toRotationMatrix: float3x3 {
        let q = self.normalized
        let x = q.x, y = q.y, z = q.z, w = q.w
        
        return float3x3(
            float3(1 - 2*(y*y + z*z), 2*(x*y - z*w), 2*(x*z + y*w)),
            float3(2*(x*y + z*w), 1 - 2*(x*x + z*z), 2*(y*z - x*w)),
            float3(2*(x*z - y*w), 2*(y*z + x*w), 1 - 2*(x*x + y*y))
        )
    }
}

// MARK: - Matrix Extensions
extension float4x4 {
    static let identity = float4x4(diagonal: float4(1, 1, 1, 1))
    
    /// Create perspective projection matrix
    static func perspective(fovRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> float4x4 {
        let tanHalfFov = tan(fovRadians * 0.5)
        
        return float4x4(
            float4(1 / (aspect * tanHalfFov), 0, 0, 0),
            float4(0, 1 / tanHalfFov, 0, 0),
            float4(0, 0, farZ / (farZ - nearZ), 1),
            float4(0, 0, -(farZ * nearZ) / (farZ - nearZ), 0)
        )
    }
    
    /// Create look-at view matrix
    static func lookAt(eye: float3, center: float3, up: float3) -> float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        
        return float4x4(
            float4(s.x, u.x, -f.x, 0),
            float4(s.y, u.y, -f.y, 0),
            float4(s.z, u.z, -f.z, 0),
            float4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        )
    }
    
    /// Create translation matrix
    static func translation(_ t: float3) -> float4x4 {
        float4x4(
            float4(1, 0, 0, 0),
            float4(0, 1, 0, 0),
            float4(0, 0, 1, 0),
            float4(t.x, t.y, t.z, 1)
        )
    }
    
    /// Create scale matrix
    static func scale(_ s: float3) -> float4x4 {
        float4x4(diagonal: float4(s.x, s.y, s.z, 1))
    }
    
    /// Extract position from matrix
    var position: float3 {
        float3(columns.3.x, columns.3.y, columns.3.z)
    }
    
    /// Extract forward direction from view matrix
    var forward: float3 {
        normalize(float3(-columns.2.x, -columns.2.y, -columns.2.z))
    }
    
    /// Extract right direction from view matrix
    var right: float3 {
        normalize(float3(columns.0.x, columns.0.y, columns.0.z))
    }
    
    /// Extract up direction from view matrix
    var up: float3 {
        normalize(float3(columns.1.x, columns.1.y, columns.1.z))
    }
}

// MARK: - Covariance Matrix Computation
extension GaussianSplat {
    /// Compute 3D covariance matrix from scale and rotation
    /// Returns upper triangular elements (Sigma): [xx, xy, xz, yy, yz, zz]
    func computeCovariance() -> (Float, Float, Float, Float, Float, Float) {
        // Build scale matrix
        let S = float3x3(diagonal: scale)
        
        // Build rotation matrix from quaternion
        let R = rotation.toRotationMatrix
        
        // Covariance Sigma = R * S * S^T * R^T = R * S^2 * R^T
        let RS = R * S
        let Sigma = RS * RS.transpose
        
        // Return upper triangular elements
        return (Sigma[0][0], Sigma[0][1], Sigma[0][2], 
                Sigma[1][1], Sigma[1][2], Sigma[2][2])
    }
}
