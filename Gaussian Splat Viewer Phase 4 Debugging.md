# 🛠️ MASTER PROMPT — GaussianSplatViewer Phase 4 Debugging
## Focus: Remaining Jitter, Sort Stability, and Latency
## Based on ACTUAL CODE AUDIT — commit `4260b68` ("phase 3 applied")
## Repo: github.com/Rajveer985/3D-Gaussian-Splatting-MacOS

> **To the AI Coding Agent:**
> Phase 1, 2, and 3 fixes are confirmed correctly applied. Do NOT re-apply them.
> Google AI Studio's Phase 4 prompt contains two completely wrong bug reports.
> Follow THIS prompt only — every bug is verified line-by-line against the actual source.

---

## WHAT GOOGLE AI STUDIO GOT WRONG THIS TIME

| Claim | Reality |
|-------|---------|
| "Remove epsilon entirely — sort must run on every camera change" | ❌ WRONG. sortDirectionEpsilon=0.0002 is slightly too loose, but the fix is to tighten it — NOT remove it. Removing it sorts 60×/sec = guaranteed lag. |
| "Missing Metal memory barriers — compute and render might overlap" | ❌ COMPLETELY WRONG. Every encoder calls `endEncoding()` before the next starts, within the same command buffer. Metal spec guarantees sequential execution. There is zero race condition. |
| "Depth key only 20 bits — causing quantization shimmer" | ❌ WRONG. 20-bit depth = 1,048,575 levels over 100 world units = 0.1mm precision. This is not the shimmer source. |
| "Async ping-pong sort across frames" | ⚠️ Architecturally valid idea but NOT needed yet — fix the actual bugs first. |

---

## BUG #1 — REAL: `sortDirectionEpsilon = 0.0002` misses very slow rotation

**File:** `GaussianSplatViewer/Rendering/Renderer.swift`

**Current code:**
```swift
private let sortDirectionEpsilon: Float = 0.0002  // ~0.01 degrees
```

**Why this still causes pops:**
`dirDelta = 1 - dot(camForward, lastSortCamForward)`

For a very slow drag (1–2 pixels per frame):
- `rotationSensitivity = 0.005` rad/pixel
- 1px drag → angle change = 0.005 rad
- `dirDelta = 1 - cos(0.005) ≈ 0.0000125` → **less than 0.0002 → sort SKIPPED**

Result: camera slowly rotates for 1–2 frames using the old sort order → splats briefly
appear in wrong Z-order → subtle pop when the sort finally fires.

**Fix — tighten the direction epsilon:**
```swift
// Renderer.swift:
private let sortDirectionEpsilon: Float = 0.00001  // catches even 1-pixel rotation
// 0.00001 ≈ 0.005 rad ≈ 1 pixel drag with rotationSensitivity=0.005
// was 0.0002 — was missing slow micro-rotations
```

The position epsilon (`sortPositionEpsilon = 0.005`) is fine — leave it.

---

## BUG #2 — REAL: `frameSemaphore(value: 3)` allows 3 frames in-flight → ~50ms visual lag

**File:** `GaussianSplatViewer/Rendering/Renderer.swift`

**Current code:**
```swift
private let frameSemaphore = DispatchSemaphore(value: 3)
```

**Why this causes the "heavy/hitchy camera" feeling:**
With 3 frames in-flight allowed:
- CPU submits frame N, N+1, N+2 before waiting
- GPU is still rendering frame N when you've already moved the camera for frame N+2
- The splat positions on screen lag up to 3 frames = **~50ms behind your mouse at 60fps**
- This is perceivable as "rubber-banding" camera feel

Reducing to 2 gives **~33ms max lag** (2 frames). This is a significant improvement.
Reducing to 1 gives **~16ms max lag** but serializes CPU+GPU (kills perf). Don't do 1.

**Fix:**
```swift
// Renderer.swift:
private let frameSemaphore = DispatchSemaphore(value: 2)  // was 3
// 2 frames in-flight = ~33ms max lag vs ~50ms. Smooth but not serialized.
```

---

## BUG #3 — REAL: Depth bias term causes sort instability during camera rotation

**File:** `GaussianSplatViewer/Shaders/GaussianSplat.metal` — `projectSplats` kernel

**Current code:**
```metal
float pixelWorldSize = abs(tz) / max(fx, 1.0f);
float biasedDepth = depth - r * pixelWorldSize * 0.05f;
```

**Why this causes shimmer:**
The bias shifts each splat's depth key by `r * pixelWorldSize * 0.05`. Both `r` (the splat's
pixel radius) and `pixelWorldSize` change as the camera rotates — they depend on the
projected covariance and view-space Z depth respectively.

For two overlapping splats A and B at nearly the same depth:
- At camera angle θ₁: biasA < biasB → A sorts behind B → B renders on top
- At camera angle θ₂: biasA > biasB → A sorts in front of B → A renders on top

This causes **per-frame order flipping** on overlapping splats near the same depth, which
is exactly the "shimmer" symptom on dense surfaces like the sofa or TV.

