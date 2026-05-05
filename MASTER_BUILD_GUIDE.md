# GaussianSplatViewer — Master Build Guide

This document is the **Ultimate Technical Blueprint** for rebuilding the real-time 3D Gaussian Splatting (3DGS) viewer for macOS from scratch. If you are an AI agent or a developer, you can use this exact guide to recreate the architecture, mathematical models, rendering techniques, and shaders.

## 1. Core Architecture & Tech Stack
- **Language**: Swift 5.7+
- **Graphics API**: Apple Metal
- **UI Framework**: SwiftUI + AppKit (`NSViewRepresentable` wrapping `MTKView`)
- **Build System**: Swift Package Manager (`Package.swift`)
- **Target**: macOS 12+ (Apple Silicon optimized)

---

## 2. Data Structures & Memory Layout

### CPU-Side Splat (`GaussianSplat` in Swift)
Each splat parsed from the `.ply` file holds:
- `position`: `simd_float3`
- `scale`: `simd_float3` (loaded via `exp(scale)`)
- `rotation`: `simd_float4` (quaternion, loaded and normalized)
- `color`: `simd_float3` (base RGB, loaded from spherical harmonics `DC` term)
- `opacity`: `Float` (loaded via `1.0 / (1.0 + exp(-opacity))` — Sigmoid)
- `shCoefficients`: `[Float]` (48 values for degree 0-3 Spherical Harmonics)

### GPU-Side Memory (`GaussianGPUData`)
Sent to the compute shader buffer. Padding matches Metal's 16-byte alignment rules:
- `position`: `float4` (w=0)
- `scale`: `float4` (w=0)
- `rotation`: `float4` (quaternion)
- `opacity`: `float`
- `shDegree`: `uint32`
- Padding: `uint2`
- SH Coefficients: 12 `float4` vectors holding the SH terms for RGB (4 for R, 4 for G, 4 for B).

### Vertex Output (`SplatVertex`)
Output from the projection compute shader, consumed by the vertex/fragment render pass:
- `screenPos`: `float2` (Center of the splat in pixel space)
- `conic_xy`: `float2` (Inverse 2D covariance components A and B)
- `conic_z`: `float` (Inverse 2D covariance component C)
- `opacity`: `float`
- `radius`: `float` (Max axis length for culling)
- `color`: `float4` (Evaluated SH view-dependent color)
- `majorAxis`, `minorAxis`: `float2` (Half-extents of the oriented bounding ellipse)

---

## 3. Mathematical Formulas & Pipeline

The pipeline consists of three main stages per frame:
1. **Depth Sorting** (CPU/GPU)
2. **Projection** (Compute Shader: `projectSplats`)
3. **Rasterization** (Vertex/Fragment Shaders: `splatVertex`, `splatFragment`)

### Step 3.1: Depth Sorting
To ensure correct alpha blending, splats are sorted back-to-front.
**Formula:** `depth = dot(splat.position - cameraPosition, cameraForward)`
*Why:* Using the camera-forward projection rather than view-space Z ensures the sort order is invariant to camera roll and prevents jitter when the camera rotates.

### Step 3.2: 3D to 2D Projection (Compute Shader)

### Step 3.2: 3D to 2D Projection (Compute Shader) & Built-in Maths

This section outlines every exact mathematical formula applied in the GPU Compute Shader (`projectSplats`).

#### 1. Frustum Culling
First, cull splats that are behind the near plane:
If `viewSpace.z >= -0.2f`, the splat is culled (`opacity = 0`).
Clip-space position `cp = viewProjMatrix * float4(worldPos, 1)`.
Frustum cull threshold: `clip = 1.2 * cp.w`. 
If `cp.x, cp.y, cp.z` fall outside `[-clip, clip]`, it is culled.

