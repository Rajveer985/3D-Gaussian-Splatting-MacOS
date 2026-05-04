#include <metal_stdlib>
using namespace metal;

// MARK: - Structures

struct GaussianGPUData {
    float3 position;
    float padding1;
    float3 scale;
    float padding2;
    float4 rotation;  // quaternion (x, y, z, w)
    float3 color;
    float opacity;
};

struct CameraUniforms {
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4x4 viewProjectionMatrix;
    float3 cameraPosition;
    float padding;
    float2 screenSize;
    float2 tanHalfFov;
};

struct ProjectedGaussian {
    float depth;
    uint index;
    float2 uv;
    float3 conic;  // 2D covariance inverse (A, B, C)
    float3 color;
    float opacity;
    float radius;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float3 conic;
    float3 color;
    float opacity;
};

// MARK: - Quaternion Math

float4 quaternionNormalize(float4 q) {
    float len = length(q);
    return len > 0.0 ? q / len : float4(0, 0, 0, 1);
}

float3x3 quaternionToMatrix(float4 q) {
    q = quaternionNormalize(q);
    float x = q.x, y = q.y, z = q.z, w = q.w;
    
    return float3x3(
        float3(1.0 - 2.0*(y*y + z*z), 2.0*(x*y - z*w), 2.0*(x*z + y*w)),
        float3(2.0*(x*y + z*w), 1.0 - 2.0*(x*x + z*z), 2.0*(y*z - x*w)),
        float3(2.0*(x*z - y*w), 2.0*(y*z + x*w), 1.0 - 2.0*(x*x + y*y))
    );
}

// MARK: - Covariance Computation

// Compute 3D covariance from scale and rotation
void computeCovariance3D(float3 scale, float4 rotation, thread float3& cov3d0, thread float3& cov3d1) {
    float3x3 R = quaternionToMatrix(rotation);
    float3x3 S = float3x3(scale.x, 0, 0, 0, scale.y, 0, 0, 0, scale.z);
    float3x3 RS = R * S;
    float3x3 Sigma = RS * transpose(RS);
    
    // Return upper triangular (row-major): [xx, xy, xz], [yy, yz, zz]
    cov3d0 = float3(Sigma[0][0], Sigma[0][1], Sigma[0][2]);
    cov3d1 = float3(Sigma[1][1], Sigma[1][2], Sigma[2][2]);
}

// Project 3D covariance to 2D screen space
float3 projectCovariance2D(
    float3 mean3d,
    float3 cov3d0,
    float3 cov3d1,
    float focalX,
    float focalY,
    float tanFovX,
    float tanFovY,
    float4x4 viewMatrix,
    float4x4 viewProjectionMatrix
) {
    // Transform to view space
    float4 meanView = viewMatrix * float4(mean3d, 1.0);
    
    // Check if behind camera
    if (meanView.z <= 0.01) {
        return float3(0, 0, 0);
    }
    
    float3 t = meanView.xyz;
    
    // Jacobian of perspective projection
    float limX = 1.3 * tanFovX;
    float limY = 1.3 * tanFovY;
    float txtz = t.x / t.z;
    float tytz = t.y / t.z;
    t.x = min(limX, max(-limX, txtz)) * t.z;
    t.y = min(limY, max(-limY, tytz)) * t.z;
    
    float3x3 J = float3x3(
        focalX / t.z, 0, -(focalX * t.x) / (t.z * t.z),
        0, focalY / t.z, -(focalY * t.y) / (t.z * t.z),
        0, 0, 0
    );
    
    // Extract view rotation
    float3x3 W = float3x3(
        viewMatrix[0][0], viewMatrix[0][1], viewMatrix[0][2],
        viewMatrix[1][0], viewMatrix[1][1], viewMatrix[1][2],
        viewMatrix[2][0], viewMatrix[2][1], viewMatrix[2][2]
    );
    
    // Build 3D covariance matrix
    float3x3 T = W * J;
    float3x3 Vrk = float3x3(
        cov3d0.x, cov3d0.y, cov3d0.z,
        cov3d0.y, cov3d1.x, cov3d1.y,
        cov3d0.z, cov3d1.y, cov3d1.z
    );
    
    float3x3 cov = transpose(T) * Vrk * T;
    
    // Apply low-pass filter
    cov[0][0] += 0.3;
    cov[1][1] += 0.3;
    
    return float3(cov[0][0], cov[0][1], cov[1][1]);
}

// MARK: - Compute Shader: Projection

