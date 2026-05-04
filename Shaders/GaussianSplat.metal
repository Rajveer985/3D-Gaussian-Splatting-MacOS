#include <metal_stdlib>
using namespace metal;

// MARK: - Structures
// All layouts must match their Swift counterparts in MathTypes.swift byte-for-byte.

struct GaussianGPUData {
    float4 position;    // xyz = position, w = 0
    float4 scale;       // xyz = scale,    w = 0
    float4 rotation;    // quaternion (x, y, z, w)
    float  opacity;
    uint   shDegree;
    uint2  padding3;
    float4 shR0, shR1, shR2, shR3;
    float4 shG0, shG1, shG2, shG3;
    float4 shB0, shB1, shB2, shB3;
};

struct CameraUniforms {
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4x4 viewProjectionMatrix;
    float4x4 modelMatrix;
    float3   cameraPosition;
    float    padding;
    float2   screenSize;
    float2   tanHalfFov;
};

// ProjectedGaussian: avoid float3 to prevent Metal alignment surprises.
// Use float4 for conic and color (w = 0) so layout is unambiguous.
struct ProjectedGaussian {
    float  depth;
    uint   index;
    float2 uv;
    float4 conic;   // xyz = conic (A, B, C), w = 0
    float4 color;   // xyz = color (R, G, B), w = 0
    float  opacity;
    float  radius;
    float2 pad;
};

struct RasterConfig {
    uint  screenWidth;
    uint  screenHeight;
    uint  tilesX;
    uint  tilesY;
    uint  tileSize;
    uint  maxGaussiansPerTile;
    uint  renderCount;
    float maxScreenRadius;
};

struct SplatSettings {
    float scaleMultiplier;
    float opacityMultiplier;
    float gaussianSharpness;
    float saturation;
    float nearClip;
    float farClip;
    float minOpacityCutoff;
    int   shDegreeOverride;
    float bgColorR;
    float bgColorG;
    float bgColorB;
    float covRegularization;
    float maxScaleThreshold;
};

// MARK: - Math Helpers

float3x3 quaternionToMatrix(float4 q) {
    float len = length(q);
    if (len > 0.0) q /= len; else q = float4(0, 0, 0, 1);
    float x = q.x, y = q.y, z = q.z, w = q.w;
    // Metal float3x3 constructor takes COLUMNS
    return float3x3(
        float3(1.0 - 2.0*(y*y + z*z),  2.0*(x*y + z*w),        2.0*(x*z - y*w)),   // col 0
        float3(2.0*(x*y - z*w),         1.0 - 2.0*(x*x + z*z),  2.0*(y*z + x*w)),   // col 1
        float3(2.0*(x*z + y*w),         2.0*(y*z - x*w),         1.0 - 2.0*(x*x + y*y)) // col 2
    );
}

// Build a 3x3 from explicit row vectors (Metal float3x3 takes columns, so we transpose)
float3x3 mat3FromRows(float3 r0, float3 r1, float3 r2) {
    // Transpose: columns become rows
    return float3x3(
        float3(r0.x, r1.x, r2.x),  // col 0
        float3(r0.y, r1.y, r2.y),  // col 1
        float3(r0.z, r1.z, r2.z)   // col 2
    );
}

constant float SH_C0 = 0.28209479177387814;
constant float SH_C1 = 0.4886025119029199;

float3 evalSHColor(const GaussianGPUData g, float3 dir) {
    float x = dir.x, y = dir.y, z = dir.z;
    float3 color = float3(SH_C0 * g.shR0.x, SH_C0 * g.shG0.x, SH_C0 * g.shB0.x);
    if (g.shDegree > 0) {
        color += float3(
            -SH_C1*y*g.shR0.y + SH_C1*z*g.shR0.z - SH_C1*x*g.shR0.w,
            -SH_C1*y*g.shG0.y + SH_C1*z*g.shG0.z - SH_C1*x*g.shG0.w,
            -SH_C1*y*g.shB0.y + SH_C1*z*g.shB0.z - SH_C1*x*g.shB0.w
        );
    }
    return clamp(color + 0.5, 0.0, 1.0);
}

float3 aces_filmic(float3 x) {
    float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x*(a*x+b)) / (x*(c*x+d)+e), 0.0, 1.0);
}

// MARK: - Project Gaussians

