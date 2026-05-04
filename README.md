# GaussianSplatViewer

A real-time, photorealistic 3D Gaussian Splatting viewer for macOS, built with Metal and Swift.

![Indoor Scene](docs/indoor.png)
![Outdoor Scene](docs/outdoor.png)

## Features

- **Real-time rendering** at 30+ FPS on Apple Silicon (M1/M2/M3)
- **Photorealistic quality** matching SuperSplat and Luma AI standards
- **PLY file support** — load any 3DGS-trained `.ply` file
- **Full spherical harmonics** — degree 0–3 view-dependent color
- **GPU radix sort** — back-to-front depth sorting every frame
- **Correct alpha blending** — standard (non-premultiplied) blending matching the reference 3DGS implementation
- **sRGB color pipeline** — gamma-correct rendering via Metal's sRGB framebuffer
- **Scene transform tools** — translate, rotate, scale the scene independently of the camera
- **Adaptive culling** — auto-computed per-scene scale threshold removes floaters without affecting geometry
- **Stable sort** — per-splat hash tie-breaker eliminates sky dome / co-planar splat jitter

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon or Intel Mac with Metal support
- Xcode 15 or later

## Getting Started

1. Clone the repository
2. Open `GaussianSplatViewer.xcodeproj` in Xcode
3. Select the `GaussianSplatViewer` scheme
4. Build and run (`⌘R`)
5. Click **Open PLY File…** and select a `.ply` file from a 3DGS training run

## Getting PLY Files

You can obtain `.ply` files from:

- **[Nerfstudio](https://docs.nerf.studio/)** — train your own splats with `ns-train splatfacto`
- **[3DGS original repo](https://github.com/graphdeco-inria/gaussian-splatting)** — reference implementation
- **[Luma AI](https://lumalabs.ai)** — capture and export from the iOS app
- **[Polycam](https://poly.cam)** — capture and export Gaussian splats
- The [original 3DGS paper datasets](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/)

## Controls

| Action | Control |
|--------|---------|
| Orbit camera | Left-click drag |
| Pan camera | Right-click drag |
| Zoom | Scroll wheel |
| Translate scene | Select **Translate** tool, then drag |
| Rotate scene | Select **Rotate** tool, then drag |
| Scale scene | Select **Scale** tool, then drag |
| Reset view | Click **Reset** |
| Open properties | Click **≡** |

## Architecture

```
GaussianSplatViewer/
├── Rendering/
│   ├── Renderer.swift          # MTKViewDelegate, GPU pipeline orchestration
│   └── Camera.swift            # Orbital camera with pan/zoom/orbit
├── Scene/
│   ├── Scene.swift             # GPU buffer management, scene state
│   └── PLYLoader.swift         # High-performance binary PLY parser
├── Shaders/
│   └── GaussianSplat.metal     # All GPU kernels and shaders
├── Math/
│   └── MathTypes.swift         # SIMD types, GPU structs, settings
└── UI/
    └── ViewportView.swift      # NSView integration, input handling
```

### Rendering Pipeline

Each frame executes the following GPU pipeline:

1. **Project** (`projectSplats` kernel) — transforms each Gaussian from world space to screen space, computes the 2D covariance via the EWA splatting Jacobian, evaluates spherical harmonics for view-dependent color, and writes a 24-bit depth sort key
2. **Init indices** (`initSortIndices` kernel) — initialises the sort index buffer to `[0, 1, 2, …, N-1]`
3. **Radix sort** (3 passes of `radixCount` + CPU prefix sum + `radixScatter`) — sorts splats back-to-front by depth key
4. **Render** (`splatVertex` + `splatFragment`) — draws each splat as a screen-aligned quad with Gaussian alpha falloff

### Key Technical Decisions

**Jacobian clamping** — the affine approximation Jacobian is stabilised by clamping the view-space `x/z` and `y/z` ratios to `±1.3 × tanHalfFov` before computing the Jacobian (matching the reference CUDA implementation and MetalSplatter). This prevents the 2D covariance from exploding when the camera is close to a splat.

**EWA low-pass filter** — `cov2D += diag(0.3, 0.3)` prevents sub-pixel aliasing on tiny/distant splats, matching the original 3DGS paper and SuperSplat.

**Depth sort key** — uses `dot(worldPos - cameraPos, cameraForward)` (camera-forward projection) rather than view-space Z. This is invariant to camera roll and matches the PlayCanvas/SuperSplat sort metric. A 4-bit per-splat Knuth hash is embedded in the low bits to break ties deterministically, eliminating sky dome jitter.

**sRGB pipeline** — SH evaluation produces sRGB-space colors matching the training pipeline. The Metal framebuffer is `.bgra8Unorm_srgb` which applies gamma automatically, so colors are linearised (`color * color`, gamma ≈ 2.0) before writing to the vertex buffer.

**Adaptive scale threshold** — at load time, 10k splats are sampled to estimate the p99 scale value. The cull threshold is set to `p99 × 3`, removing the top ~1% of giant background/floater splats while preserving all scene geometry. Works for both indoor and outdoor scenes.

## References

- [3D Gaussian Splatting for Real-Time Radiance Field Rendering](https://arxiv.org/abs/2308.04079) — Kerbl et al., SIGGRAPH 2023
- [Mip-Splatting: Alias-Free 3D Gaussian Splatting](https://arxiv.org/abs/2311.16493) — Yu et al., CVPR 2024
- [StopThePop: Sorted Gaussian Splatting](https://arxiv.org/abs/2402.00525) — Radl et al., 2024
- [MetalSplatter](https://github.com/scier/MetalSplatter) — reference Metal implementation by Sean Cier
- [PlayCanvas SuperSplat](https://github.com/playcanvas/supersplat) — reference WebGL implementation

## License

MIT License — see [LICENSE](LICENSE) for details.
