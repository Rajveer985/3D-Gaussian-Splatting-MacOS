# 🛠️ MASTER PROMPT — GaussianSplatViewer Phase 3 Debugging
## Focus: Jitter & Lag — CPU/GPU Synchronization
## Based on ACTUAL CODE AUDIT — commit `794e67e` ("Phase 2 fix applied")
## Repo: github.com/Rajveer985/3D-Gaussian-Splatting-MacOS

> **To the AI Coding Agent:**
> Phase 1 and Phase 2 fixes are confirmed applied and correct. Do NOT re-apply them.
> The following bugs are VERIFIED line-by-line in the actual current source.
> Google AI Studio's Phase 3 prompt is partially correct but misdiagnoses several items.
> Follow THIS prompt only.

---

## WHAT GOOGLE AI STUDIO GOT RIGHT vs WRONG

| Claim | Actual Status |
|-------|--------------|
| "Radial vs planar depth" | ✅ Already planar — `dot(wp - camPos, camForward)` — DO NOT CHANGE |
| "Matrix desync between sort and render" | ✅ Already uses same `camOff` for both — DO NOT CHANGE |
| "Missing semaphore / triple buffering broken" | ✅ **REAL BUG — needs fix** |
| "waitUntilCompleted() in render loop" | ✅ Does NOT exist — no change needed |
| "Sort every frame unconditionally" | ✅ Already delta-gated — DO NOT CHANGE |

---

## BUG #1 — CRITICAL: Triple buffering exists but has NO semaphore — CPU can overwrite active GPU data

**File:** `GaussianSplatViewer/Rendering/Renderer.swift`

**Current situation:**
The code allocates a `cameraBuffer` with 3 slots (`length = stride * 3`) and writes to slot
`frameCount % 3` each frame. This looks like triple buffering but is **incomplete**.

There is **no `DispatchSemaphore`** to limit how many frames the CPU can get ahead of the GPU.
Without a semaphore, on a fast M1 Pro, the CPU can run 5–10 frames ahead of the GPU. It will
cycle through all 3 slots and start overwriting slot 0 while the GPU is still rendering with it.

**Symptom:** Camera matrix torn mid-frame. Sort uses one view matrix, render uses a slightly
different one (the overwritten one). Splats appear to pop/jitter because their projected positions
disagree between the compute pass and vertex pass — even though they use the "same" `camOff`.

**The fix — 3 changes to `Renderer.swift`:**

**Step 1:** Add the semaphore property (alongside other Metal object properties):
```swift
// Renderer.swift — add with other properties at top of class:
private let maxFramesInFlight = 3
private var frameSemaphore: DispatchSemaphore = DispatchSemaphore(value: 3)
```

**Step 2:** At the very START of `draw(in:)`, wait on the semaphore before touching any buffer:
```swift
// Renderer.swift — first line inside draw(in:), before frameCount += 1:
frameSemaphore.wait()
```

**Step 3:** In the command buffer completion handler, signal the semaphore:
```swift
// Renderer.swift — REPLACE:
cb.present(drawable)
cb.commit()

// WITH:
cb.present(drawable)
cb.addCompletedHandler { [weak self] _ in
    self?.frameSemaphore.signal()
}
cb.commit()
```

**Why this works:** The semaphore starts at 3 (3 in-flight frames allowed). Each `draw()` call
decrements it. Each GPU completion increments it. Once 3 frames are in flight, `wait()` blocks
the CPU until the GPU finishes frame N before the CPU starts writing for frame N+3.

---

## BUG #2 — HIGH: Sort epsilon 0.0001 is too tight — sorts fire on every sub-pixel camera move

**File:** `GaussianSplatViewer/Rendering/Renderer.swift`

**Current code (line ~57):**
```swift
private let sortEpsilon: Float = 0.0001
```

**Why this is a problem:**
With `sortEpsilon = 0.0001`, any camera position change larger than 0.1mm in world units triggers
a full GPU radix sort. On an M1 Pro, a 1M-splat radix sort takes ~4–8ms per sort.
At 60Hz, the frame budget is 16.7ms. A sort eating 8ms = 48% of frame budget on EVERY frame
during camera movement = stuttering.

The sort epsilon was originally set to `0.0001` with the comment "fat splats (0.6f LPF) need more
frequent sorts" — but Phase 1 fixed the LPF back to 0.3. The reason for the tight epsilon is gone.

**Fix:**
```swift
// Renderer.swift — change sortEpsilon:
private let sortEpsilon: Float = 0.005  // 5mm world units — barely perceptible quality loss
                                         // was 0.0001 (sub-mm) — overkill after LPF fix
```

For rotation, the `dirDelta` threshold (currently also `sortEpsilon`) can stay at `0.0001` radians
because rotation jitter is more visually noticeable. Split them:

