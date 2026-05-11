#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Structures
// ---------------------------------------------------------------------------

struct GaussianGPUData {
    float4 position;
    float4 scale;
    float4 rotation;
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

struct SplatVertex {
    float2 screenPos;
    float2 conic_xy;
    float  conic_z;
    float  opacity;
    float  radius;
    float  _pad;
    float4 color;
    float2 majorAxis;   // oriented half-major axis (pixels)
    float2 minorAxis;   // oriented half-minor axis (pixels)
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

// ---------------------------------------------------------------------------
// Math helpers
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
// Spherical Harmonics — degrees 0–3
// ---------------------------------------------------------------------------

constant float SH_C0   = 0.28209479177387814f;
constant float SH_C1   = 0.4886025119029199f;
constant float SH_C2_0 = 1.0925484305920792f;
constant float SH_C2_1 = -1.0925484305920792f;
constant float SH_C2_2 = 0.31539156525252005f;
constant float SH_C2_3 = -1.0925484305920792f;
constant float SH_C2_4 = 0.5462742152960396f;
constant float SH_C3_0 = -0.5900435899266435f;
constant float SH_C3_1 = 2.890611442640554f;
constant float SH_C3_2 = -0.4570457994644658f;
constant float SH_C3_3 = 0.3731763325901154f;
constant float SH_C3_4 = -0.4570457994644658f;
constant float SH_C3_5 = 1.4453057213202770f;
constant float SH_C3_6 = -0.5900435899266435f;

float3 evalSH(const GaussianGPUData g, float3 dir, int degreeOverride) {
    float x = dir.x, y = dir.y, z = dir.z;

    float3 c = float3(SH_C0 * g.shR0.x,
                      SH_C0 * g.shG0.x,
                      SH_C0 * g.shB0.x);

    uint deg = (degreeOverride >= 0) ? uint(degreeOverride) : g.shDegree;

    if (deg >= 1) {
        c += float3(
            -SH_C1*y*g.shR0.y + SH_C1*z*g.shR0.z - SH_C1*x*g.shR0.w,
            -SH_C1*y*g.shG0.y + SH_C1*z*g.shG0.z - SH_C1*x*g.shG0.w,
            -SH_C1*y*g.shB0.y + SH_C1*z*g.shB0.z - SH_C1*x*g.shB0.w
        );
    }

    if (deg >= 2) {
        float xx=x*x, yy=y*y, zz=z*z, x_y=x*y, x_z=x*z, y_z=y*z;
        c += float3(
            SH_C2_0*x_y*g.shR1.x + SH_C2_1*y_z*g.shR1.y +
            SH_C2_2*(2*zz-xx-yy)*g.shR1.z + SH_C2_3*x_z*g.shR1.w +
            SH_C2_4*(xx-yy)*g.shR2.x,

            SH_C2_0*x_y*g.shG1.x + SH_C2_1*y_z*g.shG1.y +
            SH_C2_2*(2*zz-xx-yy)*g.shG1.z + SH_C2_3*x_z*g.shG1.w +
            SH_C2_4*(xx-yy)*g.shG2.x,

            SH_C2_0*x_y*g.shB1.x + SH_C2_1*y_z*g.shB1.y +
            SH_C2_2*(2*zz-xx-yy)*g.shB1.z + SH_C2_3*x_z*g.shB1.w +
            SH_C2_4*(xx-yy)*g.shB2.x
        );
    }

    if (deg >= 3) {
        float xx=x*x, yy=y*y, zz=z*z, x_y=x*y;
        c += float3(
            SH_C3_0*y*(3*xx-yy)*g.shR2.y +
            SH_C3_1*x_y*z*g.shR2.z +
            SH_C3_2*y*(4*zz-xx-yy)*g.shR2.w +
            SH_C3_3*z*(2*zz-3*xx-3*yy)*g.shR3.x +
            SH_C3_4*x*(4*zz-xx-yy)*g.shR3.y +
            SH_C3_5*(xx-yy)*z*g.shR3.z +
            SH_C3_6*x*(xx-3*yy)*g.shR3.w,

            SH_C3_0*y*(3*xx-yy)*g.shG2.y +
            SH_C3_1*x_y*z*g.shG2.z +
            SH_C3_2*y*(4*zz-xx-yy)*g.shG2.w +
            SH_C3_3*z*(2*zz-3*xx-3*yy)*g.shG3.x +
            SH_C3_4*x*(4*zz-xx-yy)*g.shG3.y +
            SH_C3_5*(xx-yy)*z*g.shG3.z +
            SH_C3_6*x*(xx-3*yy)*g.shG3.w,

            SH_C3_0*y*(3*xx-yy)*g.shB2.y +
            SH_C3_1*x_y*z*g.shB2.z +
            SH_C3_2*y*(4*zz-xx-yy)*g.shB2.w +
            SH_C3_3*z*(2*zz-3*xx-3*yy)*g.shB3.x +
            SH_C3_4*x*(4*zz-xx-yy)*g.shB3.y +
            SH_C3_5*(xx-yy)*z*g.shB3.z +
            SH_C3_6*x*(xx-3*yy)*g.shB3.w
        );
    }

    // SuperSplat-compatible: clamp to 0 but allow values > 1 for bright highlights.
    // The sRGB framebuffer will naturally clamp at display time.
    return max(float3(0.0f), c + 0.5f);
}

float3 adjustSaturation(float3 color, float sat) {
    float lum = dot(color, float3(0.2126f, 0.7152f, 0.0722f));
    return saturate(mix(float3(lum), color, sat));
}

// ---------------------------------------------------------------------------
// Kernel 1: Project each Gaussian → SplatVertex + write depth key
//
// depthKeys[i] = quantised view-space depth (for sorting)
//   We store  (uint)((-vp.z / farClip) * 0xFFFFFF)  so that
//   larger uint = farther away → sort descending = back-to-front.
// ---------------------------------------------------------------------------
kernel void projectSplats(
    device const GaussianGPUData* splats    [[ buffer(0) ]],
    device       SplatVertex*     verts     [[ buffer(1) ]],
    constant     CameraUniforms&  cam       [[ buffer(2) ]],
    constant     uint&            count     [[ buffer(3) ]],
    constant     SplatSettings&   settings  [[ buffer(4) ]],
    device       uint*            depthKeys [[ buffer(5) ]],   // for sorting
    uint gid [[ thread_position_in_grid ]]
) {
    if (gid >= count) return;

    // Default: mark as invisible / far
    depthKeys[gid] = 0;

    GaussianGPUData g = splats[gid];

    float effOpacity = g.opacity * settings.opacityMultiplier;
    if (effOpacity < settings.minOpacityCutoff) {
        verts[gid].opacity = 0; return;
    }

    float3 wp = (cam.modelMatrix * float4(g.position.xyz, 1)).xyz;
    float3 vp = (cam.viewMatrix  * float4(wp, 1)).xyz;

    if (vp.z >= -settings.nearClip) { verts[gid].opacity = 0; return; }

    float4 cp = cam.viewProjMatrix * float4(wp, 1);
    if (cp.w <= 0) { verts[gid].opacity = 0; return; }
    float2 ndc = cp.xy / cp.w;
    if (any(abs(ndc) > float2(1.3f))) { verts[gid].opacity = 0; return; }

    float2 sp = float2(
        ( ndc.x * 0.5f + 0.5f) * cam.screenSize.x,
        (-ndc.y * 0.5f + 0.5f) * cam.screenSize.y
    );

    float fx = cam.projMatrix[0][0] * cam.screenSize.x * 0.5f;
    float fy = cam.projMatrix[1][1] * cam.screenSize.y * 0.5f;

    // Optional: cull giant splats (floaters / skybox artefacts).
    // Compare against raw PLY scale (not multiplied by scaleMultiplier) so the
    // cull is scale-invariant — works the same regardless of scene scale tool.
    if (settings.maxScaleThreshold > 0) {
        float maxS = max(g.scale.x, max(g.scale.y, g.scale.z));
        if (maxS > settings.maxScaleThreshold) { verts[gid].opacity = 0; return; }
        // Soft fade: splats approaching the threshold fade out smoothly.
        // This removes the hard edge artifact at the cull boundary.
        float fadeStart = settings.maxScaleThreshold * 0.85f;
        if (maxS > fadeStart) {
            float t = (maxS - fadeStart) / (settings.maxScaleThreshold - fadeStart);
            effOpacity *= (1.0f - t);
            if (effOpacity < settings.minOpacityCutoff) { verts[gid].opacity = 0; return; }
        }
    }

    // ── Covariance projection ────────────────────────────────────────────────
    //
    // Reference implementation (MetalSplatter / graphdeco-inria):
    // Clamp the x/z and y/z ratios to ±1.3*tanHalfFov BEFORE computing the
    // Jacobian. This is the correct way to prevent the Jacobian from blowing
    // up at close range — NOT by clamping tz directly.

    float tz  = vp.z;
    float tz2 = tz * tz;

    // Clamp view-space x,y to the frustum guard band (1.3× FOV)
    float limX = 1.3f * cam.tanHalfFov.x;
    float limY = 1.3f * cam.tanHalfFov.y;
    float vpx  = clamp(vp.x / tz, -limX, limX) * tz;
    float vpy  = clamp(vp.y / tz, -limY, limY) * tz;

    float3x3 R  = quatToMat(g.rotation);
    float3x3 S  = float3x3(
        float3(g.scale.x * settings.scaleMultiplier, 0, 0),
        float3(0, g.scale.y * settings.scaleMultiplier, 0),
        float3(0, 0, g.scale.z * settings.scaleMultiplier)
    );
    float3x3 Mm = float3x3(cam.modelMatrix[0].xyz,
                           cam.modelMatrix[1].xyz,
                           cam.modelMatrix[2].xyz);
    float3x3 M  = Mm * R * S;
    float3x3 Sg = M * transpose(M);

    float3x3 J = transpose(float3x3(
        float3( fx/tz,        0.0f,          0.0f),
        float3( 0.0f,        -fy/tz,         0.0f),
        float3(-fx*vpx/tz2,   fy*vpy/tz2,    0.0f)
    ));
    float3x3 W = float3x3(cam.viewMatrix[0].xyz,
                          cam.viewMatrix[1].xyz,
                          cam.viewMatrix[2].xyz);
    // T = Wᵀ · J  (matches graphdeco-inria reference: T = transpose(mat3(view)) * J)
    float3x3 T   = transpose(W) * J;
    // cov2d = Tᵀ · Σ · T  (matches reference)
    float3x3 cov = transpose(T) * Sg * T;

    // Low-pass filter: every Gaussian should cover at least ~1 pixel.
    // Standard 3DGS reference value (graphdeco-inria, SuperSplat, MetalSplatter).
    cov[0][0] += 0.3f;
    cov[1][1] += 0.3f;

    float det = cov[0][0]*cov[1][1] - cov[0][1]*cov[0][1];
    if (det < 1e-6f) { verts[gid].opacity = 0; return; }

    float mid  = 0.5f * (cov[0][0] + cov[1][1]);
    float disc = max(0.1f, mid*mid - det);
    float r    = ceil(3.0f * sqrt(mid + sqrt(disc)));

    // Cull splats that project too large — these are always floaters or
    // splats seen from outside the trained region.
    // Raised to 1024px so close-up splats don't vanish when the camera approaches.
    if (r < 0.5f || r > 1024.0f) { verts[gid].opacity = 0; return; }

    if (sp.x+r < 0 || sp.x-r > cam.screenSize.x ||
        sp.y+r < 0 || sp.y-r > cam.screenSize.y) {
        verts[gid].opacity = 0; return;
    }

    float di = 1.0f / det;

    // Transform view direction back into original SH training space.
    // When modelMatrix ≠ identity (user rotated/scaled the scene), the SH
    // bands were trained in the original coordinate space, so we must undo
    // the model rotation before querying SH coefficients.
    float3x3 Minv = transpose(float3x3(cam.modelMatrix[0].xyz,
                                        cam.modelMatrix[1].xyz,
                                        cam.modelMatrix[2].xyz));
    float3 shDir = normalize(Minv * (wp - cam.camPos));
    float3 color = evalSH(g, shDir, settings.shDegreeOverride);
    color = adjustSaturation(color, settings.saturation);

    // SH evaluation produces sRGB-space colors (matching the training pipeline).
    // Metal's sRGB framebuffer (.bgra8Unorm_srgb) expects LINEAR input and applies
    // gamma automatically. Convert sRGB → linear using fast gamma-2.2 approximation.
    // Use multiply instead of pow() for performance — pow() is ~10x slower on GPU.
    color = color * color;  // gamma 2.0 approximation — fast, visually close to 2.2

    verts[gid].screenPos = sp;
    verts[gid].conic_xy  = float2(cov[1][1]*di, -cov[0][1]*di);
    verts[gid].conic_z   = cov[0][0]*di;
    verts[gid].opacity   = effOpacity;
    verts[gid].radius    = r;
    verts[gid]._pad      = 0;
    verts[gid].color     = float4(color, 1);

    // Compute oriented ellipse axes for the vertex shader quad.
    // Eigendecompose the 2x2 covariance to get the principal directions.
    float a = cov[0][0], b = cov[0][1], c = cov[1][1];
    float eigMid    = (a + c) * 0.5f;
    float eigRadius = length(float2((a - c) * 0.5f, b));
    float lambda1   = eigMid + eigRadius;
    float lambda2   = eigMid - eigRadius;
    float2 diagVec  = (abs(b) > 1e-6f) ? normalize(float2(b, lambda1 - a))
                                        : float2(1.0f, 0.0f);
    verts[gid].majorAxis = min(3.0f * sqrt(max(lambda1, 0.0f)), 1024.0f) * diagVec;
    verts[gid].minorAxis = min(3.0f * sqrt(max(lambda2, 0.0f)), 1024.0f) * float2(diagVec.y, -diagVec.x);

    // Depth key: 20-bit sqrt-mapped depth | 12-bit splat index tie-breaker = 32 bits.
    // 20-bit depth = 1M depth levels. 12-bit ID = 4096 tie-breaker states.
    // Safer bit split while GPU scan architecture is being stabilized.
    float3 camForward = -float3(cam.viewMatrix[0].z, cam.viewMatrix[1].z, cam.viewMatrix[2].z);
    float depth = dot(wp - cam.camPos, camForward);

    float pixelWorldSize = abs(tz) / max(fx, 1.0f);
    float biasedDepth = depth - r * pixelWorldSize * 0.05f;

    float normDepth = clamp(biasedDepth / max(settings.farClip, 1.0f), 0.0f, 1.0f);

    // sqrt maps more bits to near-camera range
    uint depthBits = uint(sqrt(normDepth) * float(0x000FFFFFu)) << 12u;
    // 12-bit splat index — XOR-fold upper bits for better tie-breaking on large scenes
    uint idBits    = (gid ^ (gid >> 12)) & 0xFFFu;
    depthKeys[gid] = depthBits | idBits;
}

// ---------------------------------------------------------------------------
// Kernel 2: Initialise sort index buffer  (sortIndices[i] = i)
// ---------------------------------------------------------------------------
kernel void initSortIndices(
    device uint* sortIndices [[ buffer(0) ]],
    constant uint& count     [[ buffer(1) ]],
    uint gid [[ thread_position_in_grid ]]
) {
    if (gid < count) sortIndices[gid] = gid;
}

// ---------------------------------------------------------------------------
// Kernel 3: Radix sort — one pass per 8-bit digit (3 passes for 24-bit key)
//
// Standard 2-pass per-digit approach:
//   Pass A (countDigits):  histogram of digit values across all elements
//   Pass B (scatterDigit): scatter elements to output using prefix-sum offsets
//
// We do this on the CPU side using a simple parallel prefix sum since
// Metal doesn't have a built-in sort. For 1M splats this runs in ~5ms.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Kernel 3a: Radix sort — count pass
// Count occurrences of each 8-bit digit value for the current radix pass
// ---------------------------------------------------------------------------
kernel void radixCount(
    device const uint* keys      [[ buffer(0) ]],   // depth keys
    device const uint* indices   [[ buffer(1) ]],   // current index order
    device       uint* histogram [[ buffer(2) ]],   // 256 buckets
    constant     uint& count     [[ buffer(3) ]],
    constant     uint& bitShift  [[ buffer(4) ]],
    uint gid [[ thread_position_in_grid ]]
) {
    if (gid >= count) return;
    uint key    = keys[indices[gid]];
    uint digit  = (key >> bitShift) & 0xFFu;
    atomic_fetch_add_explicit((device atomic_uint*)&histogram[digit], 1u, memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// Kernel 3b: GPU Exclusive Prefix Sum — simple serial scan by thread 0
//
// 256 buckets is trivially small. A single thread loops through all 256
// entries and accumulates the exclusive prefix sum. This is mathematically
// foolproof and takes < 0.01ms on any Apple GPU.
// Back-to-front scan (255 → 0) produces back-to-front render order.
// ---------------------------------------------------------------------------
kernel void prefixSum(
    device uint* histogram [[ buffer(0) ]]
) {
    // Only thread 0 does the work — serial, no sync issues possible
    uint sum = 0;
    for (int b = 255; b >= 0; b--) {
        uint c = histogram[b];
        histogram[b] = sum;
        sum += c;
    }
}

// ---------------------------------------------------------------------------
// Kernel 3c: Radix sort — scatter pass
// Scatter elements into output buffer using GPU prefix-sum offsets
// ---------------------------------------------------------------------------
kernel void radixScatter(
    device const uint* keysIn    [[ buffer(0) ]],
    device const uint* indicesIn [[ buffer(1) ]],
    device       uint* indicesOut[[ buffer(2) ]],
    device       uint* offsets   [[ buffer(3) ]],   // exclusive prefix sum of histogram
    constant     uint& count     [[ buffer(4) ]],
    constant     uint& bitShift  [[ buffer(5) ]],
    uint gid [[ thread_position_in_grid ]]
) {
    if (gid >= count) return;
    uint idx    = indicesIn[gid];
    uint key    = keysIn[idx];
    uint digit  = (key >> bitShift) & 0xFFu;
    uint pos    = atomic_fetch_add_explicit((device atomic_uint*)&offsets[digit], 1u, memory_order_relaxed);
    indicesOut[pos] = idx;
}

// ---------------------------------------------------------------------------
// Vertex shader: draw each splat as a screen-aligned quad.
// Uses sortIndices to fetch splats in back-to-front order.
//
// The quad corners are placed at ±majorAxis ± minorAxis (pixel space).
// Since majorAxis ⊥ minorAxis (eigenvectors of symmetric matrix), this
// forms a rectangle — the tightest axis-aligned bounding box of the ellipse.
// The fragment shader evaluates the Gaussian falloff inside, producing a
// smooth ellipse. At high sharpness the falloff is steep and the rectangular
// boundary becomes visible — keep sharpness near 1.0 for smooth results.
// ---------------------------------------------------------------------------
struct VSOut {
    float4 pos      [[ position ]];
    float2 uv;          // pixel offset from splat centre (for conic evaluation)
    float2 conic_xy;
    float  conic_z;
    float  opacity;
    float3 color;
    float  sharpness;
};

vertex VSOut splatVertex(
    uint                      vid      [[ vertex_id   ]],
    uint                      iid      [[ instance_id ]],
    device const uint*        sortIdx  [[ buffer(0)   ]],   // sorted indices
    device const SplatVertex* sv       [[ buffer(1)   ]],
    constant CameraUniforms&  cam      [[ buffer(2)   ]],
    constant SplatSettings&   settings [[ buffer(3)   ]]
) {
    VSOut out;

    uint splatIdx = sortIdx[iid];
    SplatVertex s = sv[splatIdx];

    if (s.opacity <= 0) {
        out.pos       = float4(0, 0, 2, 1);
        out.opacity   = 0;
        out.sharpness = 1;
        return out;
    }

    // Corner signs: vid 0=(-1,-1), 1=(1,-1), 2=(-1,1), 3=(1,1)
    float cx = (vid & 1) ? 1.0f : -1.0f;
    float cy = (vid & 2) ? 1.0f : -1.0f;

    // Pixel offset from splat centre along oriented ellipse axes.
    // majorAxis ⊥ minorAxis (eigenvectors), so this is always a rectangle.
    float2 pixOff = cx * s.majorAxis + cy * s.minorAxis;
    float2 pix    = s.screenPos + pixOff;

    float2 ndc = float2( pix.x / cam.screenSize.x * 2.0f - 1.0f,
                        -pix.y / cam.screenSize.y * 2.0f + 1.0f);

    out.pos       = float4(ndc, 0.5f, 1.0f);
    out.uv        = pixOff;   // passed to fragment for conic (Mahalanobis) evaluation
    out.conic_xy  = s.conic_xy;
    out.conic_z   = s.conic_z;
    out.opacity   = s.opacity;
    out.color     = s.color.rgb;
    out.sharpness = settings.gaussianSharpness;
    return out;
}

// ---------------------------------------------------------------------------
// Fragment shader — evaluates the 2D Gaussian at each pixel.
//
// The conic (A,B,C) is the inverse of the 2D covariance in pixel space.
// power = -0.5 * [dx dy] * [[A B],[B C]] * [dx dy]ᵀ
// alpha = opacity * exp(power)   — this is the standard 3DGS formula.
//
// Blending: standard (non-premultiplied) alpha, matching SuperSplat:
//   out.rgb = src.rgb * src.a + dst.rgb * (1 - src.a)
// ---------------------------------------------------------------------------
fragment float4 splatFragment(VSOut in [[ stage_in ]]) {
    if (in.opacity <= 0) discard_fragment();

    float2 d     = in.uv;
    float  power = in.sharpness * (-0.5f * (in.conic_xy.x * d.x * d.x
                                          + 2.0f * in.conic_xy.y * d.x * d.y
                                          + in.conic_z * d.y * d.y));
    if (power > 0.0f) discard_fragment();

    // Natural Gaussian falloff — no hard clamp so the soft edge is preserved.
    float alpha = in.opacity * exp(power);
    if (alpha < 1.0f / 255.0f) discard_fragment();

    // Premultiplied alpha output — matches blend mode (.one, .oneMinusSourceAlpha).
    // out.rgb = color * alpha, out.a = alpha
    return float4(in.color * alpha, alpha);
}
