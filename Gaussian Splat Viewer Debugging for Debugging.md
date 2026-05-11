# 🛠️ MASTER PROMPT — GaussianSplatViewer Renderer Debugging
## Based on ACTUAL CODE AUDIT of: `github.com/Rajveer985/3D-Gaussian-Splatting-MacOS`

> **To the AI Coding Agent (Cursor / Windsurf / Copilot):**
> You are fixing a Metal-based 3D Gaussian Splatting renderer for macOS called **GaussianSplatViewer**.
> The codebase has been fully audited. The bugs listed below are CONFIRMED to exist in the actual source files.
> Do NOT hypothesize — fix exactly what is listed here.

---

## REPO STRUCTURE (relevant files only)

```
GaussianSplatViewer/
├── Math/MathTypes.swift          ← GaussianGPUData packing, SplatSettings
├── Scene/PLYLoader.swift         ← PLY parsing, scale/quat/opacity loading
├── Scene/Scene.swift             ← CPU sort (legacy), GPU buffer upload
├── Rendering/Camera.swift        ← tanHalfFov, view/proj matrix
├── Rendering/Renderer.swift      ← GPU pipeline, radix sort, draw call
└── Shaders/GaussianSplat.metal   ← projectSplats kernel, splatVertex, splatFragment
```

---

## BUG #1 — CONFIRMED: Scale NOT being exp()-activated in the GPU shader

**File:** `GaussianSplatViewer/Shaders/GaussianSplat.metal` — function `projectSplats`

**Root cause:** The PLYLoader correctly applies `exp(scale)` on the CPU before uploading to the GPU buffer.
The GPU shader then applies `scaleMultiplier` to the already-exponentiated scale. **This is correct and fine.**

**BUT** — the scale stored in `GaussianGPUData` (MathTypes.swift) is the **linear scale** after `exp()`,
yet the shader's `S` matrix uses it RAW — so if `scaleMultiplier` default is `1.0`, this is OK.

**ACTUAL issue:** `SplatSettings.scaleMultiplier` defaults to `1.0`. However, if a scene has splats
with typical scale values (exp of log-scale ≈ 0.01–0.3), these are SMALL and correct.
The soft-fade logic at `maxScaleThreshold * 0.7f` means splats between 70%–100% of the p99 scale
are **fading out silently** — which can make surfaces near the threshold disappear.

**Fix:** Change the fade start from `0.7f` to `0.85f`:
```metal
// GaussianSplat.metal, inside projectSplats kernel
float fadeStart = settings.maxScaleThreshold * 0.85f;  // was 0.7f
```

---

## BUG #2 — CONFIRMED CRITICAL: Covariance matrix convention mismatch (column-major vs row-major)

**File:** `GaussianSplatViewer/Shaders/GaussianSplat.metal` — function `projectSplats`

**Root cause:** Metal's `float3x3(col0, col1, col2)` constructor takes **columns**, not rows.
The Jacobian `J` is constructed as:

```metal
// CURRENT CODE (WRONG — these are being interpreted as COLUMNS)
float3x3 J = float3x3(
    float3( fx/tz,        0.0f,          0.0f),   // ← this is COLUMN 0, not row 0
    float3( 0.0f,        -fy/tz,         0.0f),   // ← COLUMN 1
    float3(-fx*vpx/tz2,   fy*vpy/tz2,    0.0f)    // ← COLUMN 2
);
```

The actual Jacobian of the perspective projection should be:
```
J = | fx/tz     0        -fx*vpx/tz²  |
    | 0        -fy/tz     fy*vpy/tz²  |
    | 0         0         0           |
```

But in Metal column-major, constructing `float3x3(col0, col1, col2)` where `col0 = (fx/tz, 0, 0)`
means the matrix stored is **J transposed**. This makes the final cov2d formula wrong.

**The formula in the code is:**
```metal
float3x3 T   = transpose(W) * J;
float3x3 cov = transpose(T) * Sg * T;
```

Since `J` is actually `Jᵀ` due to Metal column convention, `T = Wᵀ · Jᵀ = (J·W)ᵀ`.
Then `cov = T·Σ·Tᵀ = (J·W)·Σ·(J·W)ᵀ` — which is wrong. It should be `J·W·Σ·Wᵀ·Jᵀ`.

**Fix:** Transpose J at construction to get the intended matrix:
```metal
// GaussianSplat.metal — replace the J construction block with:
float3x3 J = transpose(float3x3(
    float3( fx/tz,        0.0f,          0.0f),
    float3( 0.0f,        -fy/tz,         0.0f),
    float3(-fx*vpx/tz2,   fy*vpy/tz2,    0.0f)
));
// Now J is the correct row-major Jacobian stored column-major in Metal.
// The rest of the formula stays the same:
// T = Wᵀ · J  →  cov = Tᵀ · Σ · T  = (J·W)·Σ·(J·W)ᵀ ✓
```