kernel void projectGaussians(
    device const GaussianGPUData*   gaussians  [[ buffer(0) ]],
    device       ProjectedGaussian* projected  [[ buffer(1) ]],
    constant     CameraUniforms&    camera     [[ buffer(2) ]],
    constant     uint&              splatCount [[ buffer(3) ]],
    constant     uint&              sampleStep [[ buffer(4) ]],
    constant     RasterConfig&      config     [[ buffer(5) ]],
    constant     SplatSettings&     settings   [[ buffer(6) ]],
    uint gid [[ thread_position_in_grid ]]
) {
    uint srcIdx = gid * sampleStep;
    if (srcIdx >= splatCount) {
        projected[gid].opacity = 0.0;
        return;
    }

    GaussianGPUData g = gaussians[srcIdx];

    // World position (apply scene model matrix)
    float3 worldPos = (camera.modelMatrix * float4(g.position.xyz, 1.0)).xyz;

    // View-space position
    float3 posView = (camera.viewMatrix * float4(worldPos, 1.0)).xyz;

    // In right-handed view space, camera looks down -Z.
    // posView.z is negative for objects in front of camera.
    // Cull if behind near plane.
    if (posView.z >= -settings.nearClip) {
        projected[gid].opacity = 0.0;
        return;
    }

    // Focal lengths (pixels per unit in NDC)
    float focalX = camera.projectionMatrix[0][0] * camera.screenSize.x * 0.5;
    float focalY = camera.projectionMatrix[1][1] * camera.screenSize.y * 0.5;

    // ---- 3D Covariance ----
    // Sigma3D = (Mmodel * R * S) * (Mmodel * R * S)^T
    float3x3 R = quaternionToMatrix(g.rotation);

    float3x3 S = float3x3(
        float3(g.scale.x * settings.scaleMultiplier, 0, 0),
        float3(0, g.scale.y * settings.scaleMultiplier, 0),
        float3(0, 0, g.scale.z * settings.scaleMultiplier)
    );

    // Upper-left 3x3 of model matrix (column vectors from column-major matrix)
    float3x3 Mmodel = float3x3(
        camera.modelMatrix[0].xyz,  // col 0
        camera.modelMatrix[1].xyz,  // col 1
        camera.modelMatrix[2].xyz   // col 2
    );

    float3x3 M     = Mmodel * R * S;
    float3x3 Sigma = M * transpose(M);

    // ---- Jacobian of perspective projection ----
    // J maps 3D view-space to 2D screen-space (approximate, first-order)
    // posView.z is negative, so we use it directly (focalX/tz where tz < 0)
    float tz  = posView.z;
    float tz2 = tz * tz;

    // Build J as rows then convert to Metal column-major
    // Row 0: [focalX/tz,  0,          -focalX*tx/tz2]
    // Row 1: [0,           focalY/tz, -focalY*ty/tz2]
    // Row 2: [0,           0,          0             ]
    float3x3 J = mat3FromRows(
        float3(focalX/tz,  0.0,        -(focalX*posView.x)/tz2),
        float3(0.0,         focalY/tz, -(focalY*posView.y)/tz2),
        float3(0.0,         0.0,        0.0)
    );

    // Upper-left 3x3 of view matrix (column vectors)
    float3x3 W = float3x3(
        camera.viewMatrix[0].xyz,
        camera.viewMatrix[1].xyz,
        camera.viewMatrix[2].xyz
    );

    // 2D covariance: cov2D = J * W * Sigma3D * W^T * J^T
    float3x3 JW   = J * W;
    float3x3 cov2 = JW * Sigma * transpose(JW);

    // Low-pass filter (anti-aliasing minimum splat size)
    cov2[0][0] += 0.3;
    cov2[1][1] += 0.3;

    float det = cov2[0][0]*cov2[1][1] - cov2[0][1]*cov2[0][1];
    if (det < 1e-6) {
        projected[gid].opacity = 0.0;
        return;
    }

    // ---- Screen-space position ----
    float4 posClip = camera.viewProjectionMatrix * float4(worldPos, 1.0);
    if (posClip.w <= 0.0) {
        projected[gid].opacity = 0.0;
        return;
    }
    float2 posNDC = posClip.xy / posClip.w;

    // NDC to pixel coords.
    // NDC x: -1=left,  +1=right  → pixel x: 0 → screenWidth
    // NDC y: +1=top,   -1=bottom → pixel y: 0=top → screenHeight  (flip Y)
    float2 posScreen = float2(
        ( posNDC.x * 0.5 + 0.5) * camera.screenSize.x,
        (-posNDC.y * 0.5 + 0.5) * camera.screenSize.y
    );

    // Splat screen radius (3-sigma of the larger axis)
    float radius = ceil(3.0 * sqrt(max(cov2[0][0], cov2[1][1])));
    if (radius < 0.5 || radius > config.maxScreenRadius) {
        projected[gid].opacity = 0.0;
        return;
    }

    // Cull if entirely off-screen
    float margin = radius + 1.0;
    if (posScreen.x < -margin || posScreen.x > camera.screenSize.x + margin ||
        posScreen.y < -margin || posScreen.y > camera.screenSize.y + margin) {
        projected[gid].opacity = 0.0;
        return;
    }

    // Inverse 2D covariance (conic)
    float detInv = 1.0 / det;
    float3 conic = float3(
         cov2[1][1] * detInv,   // A
        -cov2[0][1] * detInv,   // B
         cov2[0][0] * detInv    // C
    );

    float3 viewDir = normalize(worldPos - camera.cameraPosition);

    ProjectedGaussian p;
    p.depth   = -posView.z;          // positive distance from camera
    p.index   = srcIdx;
    p.uv      = posScreen;
    p.conic   = float4(conic, 0.0);
    p.color   = float4(evalSHColor(g, viewDir), 0.0);
    p.opacity = g.opacity * settings.opacityMultiplier;
    p.radius  = radius;
    p.pad     = float2(0.0);
    projected[gid] = p;
}

