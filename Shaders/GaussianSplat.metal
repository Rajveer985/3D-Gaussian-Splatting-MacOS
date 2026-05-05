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

// Output of the project kernel, input to the render kernel
struct SplatVertex {
    float2 screenPos;   // pixel-space centre
    float2 conic_xy;    // inverse-cov  A, B
    float  conic_z;     // inverse-cov  C
    float  opacity;
    float  radius;
    float  _pad;
    float4 color;       // rgba (a unused)
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

float3x3 quatToMat(float4 q) {
    q = normalize(q);
    float x=q.x, y=q.y, z=q.z, w=q.w;
    // column-major (Metal convention)
    return float3x3(
        float3(1-2*(y*y+z*z),   2*(x*y+z*w),   2*(x*z-y*w)),
        float3(  2*(x*y-z*w), 1-2*(x*x+z*z),   2*(y*z+x*w)),
        float3(  2*(x*z+y*w),   2*(y*z-x*w), 1-2*(x*x+y*y))
    );
}

constant float SH_C0 = 0.28209479177387814f;
constant float SH_C1 = 0.48860251190292f;

float3 shColor(GaussianGPUData g, float3 dir) {
    float3 c = float3(SH_C0*g.shR0.x, SH_C0*g.shG0.x, SH_C0*g.shB0.x);
    if (g.shDegree >= 1) {
        float x=dir.x, y=dir.y, z=dir.z;
        c += float3(-SH_C1*y*g.shR0.y + SH_C1*z*g.shR0.z - SH_C1*x*g.shR0.w,
                    -SH_C1*y*g.shG0.y + SH_C1*z*g.shG0.z - SH_C1*x*g.shG0.w,
                    -SH_C1*y*g.shB0.y + SH_C1*z*g.shB0.z - SH_C1*x*g.shB0.w);
    }
    return saturate(c + 0.5f);
}

// ---------------------------------------------------------------------------
// Kernel 1 – project each Gaussian to screen space
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

    // World → view
    float3 wp  = (cam.modelMatrix * float4(g.position.xyz, 1)).xyz;
    float3 vp  = (cam.viewMatrix  * float4(wp, 1)).xyz;

    // Cull behind camera (view-space z is negative in front)
    if (vp.z >= -0.1f) {
        verts[gid].opacity = 0;
        return;
    }

    // NDC → screen
    float4 cp  = cam.viewProjMatrix * float4(wp, 1);
    float2 ndc = cp.xy / cp.w;
    float2 sp  = float2(( ndc.x*0.5f+0.5f)*cam.screenSize.x,
                        (-ndc.y*0.5f+0.5f)*cam.screenSize.y);

    // Focal lengths
    float fx = cam.projMatrix[0][0] * cam.screenSize.x * 0.5f;
    float fy = cam.projMatrix[1][1] * cam.screenSize.y * 0.5f;

    // 3-D covariance  Σ = (M·R·S)(M·R·S)ᵀ
    float3x3 R = quatToMat(g.rotation);
    float3x3 S = float3x3(float3(g.scale.x,0,0),
                          float3(0,g.scale.y,0),
                          float3(0,0,g.scale.z));
    float3x3 Mm = float3x3(cam.modelMatrix[0].xyz,
                           cam.modelMatrix[1].xyz,
                           cam.modelMatrix[2].xyz);
    float3x3 M  = Mm * R * S;
    float3x3 Sg = M * transpose(M);

    // Jacobian (rows → columns for Metal)
    float tz = vp.z, tz2 = tz*tz;
    float3x3 J = float3x3(
        float3(fx/tz, 0,    0),
        float3(0,    fy/tz, 0),
        float3(-(fx*vp.x)/tz2, -(fy*vp.y)/tz2, 0)
    );
    float3x3 Wm = float3x3(cam.viewMatrix[0].xyz,
                           cam.viewMatrix[1].xyz,
                           cam.viewMatrix[2].xyz);
    float3x3 T   = J * Wm;
    float3x3 cov = T * Sg * transpose(T);
    cov[0][0] += 0.3f;
    cov[1][1] += 0.3f;

    float det = cov[0][0]*cov[1][1] - cov[0][1]*cov[0][1];
    if (det < 1e-6f) { verts[gid].opacity = 0; return; }

    float mid  = 0.5f*(cov[0][0]+cov[1][1]);
    float disc = max(0.1f, mid*mid - det);
    float r    = ceil(3.0f * sqrt(mid + sqrt(disc)));

    if (r < 0.5f || r > 1024.0f) { verts[gid].opacity = 0; return; }

    float di = 1.0f/det;
    verts[gid].screenPos  = sp;
    verts[gid].conic_xy   = float2(cov[1][1]*di, -cov[0][1]*di);
    verts[gid].conic_z    = cov[0][0]*di;
    verts[gid].opacity    = g.opacity;
    verts[gid].radius     = r;
    verts[gid]._pad       = 0;
    verts[gid].color      = float4(shColor(g, normalize(wp - cam.camPos)), 1);
}

// ---------------------------------------------------------------------------
// Vertex shader – expand each splat to a screen-aligned quad
// ---------------------------------------------------------------------------
struct VSOut {
    float4 pos   [[ position ]];
    float2 uv;          // offset from splat centre in pixels
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
        out.pos = float4(0,0,2,1);   // clip away
        out.opacity = 0;
        return out;
    }

    // Quad corners: (-1,-1) (1,-1) (-1,1) (1,1)
    float2 corner = float2((vid & 1) ? 1.0f : -1.0f,
                           (vid & 2) ? 1.0f : -1.0f);
    float2 pixOff = corner * s.radius;
    float2 pix    = s.screenPos + pixOff;

    // Pixel → NDC
    float2 ndc = float2( pix.x / cam.screenSize.x * 2.0f - 1.0f,
                        -pix.y / cam.screenSize.y * 2.0f + 1.0f);

    out.pos      = float4(ndc, 0.0f, 1.0f);
    out.uv       = pixOff;
    out.conic_xy = s.conic_xy;
    out.conic_z  = s.conic_z;
    out.opacity  = s.opacity;
    out.color    = s.color.rgb;
    return out;
}

// ---------------------------------------------------------------------------
// Fragment shader – evaluate 2-D Gaussian
// ---------------------------------------------------------------------------
fragment float4 splatFragment(VSOut in [[ stage_in ]]) {
    if (in.opacity <= 0) discard_fragment();

    float2 d = in.uv;
    float power = -0.5f * (in.conic_xy.x*d.x*d.x
                         + 2.0f*in.conic_xy.y*d.x*d.y
                         + in.conic_z*d.y*d.y);
    if (power > 0) discard_fragment();

    float alpha = min(0.99f, in.opacity * exp(power));
    if (alpha < 1.0f/255.0f) discard_fragment();

    return float4(in.color * alpha, alpha);
}