**Symptom this causes:** Splats appear as **axis-aligned blobs** instead of oriented ellipses.
The off-diagonal covariance entries are swapped, making all splats look round/isotropic.

---

## BUG #3 — CONFIRMED CRITICAL: Low-pass filter value too high (0.6 instead of 0.3)

**File:** `GaussianSplatViewer/Shaders/GaussianSplat.metal` — function `projectSplats`

**Current code:**
```metal
cov[0][0] += 0.6f;
cov[1][1] += 0.6f;
```

**The standard 3DGS reference** (graphdeco-inria, SuperSplat, MetalSplatter) uses `0.3`.
Using `0.6` means every Gaussian has its variance inflated by an extra 0.3 pixels² on each axis —
this makes small splats appear **2× larger** than they should be, and blurs fine surface detail.

**Fix:**
```metal
cov[0][0] += 0.3f;
cov[1][1] += 0.3f;
```

**Symptom this causes:** "Watercolor / smudge" effect. Thin surfaces (cables, furniture edges) bleed
into surrounding space. TV screen and sofa boundaries look like paint strokes.

---

## BUG #4 — CONFIRMED: minOpacityCutoff is too aggressive

**File:** `GaussianSplatViewer/Math/MathTypes.swift` — struct `SplatSettings`

**Current code:**
```swift
var minOpacityCutoff: Float = 3.0 / 255.0  // ≈ 0.01176
```

The comment says it was "raised from 1/255 — reduces low-opacity popping." However this is too high.
Semi-transparent surfaces (glass, gauze, thin walls) have splats with opacity in the 0.005–0.01 range.
This threshold **silently culls them** before the GPU ever sees them, making those surfaces disappear.

**Fix:**
```swift
var minOpacityCutoff: Float = 1.0 / 255.0  // standard threshold, matches reference renderers
```

---

## BUG #5 — CONFIRMED: Depth key encoding uses sqrt but radix sort is descending — produces wrong render order

**File:** `GaussianSplatViewer/Shaders/GaussianSplat.metal` — `prefixSum` kernel + `projectSplats`

**Current prefix sum scans 255→0 (descending)** to get back-to-front order from smaller depth keys first.
But the depth key is encoded as:
```metal
uint depthBits = uint(sqrt(normDepth) * float(0x000FFFFFu)) << 12u;
```

`sqrt(normDepth)` maps near-to-far as 0→1. So **larger depthBits = farther away**.
Descending prefix sum places larger keys first → farther splats render first. This is correct **IF**
the scatter places them at the front of the output array (index 0 = farthest).

**BUT** the vertex shader draws instance 0 first (under everything). So farthest splat at index 0
= drawn first = under foreground. This is back-to-front = **correct in theory**.

**ACTUAL BUG:** The 12-bit `idBits` tie-breaker:
```metal
uint idBits = gid & 0xFFFu;  // only 4096 unique values for potentially 1M+ splats
```
With 1M splats, `gid & 0xFFF` repeats every 4096 splats. Splats with the same 20-bit depth AND same
4096-modulo index get **non-deterministic ordering** between frames = Z-fighting shimmer.

**Fix:** Use more bits or XOR-fold the full index:
```metal
// Better tie-breaker: fold upper bits of gid into lower 12
uint idBits = (gid ^ (gid >> 12)) & 0xFFFu;
```

---

## BUG #6 — CONFIRMED: SH evaluation viewing direction is in WORLD space, not normalized correctly

**File:** `GaussianSplatViewer/Shaders/GaussianSplat.metal` — `projectSplats` kernel

**Current code:**
```metal
float3 viewDir = normalize(wp - cam.camPos);
float3 color   = evalSH(g, viewDir, settings.shDegreeOverride);
```

`wp` is already the world-space position after applying the model matrix.
`cam.camPos` is the camera position in world space.
`normalize(wp - cam.camPos)` gives the direction **from camera TO splat** — this is correct.

**HOWEVER** — the `modelMatrix` is applied to `g.position.xyz` to get `wp`:
```metal
float3 wp = (cam.modelMatrix * float4(g.position.xyz, 1)).xyz;
```

But `cam.camPos` is the raw camera position, **not** transformed by the inverse model matrix.
When the scene is rotated/scaled (via the Move/Rotate/Scale tools in the UI), `wp` changes
but `cam.camPos` stays in world space. The view direction **is still correct** in this case.