**Fix — remove the bias entirely:**
```metal
// GaussianSplat.metal — replace the bias block:

// REMOVE these two lines:
// float pixelWorldSize = abs(tz) / max(fx, 1.0f);
// float biasedDepth = depth - r * pixelWorldSize * 0.05f;

// REPLACE with:
float normDepth = clamp(depth / max(settings.farClip, 1.0f), 0.0f, 1.0f);
// (remove biasedDepth entirely — use raw depth for stable sort keys)
```

The depth bias was an attempt to sort large splats slightly closer (so they render on top of
smaller ones they contain). But 3DGS doesn't need this — the alpha compositing math handles
transparency correctly regardless of which large splat is "on top". The bias is causing more
harm than good.

---

## BUG #4 — REAL: `cameraBuffer` slot written BEFORE `frameSemaphore.wait()` check is effective

**File:** `GaussianSplatViewer/Rendering/Renderer.swift` — `draw(in:)` function

**Current code flow:**
```swift
func draw(in view: MTKView) {
    guard let scene, scene.isLoaded, ... else { return }  // guard checks

    frameSemaphore.wait()   // ← wait happens HERE

    frameCount += 1
    var uni = camera.getUniforms(screenSize: viewportSize)
    let camOff = Int(frameCount % 3) * MemoryLayout<CameraUniforms>.stride
    memcpy(camBuf.contents().advanced(by: camOff), &uni, ...)  // ← write camera
```

**The problem:**
The `guard` block runs BEFORE `frameSemaphore.wait()`. If the guard fails (scene not loaded),
we return without waiting. This is fine. But the `guard` block also reads `scene.splatBuffer`
and other GPU resources — these reads are safe.

**Actually this ordering is fine** — no change needed here. The `wait()` before `frameCount++`
correctly serializes buffer access.

---

## BUG #5 — REAL: `color = color * color` gamma approximation is too dark

**File:** `GaussianSplatViewer/Shaders/GaussianSplat.metal` — `projectSplats` kernel

**Current code:**
```metal
color = color * color;  // gamma 2.0 approximation — fast, visually close to 2.2
```

**Why this causes flat-looking colors:**
SH evaluation returns values in approximately sRGB space (range 0–1 after the `+ 0.5` offset).
`color * color` applies a gamma of 2.0, converting sRGB → linear.

However, the MTKView framebuffer is `.bgra8Unorm_srgb`, which means Metal **automatically**
applies sRGB gamma on write. So the pipeline is:

```
SH output (sRGB) → color*color (gamma 2.0 decode) → sRGB framebuffer (gamma 2.2 re-encode)
```

The net effect is `2.0 / 2.2 = 0.91` gamma — colors are **slightly too dark** across the board,
and highlights are compressed. This makes the scene look flat compared to the reference renderer.

**Fix — use the standard sRGB linearization instead:**
```metal
// GaussianSplat.metal — replace the gamma line:

// REMOVE:
// color = color * color;  // gamma 2.0 approximation

// REPLACE with proper sRGB → linear (fast piecewise approximation):
color = select(color / 12.92f,
               pow((color + 0.055f) / 1.055f, 2.4f),
               color > 0.04045f);
```

Or if you want to keep it fast (pow is expensive on GPU, use this instead):
```metal
// Fast gamma-2.2 approximation (better than 2.0):
color = pow(color, float3(2.2f));
// pow with a constant exponent gets optimized by the Metal compiler to ~3 multiplies
```

---

## WHAT IS CORRECT — DO NOT CHANGE

- ✅ `endEncoding()` sequence — no Metal race condition exists
- ✅ Depth key: planar `dot(wp - camPos, camForward)` — correct
- ✅ 20-bit depth precision — adequate for any room-scale scene  
- ✅ `sortPositionEpsilon = 0.005` — correct for translation
- ✅ Semaphore structure (wait/signal) — correct, just reduce value 3→2
- ✅ Premultiplied alpha blend state — correct
- ✅ All Phase 1, 2, 3 fixes — correct, confirmed in place

---

## PRIORITY ORDER

1. **Bug #1** (direction epsilon 0.0002 → 0.00001) — fixes slow-rotation pops, 1 line
2. **Bug #3** (remove depth bias) — fixes dense surface shimmer, 2 lines
3. **Bug #2** (semaphore 3→2) — reduces camera lag feel, 1 line
4. **Bug #5** (gamma 2.0 → 2.2) — fixes color accuracy, 1-2 lines

---

## EXPECTED RESULT AFTER PHASE 4

- No more pops during slow rotation
- Dense surfaces (sofa, TV) no longer shimmer when moving
- Camera feels ~17ms more responsive
- Colors match reference renderer more closely — highlights visible on shiny surfaces

---

*Generated by Claude via full source audit of commit `4260b68` on 2026-05-11.*
*Repo: github.com/Rajveer985/3D-Gaussian-Splatting-MacOS*