// MARK: - Bin Gaussians into Tiles

kernel void binGaussians(
    device const ProjectedGaussian* projected  [[ buffer(0) ]],
    device       atomic_uint*       tileCounts [[ buffer(1) ]],
    device       uint*              tileList   [[ buffer(2) ]],
    constant     RasterConfig&      config     [[ buffer(3) ]],
    uint gid [[ thread_position_in_grid ]]
) {
    if (gid >= config.renderCount) return;

    ProjectedGaussian p = projected[gid];
    if (p.opacity <= 0.001) return;

    float r = p.radius;
    int2 minT = int2(floor((p.uv - r) / float(config.tileSize)));
    int2 maxT = int2(floor((p.uv + r) / float(config.tileSize)));
    minT = max(minT, int2(0, 0));
    maxT = min(maxT, int2(int(config.tilesX) - 1, int(config.tilesY) - 1));

    for (int ty = minT.y; ty <= maxT.y; ++ty) {
        for (int tx = minT.x; tx <= maxT.x; ++tx) {
            uint tIdx   = uint(ty) * config.tilesX + uint(tx);
            uint offset = atomic_fetch_add_explicit(&tileCounts[tIdx], 1u, memory_order_relaxed);
            if (offset < config.maxGaussiansPerTile) {
                tileList[tIdx * config.maxGaussiansPerTile + offset] = gid;
            }
        }
    }
}

// MARK: - Sort Gaussians within Each Tile (back-to-front by depth)

kernel void sortTiles(
    device const ProjectedGaussian* projected  [[ buffer(0) ]],
    device const atomic_uint*       tileCounts [[ buffer(1) ]],
    device       uint*              tileList   [[ buffer(2) ]],
    constant     RasterConfig&      config     [[ buffer(3) ]],
    uint tIdx [[ thread_position_in_grid ]]
) {
    if (tIdx >= config.tilesX * config.tilesY) return;

    uint count = min(
        atomic_load_explicit(&tileCounts[tIdx], memory_order_relaxed),
        config.maxGaussiansPerTile
    );
    if (count <= 1) return;

    uint base = tIdx * config.maxGaussiansPerTile;

    // Insertion sort: largest depth first (back-to-front for alpha blending)
    for (uint i = 1; i < count; ++i) {
        uint  key      = tileList[base + i];
        float keyDepth = projected[key].depth;
        int   j        = int(i) - 1;
        while (j >= 0 && projected[tileList[base + j]].depth < keyDepth) {
            tileList[base + j + 1] = tileList[base + j];
            j--;
        }
        tileList[base + j + 1] = key;
    }
}

// MARK: - Render Tiles (back-to-front alpha compositing)

kernel void renderTiles(
    device const ProjectedGaussian* projected  [[ buffer(0) ]],
    device const atomic_uint*       tileCounts [[ buffer(1) ]],
    device const uint*              tileList   [[ buffer(2) ]],
    constant     RasterConfig&      config     [[ buffer(3) ]],
    constant     SplatSettings&     settings   [[ buffer(4) ]],
    texture2d<float, access::write> output     [[ texture(0) ]],
    uint2 gid [[ thread_position_in_grid ]]
) {
    if (gid.x >= config.screenWidth || gid.y >= config.screenHeight) return;

    uint tIdx = (gid.y / config.tileSize) * config.tilesX + (gid.x / config.tileSize);
    uint count = min(
        atomic_load_explicit(&tileCounts[tIdx], memory_order_relaxed),
        config.maxGaussiansPerTile
    );

    float  T     = 1.0;
    float3 accum = float3(0.0);
    float2 px    = float2(gid) + 0.5;  // pixel center

    for (uint i = 0; i < count; ++i) {
        ProjectedGaussian p = projected[tileList[tIdx * config.maxGaussiansPerTile + i]];

        float2 d = px - p.uv;
        // Gaussian exponent: -0.5 * (A*dx^2 + 2*B*dx*dy + C*dy^2)
        float power = -0.5 * (p.conic.x*d.x*d.x + 2.0*p.conic.y*d.x*d.y + p.conic.z*d.y*d.y);
        if (power > 0.0) continue;

        float alpha = min(0.99, p.opacity * exp(power));
        if (alpha < settings.minOpacityCutoff) continue;

        accum += p.color.xyz * alpha * T;
        T     *= (1.0 - alpha);
        if (T < 0.01) break;
    }

    float3 bg    = float3(settings.bgColorR, settings.bgColorG, settings.bgColorB);
    float3 color = aces_filmic(accum + bg * T);
    output.write(float4(color, 1.0), gid);
}