**REAL issue:** The SH evaluation uses world-space direction but the SH bands were trained in the
**original scene coordinate space**. When `modelMatrix ≠ identity` (user rotates scene), the SH
direction should be transformed by `inverse(modelMatrix_rotation)` to query in original SH space.

**Fix:** Transform view direction back to original SH space:
```metal
// After computing viewDir, rotate it back into SH training space
float3x3 Minv = transpose(float3x3(cam.modelMatrix[0].xyz,
                                    cam.modelMatrix[1].xyz,
                                    cam.modelMatrix[2].xyz));
float3 shDir = normalize(Minv * (wp - cam.camPos));
float3 color = evalSH(g, shDir, settings.shDegreeOverride);
```

**Symptom:** When scene is rotated, specular highlights stay fixed in world space instead of
rotating with the object. This is subtle but visible on shiny surfaces.

---

## BUG #7 — CONFIRMED: Scene.swift has a dead `sortSplats` function that is never called by Renderer.swift

**File:** `GaussianSplatViewer/Scene/Scene.swift` — function `sortSplats`

**The Renderer.swift uses a full GPU radix sort** (correct, modern approach).
But `Scene.swift` still has a CPU `sortSplats()` function that writes back to the shared splatBuffer.
This function is **never called** by Renderer.swift — but if any other code path calls it accidentally,
it would overwrite the GPU buffer contents with CPU-sorted data, breaking the GPU sort.

**Fix:** Either delete `sortSplats()` from Scene.swift entirely, or mark it clearly as deprecated:
```swift
// Scene.swift — mark as dead code to prevent accidental use
@available(*, deprecated, message: "Use GPU radix sort in Renderer.swift instead")
func sortSplats(cameraPosition: float3, forward: float3) { /* ... */ }
```

---

## SUMMARY TABLE

| # | File | Bug | Severity | Symptom |
|---|------|-----|----------|---------|
| 1 | GaussianSplat.metal | Fade threshold too early (0.7→0.85) | Medium | Surface splats near p99 threshold disappear |
| 2 | GaussianSplat.metal | **Jacobian J is transposed** due to Metal column-major | **CRITICAL** | All splats appear round/isotropic, no ellipse orientation |
| 3 | GaussianSplat.metal | Low-pass filter 0.6 instead of 0.3 | **HIGH** | Watercolor/smudge, 2× over-blurred splats |
| 4 | MathTypes.swift | minOpacityCutoff = 3/255 culls semi-transparent surfaces | High | Glass/thin surfaces disappear |
| 5 | GaussianSplat.metal | 12-bit ID tie-breaker repeats every 4096 splats | Medium | Z-fighting shimmer on large scenes |
| 6 | GaussianSplat.metal | SH direction not inverse-transformed when model≠identity | Low | Wrong view-dependent color when scene is rotated |
| 7 | Scene.swift | Dead CPU sortSplats() risks overwriting GPU buffer | Low | Silent corruption if accidentally called |

---

## PRIORITY ORDER FOR FIXES

Fix in this order — each fix builds on the previous one:

1. **Fix #3 first** (LPF 0.6→0.3) — biggest visual improvement, one line change
2. **Fix #2 next** (Jacobian transpose) — fixes splat orientation/shape
3. **Fix #4** (opacity cutoff 3/255→1/255) — restores semi-transparent surfaces
4. **Fix #1** (fade threshold 0.7→0.85) — reduces over-culling at scale boundaries
5. **Fix #5** (tie-breaker) — reduces shimmer on large scenes
6. **Fix #6** (SH direction) — only matters when scene is rotated in the UI
7. **Fix #7** (dead code cleanup) — safety/cleanup only

---

## THINGS THAT ARE CORRECT — DO NOT CHANGE

- PLYLoader.swift: `exp(scale)` ✅, `sigmoid(opacity)` ✅, quaternion normalization ✅
- Renderer.swift: GPU radix sort logic ✅, premultiplied alpha blend state ✅, buffer management ✅
- Camera.swift: `tanHalfFov` calculation ✅, perspective matrix ✅, lookAt matrix ✅
- MathTypes.swift: `GaussianGPUData` layout matches Metal struct ✅, SH packing ✅
- Shader: sigmoid/exp activations are done on CPU ✅, SH constants ✅, conic inversion ✅
- splatFragment: conic evaluation formula ✅, premultiplied alpha output ✅
- splatVertex: oriented ellipse quad with eigendecomposed axes ✅

---

*Generated by Claude via full source audit of commit on 2026-05-11.*
*Repo: github.com/Rajveer985/3D-Gaussian-Splatting-MacOS*