kernel void projectGaussians(
    device const GaussianGPUData* gaussians [[buffer(0)]],
    device ProjectedGaussian* projected [[buffer(1)]],
    constant CameraUniforms& camera [[buffer(2)]],
    constant uint& splatCount [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= splatCount) return;
    
    GaussianGPUData g = gaussians[gid];
    
    // Compute 3D covariance
    float3 cov3d0, cov3d1;
    computeCovariance3D(g.scale, g.rotation, cov3d0, cov3d1);
    
    // Compute focal lengths from projection matrix
    float focalX = camera.projectionMatrix[0][0] * camera.screenSize.x * 0.5;
    float focalY = camera.projectionMatrix[1][1] * camera.screenSize.y * 0.5;
    
    // Project to 2D
    float3 cov2d = projectCovariance2D(
        g.position, cov3d0, cov3d1,
        focalX, focalY,
        camera.tanHalfFov.x, camera.tanHalfFov.y,
        camera.viewMatrix, camera.viewProjectionMatrix
    );
    
    // Compute conic (inverse covariance)
    float det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
    if (det == 0.0) {
        projected[gid].opacity = 0.0;
        return;
    }
    
    float detInv = 1.0 / det;
    float3 conic = float3(cov2d.z * detInv, -cov2d.y * detInv, cov2d.x * detInv);
    
    // Compute view space position for depth
    float4 posView4 = camera.viewMatrix * float4(g.position, 1.0);
    float3 posView = posView4.xyz;
    
    // Compute projected position
    float4 posClip = camera.viewProjectionMatrix * float4(g.position, 1.0);
    float3 posNDC = posClip.xyz / posClip.w;
    float2 posScreen = (posNDC.xy * 0.5 + 0.5) * camera.screenSize;
    
    // Compute radius (3 sigma)
    float mid = 0.5 * (cov2d.x + cov2d.z);
    float lambda1 = mid + sqrt(max(0.1, mid * mid - det));
    float lambda2 = mid - sqrt(max(0.1, mid * mid - det));
    float radius = ceil(3.0 * sqrt(max(lambda1, lambda2)));
    
    // Store projected data
    ProjectedGaussian p;
    p.depth = posView.z;
    p.index = gid;
    p.uv = posScreen;
    p.conic = conic;
    p.color = g.color;
    p.opacity = g.opacity;
    p.radius = radius;
    
    projected[gid] = p;
}

// MARK: - Vertex Shader

vertex VertexOut gaussianVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    device const ProjectedGaussian* projected [[buffer(0)]],
    constant CameraUniforms& camera [[buffer(1)]]
) {
    VertexOut out;
    
    // Quad vertices: 0=(-1,-1), 1=(1,-1), 2=(-1,1), 3=(1,1)
    float2 quadPos = float2(
        vertexID % 2 == 0 ? -1.0 : 1.0,
        vertexID < 2 ? -1.0 : 1.0
    );
    
    ProjectedGaussian p = projected[instanceID];
    
    // Discard if not visible
    if (p.opacity <= 0.0 || p.radius <= 0.0) {
        out.position = float4(0, 0, 0, 0);
        out.opacity = 0.0;
        return out;
    }
    
    // Compute pixel position
    float2 pixelPos = p.uv + quadPos * p.radius;
    
    // Convert to NDC
    float2 ndc = (pixelPos / camera.screenSize) * 2.0 - 1.0;
    
    // Map depth to [0, 1] for depth buffer
    float depthNorm = p.depth / 100.0;  // Normalize based on far plane
    
    out.position = float4(ndc.x, ndc.y, depthNorm, 1.0);
    out.uv = quadPos * p.radius;
    out.conic = p.conic;
    out.color = p.color;
    out.opacity = p.opacity;
    
    return out;
}

// MARK: - Fragment Shader

fragment float4 gaussianFragment(
    VertexOut in [[stage_in]]
) {
    if (in.opacity <= 0.0) {
        discard_fragment();
    }
    
    // Evaluate 2D Gaussian
    float2 d = in.uv;
    float power = -0.5 * (in.conic.x * d.x * d.x + in.conic.z * d.y * d.y) 
                  - in.conic.y * d.x * d.y;
    
    if (power > 0.0) {
        discard_fragment();
    }
    
    // Compute alpha
    float alpha = min(0.99, in.opacity * exp(power));
    
    if (alpha < 1.0 / 255.0) {
        discard_fragment();
    }
    
    // Premultiplied alpha
    return float4(in.color * alpha, alpha);
}

// MARK: - Sorting (Simple Bitonic Sort Kernel)

kernel void bitonicSort(
    device ProjectedGaussian* data [[buffer(0)]],
    device uint* indices [[buffer(1)]],
    constant uint& stage [[buffer(2)]],
    constant uint& step [[buffer(3)]],
    constant uint& count [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    uint pairDistance = 1 << (stage - step);
    uint blockWidth = pairDistance * 2;
    
    uint leftId = (gid / pairDistance) * blockWidth + (gid % pairDistance);
    uint rightId = leftId + pairDistance;
    
    if (rightId >= count) return;
    
    bool ascending = ((leftId / (1 << stage)) % 2) == 0;
    
    float leftDepth = data[leftId].depth;
    float rightDepth = data[rightId].depth;
    
    bool shouldSwap = ascending ? (leftDepth < rightDepth) : (leftDepth > rightDepth);
    
    if (shouldSwap) {
        // Swap indices
        uint tempIdx = indices[leftId];
        indices[leftId] = indices[rightId];
        indices[rightId] = tempIdx;
        
        // Swap data
        ProjectedGaussian temp = data[leftId];
        data[leftId] = data[rightId];
        data[rightId] = temp;
    }
}
