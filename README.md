# 3D Gaussian Splat Viewer — macOS

A high-performance, native macOS viewer for 3D Gaussian Splatting (3DGS) scenes, built with Swift and Metal. Supports real-time rendering of `.ply` files with a full keyframe animation system for cinematic camera paths.

![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-blue)
![Language](https://img.shields.io/badge/language-Swift%205.7-orange)
![GPU](https://img.shields.io/badge/GPU-Metal-silver)

---

## Features

### Rendering
- **Metal-accelerated** Gaussian splat rasterization with full Spherical Harmonics (degrees 0–3)
- **4-pass 32-bit GPU Radix sort** for correct back-to-front alpha compositing
- **Premultiplied alpha blending** for smooth, artifact-free transparency
- **2D covariance low-pass filter** (0.3px minimum radius) for anti-aliased splat edges
- **Sort-skip optimization** — only re-sorts when the camera moves, preserving temporal stability on still frames
- **View frustum culling** and scale-threshold culling with soft fade
- **Adaptive farClip** — automatically scales to scene depth range
- **Auto scale threshold** — samples p99 of splat scales at load time to cull floaters

### Camera Controls
- **Left drag** — orbit (azimuth / elevation)
- **Right drag / middle drag** — pan
- **Scroll** — zoom
- **Scene transform** — Move / Rotate / Scale buttons for non-destructive scene offset

### Keyframe Animation System
Full professional-grade camera animation, comparable to DaVinci Resolve / After Effects workflow:

- **8 animatable properties**: Azimuth, Elevation, Distance, Target X/Y/Z, FOV, Roll
- **6 interpolation modes**: Linear, Bezier (with tangent handles), Ease In, Ease Out, Ease In/Out, Constant
- **Timeline UI** with per-property tracks, draggable keyframe diamonds, scrubber
- **Keyframe inspector** — click any diamond to see value, frame, and change interpolation mode
- **Graph editor** — visual bezier curve editing with draggable in/out tangent handles
- **Playback engine** — real-time playback at 24 / 30 / 60 FPS with loop support
- **Save / Load** animations to `.gsanim` JSON files
- **Sort-every-frame** during animation playback for correct depth ordering

### Splat Properties Panel
- Splat Scale, Opacity, Sharpness, Saturation
- Near / Far clip planes
- Max Splat Scale threshold
- Camera Distance slider
- Min Alpha Cutoff
- Spherical Harmonics degree override (Auto / 0 / 1 / 2 / 3)
- Covariance regularization
- Background color picker with presets

---

## Requirements

- macOS 12.0 or later
- Apple Silicon or Intel Mac with Metal support
- Xcode 14 or later

---

## Getting Started

1. Clone the repo:
   ```bash
   git clone https://github.com/Rajveer985/3D-Gaussian-Splatting-MacOS.git
   ```

2. Open the Xcode project:
   ```bash
   open GaussianSplatViewer/GaussianSplatViewer.xcodeproj
   ```

3. Build and run with **⌘R**

4. Click **Open PLY File…** and select a `.ply` file from any 3DGS training output (e.g. from [Hugging Face 3DGS datasets](https://huggingface.co/datasets))

---

## Animating a Camera Path

1. Open a PLY file
2. Click the **🎬 Timeline** button in the toolbar to show the timeline panel
3. Position the camera at your starting viewpoint
4. Click **Set All** to capture all 8 camera properties as keyframes at frame 0
5. Scrub to frame 120, move the camera to a new position, click **Set All** again
6. Press **▶ Play** to preview the animation
7. Click individual ◆ buttons on each property track to set keyframes for specific properties only
8. Click a keyframe diamond to select it — the inspector bar lets you change interpolation mode
9. Use **Save Anim** / **Load Anim** to persist your animation to a `.gsanim` file

---

## File Format Support

| Format | Support |
|--------|---------|
| `.ply` (binary little-endian) | ✅ Full |
| `.ply` (binary big-endian) | ✅ Full |
| `.ply` (ASCII) | ✅ Full |
| `.gsanim` (animation) | ✅ Read/Write |

Standard 3DGS PLY files from tools like [gaussian-splatting](https://github.com/graphdeco-inria/gaussian-splatting), [Nerfstudio](https://github.com/nerfstudio-project/nerfstudio), and [Luma AI](https://lumalabs.ai) are supported.

---

## Architecture

```
GaussianSplatViewer/
├── Rendering/
│   ├── Renderer.swift       — Metal render loop, radix sort, draw calls
│   └── Camera.swift         — Orbital camera with roll support
├── Shaders/
│   └── GaussianSplat.metal  — Project kernel, radix sort kernels, vertex/fragment shaders
├── Scene/
│   ├── Scene.swift          — GPU buffer management
│   └── PLYLoader.swift      — High-performance binary PLY parser
├── Math/
│   └── MathTypes.swift      — SIMD types, GPU structs, matrix math
├── Animation/               — Full keyframe animation system (11 files)
│   ├── AnimationSystem.swift
│   ├── KeyframeStore.swift
│   ├── InterpolationEngine.swift
│   ├── PlaybackEngine.swift
│   ├── Timeline.swift
│   └── ...
└── UI/
    ├── ContentView.swift    — Main window, toolbar, properties panel
    ├── ViewportView.swift   — MTKView wrapper, ViewModel
    └── Timeline/            — Timeline UI (8 files)
        ├── TimelineView.swift
        ├── PlaybackControlsBar.swift
        ├── TimelineTracksArea.swift
        ├── GraphEditorView.swift
        └── ...
```

---

## License

MIT License — see [LICENSE](LICENSE) for details.
