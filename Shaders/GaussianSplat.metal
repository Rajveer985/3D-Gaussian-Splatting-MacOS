#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Shared structures  (must match Swift counterparts byte-for-byte)
// ---------------------------------------------------------------------------

struct GaussianGPUData {
    float4 position;   // xyz = world pos,  w = 0
    float4 scale;      // xyz = scale,       w = 0
    float4 rotation;   // quaternion x y z w
    float  opacity;
    uint   shDegree;
    uint2  _pad0;
    float4 shR0, shR1, shR2, shR3;
    float4 shG0, shG1, shG2, shG3;
    float4 shB0, shB1, shB2, shB3;
};

struct CameraUniforms {
    float4x4 viewMatrix;
    float4x4 projMatrix;
    float4x4 viewProjMatrix;
    float4x4 modelMatrix;
    float3   camPos;
    float    _pad;
    float2   screenSize;
    float2   tanHalfFov;
};

// Output of the project kernel — now stores oriented ellipse axes
struct SplatVertex {
    float2 screenPos;   // pixel-space centre
    float2 conic_xy;    // inverse-cov  A, B  (in normalised [-2,2] quad space)
    float  conic_z;     // inverse-cov  C
    float  opacity;
    float  radius;      // max axis length (pixels) — used for culling only
    float  _pad;
    float4 color;       // rgba
    // Oriented axes in pixel space (for the vertex shader quad)
    float2 majorAxis;   // half-major axis vector (pixels)
    float2 minorAxis;   // half-minor axis vector (pixels)
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

float3x3 quatToMat(float4 q) {
    q = normalize(q);
    float x=q.x, y=q.y, z=q.z, w=q.w;
    return float3x3(
        float3(1-2*(y*y+z*z),   2*(x*y+z*w),   2*(x*z-y*w)),
        float3(  2*(x*y-z*w), 1-2*(x*x+z*z),   2*(y*z+x*w)),
        float3(  2*(x*z+y*w),   2*(y*z-x*w), 1-2*(x*x+y*y))
    );
}

// ---------------------------------------------------------------------------
// Spherical Harmonics — full degree 0-3
// ---------------------------------------------------------------------------
constant float SH_C0 = 0.28209479177387814f;
constant float SH_C1 = 0.48860251190292f;
constant float SH_C2_0 =  1.0925484305920792f;
constant float SH_C2_1 = -1.0925484305920792f;
constant float SH_C2_2 =  0.31539156525252005f;
constant float SH_C2_3 = -1.0925484305920792f;
constant float SH_C2_4 =  0.5462742152960396f;
constant float SH_C3_0 = -0.5900435899266435f;
constant float SH_C3_1 =  2.890611442640554f;
constant float SH_C3_2 = -0.4570457994644658f;
constant float SH_C3_3 =  0.3731763325901154f;
constant float SH_C3_4 = -0.4570457994644658f;
constant float SH_C3_5 =  1.445305721320277f;
constant float SH_C3_6 = -0.5900435899266435f;

float3 shColor(GaussianGPUData g, float3 dir) {
    float3 c = float3(SH_C0*g.shR0.x, SH_C0*g.shG0.x, SH_C0*g.shB0.x);

    if (g.shDegree >= 1) {
        float x=dir.x, y=dir.y, z=dir.z;
        c += float3(-SH_C1*y*g.shR0.y + SH_C1*z*g.shR0.z - SH_C1*x*g.shR0.w,
                    -SH_C1*y*g.shG0.y + SH_C1*z*g.shG0.z - SH_C1*x*g.shG0.w,
                    -SH_C1*y*g.shB0.y + SH_C1*z*g.shB0.z - SH_C1*x*g.shB0.w);

        if (g.shDegree >= 2) {
            float xx=x*x, yy=y*y, zz=z*z, xy=x*y, yz=y*z, xz=x*z;
            c += float3(
                SH_C2_0*xy*g.shR1.x + SH_C2_1*yz*g.shR1.y +
                SH_C2_2*(2*zz-xx-yy)*g.shR1.z + SH_C2_3*xz*g.shR1.w +
                SH_C2_4*(xx-yy)*g.shR2.x,
                SH_C2_0*xy*g.shG1.x + SH_C2_1*yz*g.shG1.y +
                SH_C2_2*(2*zz-xx-yy)*g.shG1.z + SH_C2_3*xz*g.shG1.w +
                SH_C2_4*(xx-yy)*g.shG2.x,
                SH_C2_0*xy*g.shB1.x + SH_C2_1*yz*g.shB1.y +
                SH_C2_2*(2*zz-xx-yy)*g.shB1.z + SH_C2_3*xz*g.shB1.w +
                SH_C2_4*(xx-yy)*g.shB2.x
            );

            if (g.shDegree >= 3) {
                c += float3(
                    SH_C3_0*y*(3*xx-yy)*g.shR2.y + SH_C3_1*xy*z*g.shR2.z +
                    SH_C3_2*y*(4*zz-xx-yy)*g.shR2.w + SH_C3_3*z*(2*zz-3*xx-3*yy)*g.shR3.x +
                    SH_C3_4*x*(4*zz-xx-yy)*g.shR3.y + SH_C3_5*(xx-yy)*z*g.shR3.z +
                    SH_C3_6*x*(xx-3*yy)*g.shR3.w,
                    SH_C3_0*y*(3*xx-yy)*g.shG2.y + SH_C3_1*xy*z*g.shG2.z +
                    SH_C3_2*y*(4*zz-xx-yy)*g.shG2.w + SH_C3_3*z*(2*zz-3*xx-3*yy)*g.shG3.x +
                    SH_C3_4*x*(4*zz-xx-yy)*g.shG3.y + SH_C3_5*(xx-yy)*z*g.shG3.z +
                    SH_C3_6*x*(xx-3*yy)*g.shG3.w,
                    SH_C3_0*y*(3*xx-yy)*g.shB2.y + SH_C3_1*xy*z*g.shB2.z +
                    SH_C3_2*y*(4*zz-xx-yy)*g.shB2.w + SH_C3_3*z*(2*zz-3*xx-3*yy)*g.shB3.x +
                    SH_C3_4*x*(4*zz-xx-yy)*g.shB3.y + SH_C3_5*(xx-yy)*z*g.shB3.z +
                    SH_C3_6*x*(xx-3*yy)*g.shB3.w
                );
            }
        }
    }
    return saturate(c + 0.5f);
}

// ---------------------------------------------------------------------------
// Kernel 1 – project each Gaussian to screen space
// Matches the reference implementation (antimatter15 / graphdeco-inria CUDA)
// ---------------------------------------------------------------------------
kernel void projectSplats(
    device const GaussianGPUData* splats   [[ buffer(0) ]],
    device       SplatVertex*     verts    [[ buffer(1) ]],
    constant     CameraUniforms&  cam      [[ buffer(2) ]],
    constant     uint&            count    [[ buffer(3) ]],
    uint gid [[ thread_position_in_grid ]]
) {
    if (gid >= count) return;

    GaussianGPUData g = splats[gid];

    // Model → world → view
    float3 wp  = (cam.modelMatrix * float4(g.position.xyz, 1)).xyz;
    float4 cam4 = cam.viewMatrix * float4(wp, 1);
    float3 vp  = cam4.xyz;

    // Cull behind near plane
    if (vp.z >= -0.2f) {
        verts[gid].opacity = 0;
        return;
    }

    // Clip-space position for frustum culling
    float4 cp = cam.viewProjMatrix * float4(wp, 1);
    float clip = 1.2f * cp.w;
    if (cp.z < -clip || cp.x < -clip || cp.x > clip || cp.y < -clip || cp.y > clip) {
        verts[gid].opacity = 0;
        return;
    }

    // Screen-space centre (pixel coords)
    float2 ndc = cp.xy / cp.w;
    float2 sp  = float2(( ndc.x * 0.5f + 0.5f) * cam.screenSize.x,
                        (-ndc.y * 0.5f + 0.5f) * cam.screenSize.y);

    // Focal lengths from projection matrix (Metal column-major: [col][row])
    float fx = cam.projMatrix[0][0] * cam.screenSize.x * 0.5f;
    float fy = cam.projMatrix[1][1] * cam.screenSize.y * 0.5f;

    // 3-D covariance Σ = (M·R·S)(M·R·S)ᵀ
    // M = upper-left 3x3 of modelMatrix * rotation * scale
    float3x3 R  = quatToMat(g.rotation);
    float3x3 S  = float3x3(float3(g.scale.x, 0, 0),
                            float3(0, g.scale.y, 0),
                            float3(0, 0, g.scale.z));
    float3x3 Mm = float3x3(cam.modelMatrix[0].xyz,
                            cam.modelMatrix[1].xyz,
                            cam.modelMatrix[2].xyz);
    float3x3 M   = Mm * R * S;
    float3x3 Vrk = M * transpose(M);   // 3D covariance

    // Jacobian of the perspective projection at vp
    // Reference: J = [ fx/z,  0,    -fx*x/z²  ]
    //                [  0,  -fy/z,   fy*y/z²  ]   (Y negated for screen-Y-down)
    //                [  0,    0,      0        ]
    float tz  = vp.z;
    float tz2 = tz * tz;
    float3x3 J = float3x3(
        float3( fx/tz,      0.0f,  0.0f),
        float3( 0.0f,  -fy/tz,    0.0f),
        float3(-(fx*vp.x)/tz2,  (fy*vp.y)/tz2, 0.0f)
    );

    // Upper-left 3x3 of view matrix (rotation part only)
    float3x3 W = float3x3(cam.viewMatrix[0].xyz,
                           cam.viewMatrix[1].xyz,
                           cam.viewMatrix[2].xyz);

    // T = Wᵀ · J  (matches reference: T = transpose(mat3(view)) * J)
    float3x3 T = transpose(W) * J;

    // 2D covariance: cov2d = Tᵀ · Vrk · T  (matches reference)
    float3x3 cov3 = transpose(T) * Vrk * T;

    // Extract 2x2 upper-left and add small regularisation
    float a = cov3[0][0] + 0.3f;
    float b = cov3[0][1];
    float c2 = cov3[1][1] + 0.3f;

    // Eigenvalue decomposition of the 2x2 covariance for oriented ellipse
    float mid    = (a + c2) * 0.5f;
    float radius = length(float2((a - c2) * 0.5f, b));
    float lambda1 = mid + radius;
    float lambda2 = mid - radius;

    if (lambda2 < 0.0f) {
        verts[gid].opacity = 0;
        return;
    }

    // Eigenvector of the larger eigenvalue → major axis direction
    float2 diagVec = normalize(float2(b, lambda1 - a));

    // Half-axis lengths clamped to 1024 px (prevents exploding splats near camera)
    float2 majorAxis = min(sqrt(2.0f * lambda1), 1024.0f) * diagVec;
    float2 minorAxis = min(sqrt(2.0f * lambda2), 1024.0f) * float2(diagVec.y, -diagVec.x);

    // Inverse 2x2 covariance (conic) for the fragment shader
    float det = a * c2 - b * b;
    if (det < 1e-6f) { verts[gid].opacity = 0; return; }
    float di = 1.0f / det;

    // Bounding radius for the axis-aligned quad
    float maxR = max(length(majorAxis), length(minorAxis));
    if (maxR < 0.5f) { verts[gid].opacity = 0; return; }

    verts[gid].screenPos  = sp;
    verts[gid].conic_xy   = float2(c2 * di, -b * di);
    verts[gid].conic_z    = a * di;
    verts[gid].opacity    = g.opacity;
    verts[gid].radius     = maxR;
    verts[gid]._pad       = 0;
    verts[gid].color      = float4(shColor(g, normalize(wp - cam.camPos)), 1);
    verts[gid].majorAxis  = majorAxis;
    verts[gid].minorAxis  = minorAxis;
}

// ---------------------------------------------------------------------------
// Vertex shader – expand each splat to an oriented screen-space quad
// The quad corners are ±(majorAxis ± minorAxis) so the bounding box is tight
// ---------------------------------------------------------------------------
struct VSOut {
    float4 pos      [[ position ]];
    float2 uv;          // position in the [-2,2] normalised ellipse space
    float2 conic_xy;
    float  conic_z;
    float  opacity;
    float3 color;
};

vertex VSOut splatVertex(
    uint              vid        [[ vertex_id ]],
    uint              iid        [[ instance_id ]],
    device const SplatVertex* sv [[ buffer(0) ]],
    constant CameraUniforms&  cam[[ buffer(1) ]]
) {
    VSOut out;

    SplatVertex s = sv[iid];
    if (s.opacity <= 0) {
        out.pos     = float4(0, 0, 2, 1);
        out.opacity = 0;
        return out;
    }

    // Four corners of the oriented bounding quad in pixel space
    // corner signs: (-1,-1) (1,-1) (-1,1) (1,1)
    float cx = (vid & 1) ? 1.0f : -1.0f;
    float cy = (vid & 2) ? 1.0f : -1.0f;

    // Pixel offset from splat centre — oriented along ellipse axes
    float2 pixOff = cx * s.majorAxis + cy * s.minorAxis;
    float2 pix    = s.screenPos + pixOff;

    // Pixel → NDC
    float2 ndc = float2( pix.x / cam.screenSize.x * 2.0f - 1.0f,
                        -pix.y / cam.screenSize.y * 2.0f + 1.0f);

    // UV in normalised ellipse space (used by fragment to evaluate Gaussian)
    // majorAxis and minorAxis are half-axes, so corner at (cx,cy) maps to
    // a point whose Mahalanobis distance we evaluate in the fragment shader.
    // We pass the raw pixel offset; the fragment uses the conic directly.
    out.pos      = float4(ndc, 0.0f, 1.0f);
    out.uv       = pixOff;
    out.conic_xy = s.conic_xy;
    out.conic_z  = s.conic_z;
    out.opacity  = s.opacity;
    out.color    = s.color.rgb;
    return out;
}

// ---------------------------------------------------------------------------
// Fragment shader – evaluate 2-D Gaussian in pixel space
// ---------------------------------------------------------------------------
fragment float4 splatFragment(VSOut in [[ stage_in ]]) {
    if (in.opacity <= 0) discard_fragment();

    float2 d = in.uv;
    // Mahalanobis distance squared (×-0.5)
    float power = -0.5f * (in.conic_xy.x * d.x * d.x
                         + 2.0f * in.conic_xy.y * d.x * d.y
                         + in.conic_z * d.y * d.y);
    if (power > 0.0f) discard_fragment();

    float alpha = min(0.99f, in.opacity * exp(power));
    if (alpha < 1.0f / 255.0f) discard_fragment();

    return float4(in.color * alpha, alpha);
}
