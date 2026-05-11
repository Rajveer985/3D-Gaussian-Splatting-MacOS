# 🛠️ MASTER PROMPT — GaussianSplatViewer Phase 2 Debugging
## Based on ACTUAL CODE AUDIT — commit `47b548d` ("Some work done")
## Repo: github.com/Rajveer985/3D-Gaussian-Splatting-MacOS

> **To the AI Coding Agent:**
> Phase 1 fixes (Jacobian transpose, LPF 0.3, opacity cutoff) have been applied and are confirmed correct.
> The following bugs remain in the CURRENT codebase. Each one is verified line-by-line against the actual source.
> Do NOT re-apply Phase 1 fixes — they are already in.

---

## BUG #1 — CRITICAL: Quad too small — splats clipped at 1.4σ instead of 3σ

**File:** `GaussianSplatViewer/Shaders/GaussianSplat.metal` — function `projectSplats`

**Current code (lines 326–327):**
```metal
verts[gid].majorAxis = min(sqrt(2.0f * max(lambda1, 0.0f)), 1024.0f) * diagVec;
verts[gid].minorAxis = min(sqrt(2.0f * max(lambda2, 0.0f)), 1024.0f) * float2(diagVec.y, -diagVec.x);
```

**Why this is wrong:**
The quad half-extent should cover **3σ** (3 standard deviations) of the Gaussian, which captures 99.7%
of its weight. The standard deviation along an axis is `sqrt(eigenvalue)`, so the extent must be
`3.0 * sqrt(eigenvalue)`.

The current code uses `sqrt(2.0 * lambda)` = `sqrt(2) * sqrt(lambda)` ≈ `1.414 * sqrt(lambda)`.
This is only **1.414σ** — the quad is **less than half the required size**.

For a splat with `lambda1 = 100`:
- Correct:  `3 * sqrt(100)` = **30 pixels** half-extent
- Current:  `sqrt(2 * 100)` = **14.1 pixels** half-extent → splat gets clipped at its edges

**Visual symptom:** Every splat looks chopped off before it fades to transparent. Splats that should
softly fade into the background instead have a hard invisible boundary at ~50% of their actual size.
This gives the "playing card" / solid-edged appearance.

**Fix — replace both lines:**
```metal
// GaussianSplat.metal — projectSplats kernel, replace the majorAxis/minorAxis assignment:
verts[gid].majorAxis = min(3.0f * sqrt(max(lambda1, 0.0f)), 1024.0f) * diagVec;
verts[gid].minorAxis = min(3.0f * sqrt(max(lambda2, 0.0f)), 1024.0f) * float2(diagVec.y, -diagVec.x);
```