#### 2. Quaternion to Rotation Matrix (\(R\))
The quaternion \(q = [x, y, z, w]\) is normalized, then converted into a 3x3 rotation matrix \(R\):
\[ R = \begin{bmatrix} 
1 - 2(y^2 + z^2) & 2(xy - zw) & 2(xz + yw) \\
2(xy + zw) & 1 - 2(x^2 + z^2) & 2(yz - xw) \\
2(xz - yw) & 2(yz + xw) & 1 - 2(x^2 + y^2)
\end{bmatrix} \]

#### 3. 3D Covariance Matrix (\(\Sigma_{3D}\))
Scale matrix \(S = \text{diag}(scale.x, scale.y, scale.z)\).
Let \(M_m\) be the upper-left 3x3 of the world `modelMatrix`.
Combined transform \(M = M_m \cdot R \cdot S\).
The 3D covariance is computed as: \(\Sigma_{3D} = M \cdot M^T\)

#### 4. EWA Splatting Jacobian Matrix (\(J\))
Extract focal lengths from the Metal projection matrix (column-major):
\(f_x = \text{projMatrix}[0][0] \times \frac{\text{screenWidth}}{2}\)
\(f_y = \text{projMatrix}[1][1] \times \frac{\text{screenHeight}}{2}\)

The Affine Approximation Jacobian (\(J\)) of the perspective projection at view-space position \(v_p = [x, y, z]\) is exactly:
\[ J = \begin{bmatrix} 
f_x / z & 0 & -(f_x \cdot x) / z^2 \\ 
0 & -f_y / z & (f_y \cdot y) / z^2 \\ 
0 & 0 & 0 
\end{bmatrix} \]
*(Note: The Y derivative is negated \((f_y \cdot y)/z^2\) because Metal/screen coordinates are Y-down).*

#### 5. 2D Covariance (\(\Sigma_{2D}\))
Let \(W\) be the 3x3 rotational part of the `viewMatrix`.
Transformation matrix \(T = W^T \cdot J\)  (or in Math notation: \(T = \text{transpose}(W) \times J\)).
The 2D screen-space covariance is projected as:
\(\Sigma_{2D} = T^T \cdot \Sigma_{3D} \cdot T\)

We extract the upper-left 2x2 components and add a low-pass filter (0.3) to prevent sub-pixel aliasing:
\(a = \Sigma_{2D}[0][0] + 0.3\)
\(b = \Sigma_{2D}[0][1]\)
\(c = \Sigma_{2D}[1][1] + 0.3\)

#### 6. Eigenvalue Decomposition for Oriented Bounding Quads
To draw tight bounding geometry instead of oversized quads, we extract the eigenvectors/eigenvalues from the 2x2 \(\Sigma_{2D}\):
- **Midpoint:** \(m = (a + c) / 2\)
- **Radius (determinant factor):** \(r = \sqrt{((a - c) / 2)^2 + b^2}\)
- **Eigenvalues:** \(\lambda_1 = m + r\), \(\lambda_2 = m - r\)
- **Eigenvector of \(\lambda_1\):** \(v_1 = \text{normalize}(\begin{bmatrix} b \\ \lambda_1 - a \end{bmatrix})\)
- **Axes:** 
  - Major Axis: \(E_{major} = \min(\sqrt{2\lambda_1}, 1024.0) \times v_1\)
  - Minor Axis: \(E_{minor} = \min(\sqrt{2\lambda_2}, 1024.0) \times \begin{bmatrix} v_1.y \\ -v_1.x \end{bmatrix}\)

#### 7. Inverse Covariance (Conic)
For the fragment shader evaluation, we pass the inverse of the 2x2 covariance (the "conic"):
\(det = a \cdot c - b^2\)
Inverse components:
\(conic_x = c / det\)
\(conic_y = -b / det\)
\(conic_z = a / det\)

### Step 3.3: Spherical Harmonics (SH) Evaluation
View-dependent color is evaluated using the view direction vector \(dir = normalize(worldPos - camPos)\).
We use full degree 0–3 SH constants (e.g., `SH_C0`, `SH_C1`, `SH_C2_x`, `SH_C3_x`) multiplied by the polynomial basis functions of \(x, y, z\) and the splat's `shCoefficients`.
Result is clamped `saturate(color + 0.5f)`.