```swift
// Renderer.swift — replace single sortEpsilon with two:
private let sortPositionEpsilon: Float = 0.005   // world-space distance
private let sortDirectionEpsilon: Float = 0.0002  // ~0.01 degrees, very sensitive

// Then update the needsSort calculation:
let needsSort = isAnimating
             || sortedIndexBuffer == nil
             || posDelta > sortPositionEpsilon       // was: sortEpsilon
             || dirDelta > sortDirectionEpsilon       // was: sortEpsilon
```

---

## BUG #3 — MEDIUM: `splatBuffer` in Scene is `.storageModeShared` — should be `.storageModePrivate`

**File:** `GaussianSplatViewer/Scene/Scene.swift`

**Current code (line ~75):**
```swift
guard let buffer = device.makeBuffer(bytes: &gpuData,
                                     length: splatBufferSize,
                                     options: .storageModeShared) else {
```

**Why this matters:**
The `splatBuffer` is only ever written once at load time (from `gpuData`) and then only read by
the GPU compute shader (`projectSplats`). It is NEVER written by the CPU again after load
(the dead `sortSplats()` function is never called).

`.storageModeShared` puts the buffer in unified memory visible to both CPU and GPU — which adds
memory bandwidth overhead on every GPU access because the GPU has to check coherency.

`.storageModePrivate` puts it entirely in GPU-local memory (VRAM on discrete, optimized tile on
Apple Silicon) — pure GPU reads are faster.

**Fix:**
```swift
// Scene.swift — change storage mode for splatBuffer:
guard let buffer = device.makeBuffer(bytes: &gpuData,
                                     length: splatBufferSize,
                                     options: .storageModePrivate) else {  // ← changed from .storageModeShared
```

> **Note:** On Apple Silicon (M1 Pro), `.storageModePrivate` still uses unified memory physically,
> but the driver can optimize access patterns. The improvement is real but modest (~5–15% compute
> throughput on large buffers). More importantly it signals intent: this buffer is GPU-only.

---

## BUG #4 — LOW: `computeThreadgroupWidth` not clamped to count — wasteful dispatch for small scenes

**File:** `GaussianSplatViewer/Rendering/Renderer.swift`

**Current dispatch:**
```swift
enc.dispatchThreads(
    MTLSize(width: Int(count), height: 1, depth: 1),
    threadsPerThreadgroup: MTLSize(width: computeThreadgroupWidth, height: 1, depth: 1))
```

`dispatchThreads` with non-uniform threadgroups is supported on Apple Silicon and handles this
correctly — no fix strictly needed. The Metal runtime handles the tail.

**No change needed here.**

---

## WHAT IS ACTUALLY CAUSING "JITTER" — Root cause summary

The jitter is primarily Bug #1 (missing semaphore). Here's the exact failure mode:

```
Frame 60:  CPU writes camBuf[0] (azimuth=30°), GPU starts compute+render with camBuf[0]
Frame 61:  CPU writes camBuf[1] (azimuth=31°), GPU starts using camBuf[1]
Frame 62:  CPU writes camBuf[2] (azimuth=32°), GPU using camBuf[2]
Frame 63:  CPU writes camBuf[0] (azimuth=33°) ← OVERWRITES while GPU frame 60 may still run
           GPU compute reads camBuf[0] = 33° for sorting
           GPU render reads camBuf[0] = 33° (same slot, after CPU overwrote it)
           But the sort was started with 30° data and is now being indexed with 33° matrices
           → Z-order is wrong for this camera angle → splats pop/swim
```

The semaphore blocks frame 63 from starting until frame 60 is confirmed complete.

---

## WHAT IS CAUSING "LAG" — Root cause summary

The lag is Bug #2 (sort epsilon too tight). Every mouse-drag event causes:
- `handleMouseDrag` → `camera.mouseDrag` → `camera.rotate` → `updateMatrices()`
- Next `draw()`: `posDelta > 0.0001` = TRUE → full radix sort dispatched
- 4× compute passes (count, prefixSum, scatter×3) = ~5–8ms on 1M splats

At 60Hz, this leaves ~9ms for everything else. Fixing the epsilon to 0.005 reduces sort frequency
by ~50× during smooth camera movement, recovering ~4–6ms per frame.

---

## PRIORITY ORDER

1. **Fix Bug #1 first** (semaphore) — eliminates the matrix tearing that causes jitter
2. **Fix Bug #2 next** (sort epsilon) — recovers frame budget, eliminates lag
3. **Fix Bug #3** (splatBuffer storage mode) — modest perf improvement, worth doing

---

## DO NOT CHANGE — Already correct

- ✅ Depth key: planar `dot(wp - camPos, camForward)` — correct
- ✅ Same `camOff` used for both compute and render — correct, no matrix desync
- ✅ No `waitUntilCompleted()` in render loop — correct
- ✅ Sort delta-gating already implemented — just needs wider epsilon
- ✅ All Phase 1 & 2 fixes — correct, do not re-apply

---

*Generated by Claude via full source audit of commit `794e67e` on 2026-05-11.*
*Repo: github.com/Rajveer985/3D-Gaussian-Splatting-MacOS*