Also update the radius calculation above it to stay consistent (it's used for screen-space culling):
```metal
// Current (line ~278):
float r = ceil(3.0f * sqrt(mid + sqrt(disc)));
// This is already correct — do NOT change this line.
```

---

## BUG #2 — CRITICAL: No depth stencil state set — Metal defaults to depth WRITE ENABLED

**File:** `GaussianSplatViewer/Rendering/Renderer.swift`

**Current state:** There is NO `MTLDepthStencilDescriptor` created anywhere in the Renderer.
The view has `depthStencilPixelFormat = .depth32Float` and the pipeline has `depthAttachmentPixelFormat = .depth32Float`,
but **no `MTLDepthStencilState` is ever created or bound** to the render encoder.

**Metal's default behavior when no depth stencil state is set:**
- `depthWriteEnabled = true` (writes depth for every fragment)
- `depthCompareFunction = .always` (passes all fragments)

The combination of `.always` compare + depth writing means: the first splat rendered writes its depth,
and subsequent splats at the same pixel still pass (because `.always`). So blending happens. But
when the depth compare function eventually gets initialized to `.less` by the driver on some hardware,
splats that are sorted farther get hard-clipped by closer splats' written depth values.

**The real danger:** Behavior is undefined/driver-dependent. On Apple M1 Pro this can manifest as
sharp polygon edges where two large splats intersect.

**Fix — add to `Renderer` class and `buildPipelines()`:**

**Step 1:** Add a property to store the state:
```swift
// Renderer.swift — add this property alongside other Metal objects:
var depthStencilState: MTLDepthStencilState?
```

**Step 2:** Create it inside `buildPipelines()`, after the render PSO:
```swift
// Renderer.swift — add at the end of buildPipelines():
let dsDesc = MTLDepthStencilDescriptor()
dsDesc.depthWriteEnabled   = false          // NEVER write depth — splats are transparent
dsDesc.depthCompareFunction = .always       // ALWAYS pass — sorting handles order
depthStencilState = device.makeDepthStencilState(descriptor: dsDesc)
print(depthStencilState != nil ? "✓ Depth stencil state (write=off)" : "✗ Depth stencil state failed")
```

**Step 3:** Bind it in the render encoder block (inside `draw(in:)`):
```swift
// Renderer.swift — inside the render encoder block, after setRenderPipelineState:
if let pso = renderPSO, let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
    enc.setRenderPipelineState(pso)
    if let dss = depthStencilState {
        enc.setDepthStencilState(dss)   // ← ADD THIS LINE
    }
    enc.setVertexBuffer(sortedBuf, offset: 0,      index: 0)
    // ... rest unchanged
}
```

---

## BUG #3 — CONFIRMED CORRECT (do NOT change): Fragment shader UV space

**The Google AI Studio Phase 2 prompt claims the UV/d coordinate space is wrong.**
**This is INCORRECT for your specific codebase.**

In your code:
```metal
// splatVertex — pixOff is in PIXEL SPACE (screen pixels)
float2 pixOff = cx * s.majorAxis + cy * s.minorAxis;   // pixels ✓
out.uv        = pixOff;   // passed to fragment as pixel offset ✓
```

```metal
// splatFragment — d is pixel offset, conic is inverse of pixel-space cov2d
float2 d     = in.uv;        // pixels ✓
float  power = -0.5f * (conic_xy.x * d.x * d.x + 2.0f * conic_xy.y * d.x * d.y + conic_z * d.y * d.y);
// conic = inv(cov2d), cov2d is in pixel space → conic is in 1/pixel² → power is dimensionless ✓
```

The conic is `inv(cov2d)` where `cov2d` is in pixel² units (output of the Jacobian projection).
`d` is in pixels. So `d^T * conic * d` = pixels * (1/pixels²) * pixels = dimensionless. **Correct.**

**Do NOT change the UV passing or conic evaluation. It is mathematically correct.**

---

## BUG #4 — CONFIRMED CORRECT (do NOT change): Blend state

**Google AI Studio Phase 2 says blend state might be wrong. It is already correct:**

```swift
// Renderer.swift lines 149–157 — already correct premultiplied alpha:
ca.isBlendingEnabled           = true
ca.sourceRGBBlendFactor        = .one
ca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
ca.sourceAlphaBlendFactor      = .one
ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
```

```metal
// splatFragment — already outputs premultiplied alpha:
return float4(in.color * alpha, alpha);   // ✓
```

**Do NOT change these. They are correct.**

---

## BUG #5 — MEDIUM: `radius` variable in `projectSplats` is inconsistent with new quad size

**File:** `GaussianSplatViewer/Shaders/GaussianSplat.metal` — `projectSplats`

The `radius` variable (used for screen-space culling, i.e. "is this splat off-screen?") is:
```metal
float r = ceil(3.0f * sqrt(mid + sqrt(disc)));
```
where `mid + sqrt(disc)` = `lambda1` (the larger eigenvalue). So `r = ceil(3*sqrt(lambda1))`.

After fixing Bug #1, `majorAxis` magnitude = `3*sqrt(lambda1)`. These now match. ✓

But the stored `verts[gid].radius` (used for... nothing in the current fragment shader) is set to `r`.
This is fine — just noting it's consistent after the fix.

**No change needed here.**

---

## BUG #6 — LOW: Depth attachment `loadAction` not set — stale depth buffer

**File:** `GaussianSplatViewer/Rendering/Renderer.swift` — `draw(in:)` function

The render pass descriptor sets color attachment load/store actions but NOT depth attachment:
```swift
rpd.colorAttachments[0].loadAction  = .clear   // ✓
rpd.colorAttachments[0].storeAction = .store    // ✓
// depth attachment load/store → NOT SET → defaults vary by driver
```

After Bug #2 fix (`depthWriteEnabled = false`), depth will never be written, so the stale buffer
won't cause visible issues. But for correctness and GPU tile memory efficiency, set explicitly:

```swift
// Renderer.swift — inside draw(), after the color attachment setup, add:
rpd.depthAttachment.loadAction  = .clear
rpd.depthAttachment.storeAction = .dontCare   // we never read depth back → don't waste bandwidth
```

---

## SUMMARY — What to fix vs what to leave alone

| # | File | Change | Priority | Status |
|---|------|--------|----------|--------|
| 1 | GaussianSplat.metal | `sqrt(2*lambda)` → `3*sqrt(lambda)` for quad axes | **CRITICAL** | 🔴 Fix now |
| 2 | Renderer.swift | Create & bind `MTLDepthStencilState` with write=false | **CRITICAL** | 🔴 Fix now |
| 3 | GaussianSplat.metal | UV / d coordinate space | ✅ Already correct | ⛔ Do NOT change |
| 4 | Renderer.swift | Premultiplied alpha blend state | ✅ Already correct | ⛔ Do NOT change |
| 5 | GaussianSplat.metal | radius consistency | ✅ Fine after fix #1 | — No change |
| 6 | Renderer.swift | Depth attachment load/store actions | Low | 🟡 Nice to have |

---

## PHASE 1 FIXES — Already applied, confirmed correct, do NOT re-apply

- ✅ Jacobian transpose: `J = transpose(float3x3(...))` 
- ✅ LPF: `cov[0][0] += 0.3f` (was 0.6)
- ✅ Opacity cutoff: `1.0/255.0` (was 3.0/255.0)
- ✅ Fade threshold: `maxScaleThreshold * 0.85f` (was 0.7)
- ✅ SH direction: inverse model rotation applied
- ✅ Tie-breaker: `(gid ^ (gid >> 12)) & 0xFFF`

---

## Expected visual result after Phase 2 fixes

After fixing Bug #1 (quad size) and Bug #2 (depth write):
- Splats will have **soft, fully faded edges** extending to 3σ
- No more hard rectangular boundaries / "playing card" look
- No more sharp polygon intersection lines where large splats overlap
- Semi-transparent surfaces (glass, thin objects) will composite correctly

*Generated by Claude via full source audit of commit `47b548d` on 2026-05-11.*
*Repo: github.com/Rajveer985/3D-Gaussian-Splatting-MacOS*