### Step 3.4: Rasterization (Vertex & Fragment Shader)

#### Vertex Shader (`splatVertex`)
Expands a single vertex into a quad instance. The 4 corners of the quad are defined by combinations of the major and minor axes:
`pixelOffset = cx * majorAxis + cy * minorAxis` (where cx, cy are \(\pm 1\)).
The `pixelOffset` is passed to the fragment shader as `uv`.

#### Fragment Shader (`splatFragment`)
Evaluates the Mahalanobis distance using the inverse 2D covariance conic (\(A, B, C\)):
`power = -0.5 * (A * dx * dx + 2 * B * dx * dy + C * dy * dy)`
If `power > 0`, `discard_fragment()`.
`alpha = min(0.99f, opacity * exp(power))`
Color output: `float4(color * alpha, alpha)`

---

## 4. Key Techniques & Metal Integrations

1. **Blending Setup:**
   Metal Render Pipeline is set up for standard (non-premultiplied) alpha blending to match 3DGS reference:
   - Source RGB: `one`, Dest RGB: `oneMinusSourceAlpha`
   - Source Alpha: `one`, Dest Alpha: `oneMinusSourceAlpha`
2. **sRGB Pipeline:**
   Color attachments use `.bgra8Unorm_srgb`. The SH outputs linear colors. Since the target is sRGB, Metal automatically applies gamma correction upon writing.
3. **PLY Parsing:**
   The `PLYLoader` parses ASCII and Binary (Little/Big Endian) formats. It detects properties like `f_dc_0` (DC term) and `f_rest_x` (higher degrees) to rebuild the 48-float SH array. Scaling uses `exp()` and opacity uses `1 / (1 + exp(-x))` (Sigmoid).
4. **Instanced Rendering:**
   `drawIndexedPrimitives` draws 6 indices per instance (`count` = splat count). `splatVertex` uses `instance_id` to index the compute shader's output buffer `SplatVertex`.
5. **Camera Mechanics:**
   Orbital camera implementation. `fovY`, `aspect`, `near`, `far` converted into Metal projection matrix. Mouse dragging modifies azimuth, elevation, and target position.

---

## 5. Master Prompt for Agents

**Objective:** "Build a real-time macOS Apple Metal 3D Gaussian Splatting viewer using Swift."
**Instructions:**
1. Setup an `MTKView` and an `NSViewRepresentable`. Use `.bgra8Unorm_srgb` color format.
2. Implement `PLYLoader.swift` to parse binary PLY files. Extract `x,y,z`, quaternion rotation, sigmoid-encoded opacity, exp-encoded scale, and 48 SH coefficients.
3. Create CPU Struct `GaussianSplat` and GPU Struct `GaussianGPUData`. Ensure exact 16-byte alignments for Metal.
4. Implement a CPU-based back-to-front depth sort (`dot(pos - camPos, camForward)`) running on every frame or every N frames. Update the GPU buffer using `memcpy`.
5. Write a Compute Shader (`projectSplats`) that projects 3D covariance to 2D covariance using EWA Splatting (Affine Jacobian of perspective projection). Add `0.3` low-pass filter to diagonal. Output oriented ellipse axes (major/minor) via Eigen decomposition. Evaluate Spherical Harmonics degree 0-3 based on view direction.
6. Write a Vertex Shader (`splatVertex`) that takes the compute output and expands it into an instanced quad using the major/minor axes for tight bounding boxes.
7. Write a Fragment Shader (`splatFragment`) that evaluates the Gaussian exponential `-0.5 * (A*dx^2 + 2*B*dx*dy + C*dy^2)`. Discard fragments outside the ellipse. Apply alpha blending.
8. Wire it all together in a `Renderer: MTKViewDelegate` class mapping CPU camera controls to uniform buffers.
