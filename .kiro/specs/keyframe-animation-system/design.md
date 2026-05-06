# Design Document: Keyframe Animation System

## Overview

The Keyframe Animation System adds professional-grade camera animation capabilities to the macOS Gaussian Splat Viewer. The system enables users to animate eight scalar camera properties (azimuth, elevation, distance, targetX, targetY, targetZ, fovDegrees, roll) using industry-standard keyframe workflows with multiple interpolation modes including Linear, Bezier with tangent handles, Ease In/Out, and Constant/Step.

The architecture follows a clean separation of concerns:
- **AnimationSystem**: Top-level coordinator owning all animation state
- **PlaybackEngine**: Real-time frame advancement using CADisplayLink
- **InterpolationEngine**: Mathematically correct curve evaluation
- **TimelineView**: SwiftUI-based timeline UI with per-property tracks
- **GraphEditorView**: Bezier handle editing interface
- **PersistenceManager**: JSON serialization/deserialization

The system integrates with the existing `Camera` and `Renderer` classes with minimal modifications, preserving the orbital camera model and existing mouse/keyboard controls.

### Architecture Diagram

```mermaid
graph TB
    subgraph "UI Layer (SwiftUI)"
        TV[TimelineView]
        GE[GraphEditorView]
        PC[PlaybackControls]
    end
    
    subgraph "Animation Core"
        AS[AnimationSystem]
        PE[PlaybackEngine]
        IE[InterpolationEngine]
        KS[KeyframeStore]
        TL[Timeline]
    end
    
    subgraph "Rendering Layer"
        R[Renderer]
        C[Camera]
    end
    
    subgraph "Persistence"
        PM[PersistenceManager]
        JSON[(JSON .gsanim)]
    end
    
    TV --> AS
    GE --> AS
    PC --> PE
    AS --> PE
    AS --> IE
    AS --> KS
    AS --> TL
    PE --> IE
    IE --> KS
    PE --> C
    AS --> C
    R --> C
    AS --> PM
    PM --> JSON
    
    style AS fill:#4a9eff
    style PE fill:#ff9a4a
    style IE fill:#4aff9a
    style TV fill:#ff4a9a

---

## Architecture

### Component Responsibilities

| Component | Responsibility |
|---|---|
| `AnimationSystem` | Top-level coordinator; owns all sub-components; exposes the public API used by UI and Renderer |
| `KeyframeStore` | Stores and manages sorted keyframe arrays per `AnimatableProperty` |
| `Timeline` | Holds startFrame, endFrame, FPS; validates configuration changes |
| `InterpolationEngine` | Stateless; evaluates interpolated scalar values given a keyframe sequence and a frame number |
| `PlaybackEngine` | Drives real-time playback using `CADisplayLink`; advances current frame; calls back into `AnimationSystem` |
| `TimelineView` | SwiftUI view rendering the ruler, per-property tracks, scrubber, and playback controls |
| `GraphEditorView` | SwiftUI view rendering the value-over-time curve and Bezier handle control points |
| `PersistenceManager` | Encodes/decodes `AnimationDocument` to/from JSON `.gsanim` files |

### Data Flow

```
User drags scrubber
    → TimelineView sets AnimationSystem.currentFrame
    → AnimationSystem calls InterpolationEngine.evaluate(frame, keyframes)
    → InterpolationEngine returns CameraState
    → AnimationSystem calls CameraState.apply(to: camera)
    → Camera.updateMatrices()
    → Renderer.draw() reads updated camera matrices

User presses Play
    → PlaybackEngine starts CADisplayLink
    → Each display tick: PlaybackEngine checks elapsed time
    → If elapsed >= 1/fps: advance currentFrame
    → AnimationSystem evaluates CameraState and applies to Camera
    → Renderer.draw() fires on next MTKView refresh
```

### Integration with Existing Code

**Camera.swift** — No structural changes required. The animation system writes directly to the existing public properties (`azimuth`, `elevation`, `distance`, `target`, `fovDegrees`) and calls `updateMatrices()`. A `roll` property will be added to `Camera` (currently absent) to support the roll keyframe channel.

**Renderer.swift** — One addition: a weak reference to `AnimationSystem` is injected after construction. During `draw(in:)`, if the animation system is in playback or scrub mode, mouse input is suppressed. No changes to the Metal pipeline.

**ContentView.swift** — `TimelineView` is added below the viewport as a collapsible panel. `ViewModel` gains an `animationSystem` property.

---

## Components and Interfaces

### AnimatableProperty

```swift
/// The eight scalar camera properties that can be keyframed.
enum AnimatableProperty: String, CaseIterable, Codable {
    case azimuth     = "azimuth"
    case elevation   = "elevation"
    case distance    = "distance"
    case targetX     = "targetX"
    case targetY     = "targetY"
    case targetZ     = "targetZ"
    case fovDegrees  = "fovDegrees"
    case roll        = "roll"
    
    /// Human-readable display name for the timeline track label.
    var displayName: String { ... }
    
    /// Reads the current value of this property from a Camera instance.
    func currentValue(from camera: Camera) -> Float { ... }
    
    /// Writes a value for this property to a Camera instance (does NOT call updateMatrices).
    func apply(_ value: Float, to camera: Camera) { ... }
}
```

### InterpolationMode

```swift
/// The curve type used to interpolate between two consecutive keyframes.
enum InterpolationMode: String, CaseIterable, Codable {
    case linear
    case bezier
    case easeIn
    case easeOut
    case easeInOut
    case constant
}
```

### BezierHandle

```swift
/// Tangent handles for a cubic Hermite spline keyframe.
/// Coordinates are in (frame, value) space — i.e., time is measured in frames.
struct BezierHandle: Codable, Equatable {
    /// Tangent arriving at this keyframe (from the left).
    var inTangent:  SIMD2<Float>   // (Δframe, Δvalue)
    /// Tangent leaving this keyframe (to the right).
    var outTangent: SIMD2<Float>   // (Δframe, Δvalue)
    
    /// Auto-tangent: smooth Catmull-Rom-style tangent computed from neighbors.
    static func autoTangent(prev: Keyframe?, current: Keyframe, next: Keyframe?) -> BezierHandle { ... }
}
```

### Keyframe

```swift
/// A single time-stamped value for one AnimatableProperty.
struct Keyframe: Codable, Equatable, Identifiable {
    let id: UUID
    var frame:             Int
    var value:             Float
    var interpolationMode: InterpolationMode
    var bezierHandle:      BezierHandle?   // non-nil only when mode == .bezier
    
    init(frame: Int, value: Float,
         interpolationMode: InterpolationMode = .linear,
         bezierHandle: BezierHandle? = nil)
}
```

### KeyframeStore

```swift
/// Manages sorted keyframe arrays for all AnimatableProperties.
/// All mutations maintain ascending frame order.
final class KeyframeStore: ObservableObject {
    /// Published so TimelineView can react to changes.
    @Published private(set) var keyframes: [AnimatableProperty: [Keyframe]] = [:]
    
    // MARK: - Mutations
    
    /// Inserts or replaces a keyframe for the given property.
    /// Maintains ascending frame order. Replaces if a keyframe at the same frame already exists.
    func set(_ keyframe: Keyframe, for property: AnimatableProperty)
    
    /// Removes the keyframe at the given frame for the given property.
    /// No-op if no keyframe exists at that frame.
    func delete(frame: Int, for property: AnimatableProperty)
    
    /// Removes all keyframes for the given property.
    func deleteAll(for property: AnimatableProperty)
    
    /// Removes all keyframes across all properties at the given frame.
    func deleteAll(at frame: Int)
    
    /// Removes all keyframes for all properties.
    func clearAll()
    
    /// Moves a keyframe from one frame to another, maintaining sorted order.
    func move(keyframeID: UUID, for property: AnimatableProperty, toFrame newFrame: Int)
    
    // MARK: - Queries
    
    /// Returns the sorted keyframe array for the given property (empty if none).
    func keyframes(for property: AnimatableProperty) -> [Keyframe]
    
    /// Returns true if a keyframe exists at the given frame for the given property.
    func hasKeyframe(at frame: Int, for property: AnimatableProperty) -> Bool
    
    /// Returns the keyframe at the given frame for the given property, or nil.
    func keyframe(at frame: Int, for property: AnimatableProperty) -> Keyframe?
}
```

### Timeline

```swift
/// Holds timeline configuration: frame range and FPS.
final class Timeline: ObservableObject {
    @Published private(set) var startFrame: Int  = 0
    @Published private(set) var endFrame:   Int  = 240
    @Published private(set) var fps:        Int  = 24
    
    /// Valid FPS values.
    static let validFPS: Set<Int> = [24, 30, 60]
    
    /// Maximum allowed frame count.
    static let maxFrames: Int = 18_000
    
    /// Total duration in seconds.
    var durationSeconds: Double { Double(endFrame - startFrame) / Double(fps) }
    
    /// Total frame count.
    var frameCount: Int { endFrame - startFrame }
    
    /// Attempts to set the start frame. Rejects if startFrame >= endFrame.
    /// Returns true on success.
    @discardableResult
    func setStartFrame(_ frame: Int) -> Bool
    
    /// Attempts to set the end frame. Rejects if endFrame <= startFrame or > maxFrames.
    /// Returns true on success.
    @discardableResult
    func setEndFrame(_ frame: Int) -> Bool
    
    /// Attempts to set FPS. Rejects if not in validFPS. Returns true on success.
    @discardableResult
    func setFPS(_ fps: Int) -> Bool
    
    /// Clamps a frame number to [startFrame, endFrame].
    func clamp(_ frame: Int) -> Int { max(startFrame, min(endFrame, frame)) }
    
    /// Converts a frame number to a time string in MM:SS:FF format.
    func timeString(for frame: Int) -> String { ... }
}
```

### CameraState

```swift
/// A snapshot of all eight AnimatableProperties at a given frame.
struct CameraState: Equatable {
    var azimuth:    Float
    var elevation:  Float
    var distance:   Float
    var targetX:    Float
    var targetY:    Float
    var targetZ:    Float
    var fovDegrees: Float
    var roll:       Float
    
    /// Applies this state to the given Camera and calls updateMatrices().
    func apply(to camera: Camera) {
        camera.azimuth    = azimuth
        camera.elevation  = elevation
        camera.distance   = distance
        camera.target     = float3(targetX, targetY, targetZ)
        camera.fovDegrees = fovDegrees
        camera.roll       = roll
        camera.updateMatrices()
    }
    
    /// Reads the current state from a Camera.
    static func capture(from camera: Camera) -> CameraState { ... }
    
    /// Returns the value for the given AnimatableProperty.
    func value(for property: AnimatableProperty) -> Float { ... }
    
    /// Returns a new CameraState with the given property set to the given value.
    func with(_ property: AnimatableProperty, value: Float) -> CameraState { ... }
}
```

### InterpolationEngine

```swift
/// Stateless engine that evaluates interpolated scalar values.
/// All methods are pure functions with no side effects.
enum InterpolationEngine {
    
    /// Evaluates the interpolated value for a property at the given frame.
    /// - Parameters:
    ///   - frame: The frame to evaluate (may be fractional for sub-frame precision).
    ///   - keyframes: Sorted ascending by frame. Must not be empty.
    /// - Returns: The interpolated scalar value.
    static func evaluate(at frame: Double, keyframes: [Keyframe]) -> Float
    
    /// Evaluates a full CameraState at the given frame across all properties.
    static func evaluate(at frame: Double, store: KeyframeStore) -> CameraState
    
    // MARK: - Segment evaluators (internal, exposed for testing)
    
    /// Linear interpolation between two values.
    static func linear(t: Float, v0: Float, v1: Float) -> Float
    
    /// Constant/step: holds v0 until t reaches 1.0.
    static func constant(t: Float, v0: Float, v1: Float) -> Float
    
    /// Cubic ease-in: slow start, fast end.
    static func easeIn(t: Float, v0: Float, v1: Float) -> Float
    
    /// Cubic ease-out: fast start, slow end.
    static func easeOut(t: Float, v0: Float, v1: Float) -> Float
    
    /// Cubic ease-in-out: slow start, slow end.
    static func easeInOut(t: Float, v0: Float, v1: Float) -> Float
    
    /// Cubic Hermite spline using tangent vectors from BezierHandles.
    static func cubicHermite(t: Float, v0: Float, v1: Float,
                              m0: Float, m1: Float) -> Float
    
    // MARK: - Normalized time
    
    /// Computes the normalized t ∈ [0, 1] for a frame within a segment.
    static func normalizedTime(frame: Double, startFrame: Int, endFrame: Int) -> Float
}
```

**Interpolation formulas:**

- **Linear**: `v0 + t * (v1 - v0)`
- **Constant**: `t < 1.0 ? v0 : v1`
- **Ease In**: `v0 + (3t² - 2t³) * (v1 - v0)` — cubic polynomial with zero derivative at t=0
- **Ease Out**: `v0 + (3t² - 2t³) * (v1 - v0)` evaluated with `t' = 1 - t` then mirrored — zero derivative at t=1
- **Ease In/Out**: `v0 + (3t² - 2t³) * (v1 - v0)` — smoothstep, zero derivatives at both ends
- **Bezier (Cubic Hermite)**: `h00(t)*v0 + h10(t)*m0 + h01(t)*v1 + h11(t)*m1` where h00..h11 are the standard Hermite basis polynomials and m0/m1 are the tangent magnitudes extracted from the BezierHandles

### PlaybackEngine

```swift
/// Drives real-time animation playback using CADisplayLink.
final class PlaybackEngine: ObservableObject {
    
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentFrame: Int = 0
    
    var loopEnabled: Bool = false
    
    weak var animationSystem: AnimationSystem?
    
    // MARK: - Transport
    
    func play()
    func pause()
    func stop()   // stops and resets to startFrame
    
    // MARK: - Scrubbing
    
    /// Moves to the given frame without starting playback.
    func scrub(to frame: Int)
    
    // MARK: - Internal
    
    private var displayLink: CVDisplayLink?
    private var lastFrameTime: Double = 0   // CACurrentMediaTime at last frame advance
    
    /// Called by CVDisplayLink callback on each display refresh.
    private func tick(now: Double)
}
```

**Timing strategy**: `CVDisplayLink` fires at the display refresh rate (typically 60 Hz or 120 Hz on ProMotion). On each tick, the engine checks `CACurrentMediaTime() - lastFrameTime >= 1.0 / Double(timeline.fps)`. If true, it advances `currentFrame` by 1 and updates `lastFrameTime`. This ensures frame-accurate timing without drift regardless of display refresh rate.

### AnimationSystem

```swift
/// Top-level coordinator for the keyframe animation system.
/// Owned by ViewModel and injected into Renderer.
final class AnimationSystem: ObservableObject {
    
    let store:    KeyframeStore
    let timeline: Timeline
    let engine:   PlaybackEngine
    
    @Published private(set) var currentFrame: Int = 0
    @Published private(set) var isAnimating:  Bool = false  // true during playback or scrub
    
    weak var camera: Camera?
    
    init(camera: Camera)
    
    // MARK: - Keyframe Authoring
    
    /// Sets a keyframe for the given property at the current frame using the camera's current value.
    func setKeyframe(for property: AnimatableProperty)
    
    /// Sets keyframes for all properties at the current frame.
    func setAllKeyframes()
    
    /// Deletes the keyframe at the current frame for the given property.
    func deleteKeyframe(for property: AnimatableProperty)
    
    /// Deletes all keyframes at the current frame across all properties.
    func deleteAllKeyframesAtCurrentFrame()
    
    /// Removes all keyframes for all properties.
    func clearAllKeyframes()
    
    // MARK: - Scrubbing
    
    /// Moves the playhead to the given frame and applies the interpolated CameraState.
    func scrub(to frame: Int)
    
    // MARK: - Camera Application
    
    /// Evaluates the interpolated CameraState at the given frame and applies it to the camera.
    func applyInterpolatedState(at frame: Int)
    
    // MARK: - Persistence
    
    func save(to url: URL) throws
    func load(from url: URL) throws
}
```

### PersistenceManager

```swift
/// Handles serialization and deserialization of animation data.
enum PersistenceManager {
    
    /// Serializes the animation state to a JSON `.gsanim` file.
    static func save(_ document: AnimationDocument, to url: URL) throws
    
    /// Deserializes a `.gsanim` file into an AnimationDocument.
    /// Throws AnimationLoadError if the file is malformed or contains invalid data.
    static func load(from url: URL) throws -> AnimationDocument
}

/// The root serializable type for a `.gsanim` file.
struct AnimationDocument: Codable {
    var version:    Int = 1
    var startFrame: Int
    var endFrame:   Int
    var fps:        Int
    var tracks:     [AnimationTrack]
}

/// One property's keyframe sequence.
struct AnimationTrack: Codable {
    var property:  AnimatableProperty
    var keyframes: [Keyframe]
}

enum AnimationLoadError: LocalizedError {
    case fileNotFound
    case malformedJSON(underlying: Error)
    case invalidVersion(Int)
    case invalidTimelineConfiguration(String)
    case invalidKeyframeData(property: AnimatableProperty, frame: Int, reason: String)
    
    var errorDescription: String? { ... }
}
```

---

## Data Models

### .gsanim JSON Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "GSAnim",
  "description": "Gaussian Splat Viewer animation file format",
  "type": "object",
  "required": ["version", "startFrame", "endFrame", "fps", "tracks"],
  "properties": {
    "version": {
      "type": "integer",
      "description": "File format version. Current: 1",
      "minimum": 1
    },
    "startFrame": {
      "type": "integer",
      "minimum": 0
    },
    "endFrame": {
      "type": "integer",
      "minimum": 1,
      "maximum": 18000
    },
    "fps": {
      "type": "integer",
      "enum": [24, 30, 60]
    },
    "tracks": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["property", "keyframes"],
        "properties": {
          "property": {
            "type": "string",
            "enum": ["azimuth", "elevation", "distance", "targetX", "targetY", "targetZ", "fovDegrees", "roll"]
          },
          "keyframes": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["id", "frame", "value", "interpolationMode"],
              "properties": {
                "id":                { "type": "string", "format": "uuid" },
                "frame":             { "type": "integer", "minimum": 0 },
                "value":             { "type": "number" },
                "interpolationMode": {
                  "type": "string",
                  "enum": ["linear", "bezier", "easeIn", "easeOut", "easeInOut", "constant"]
                },
                "bezierHandle": {
                  "type": "object",
                  "required": ["inTangent", "outTangent"],
                  "properties": {
                    "inTangent":  { "$ref": "#/definitions/vec2" },
                    "outTangent": { "$ref": "#/definitions/vec2" }
                  }
                }
              }
            }
          }
        }
      }
    }
  },
  "definitions": {
    "vec2": {
      "type": "array",
      "items": { "type": "number" },
      "minItems": 2,
      "maxItems": 2
    }
  }
}
```

### Example .gsanim File

```json
{
  "version": 1,
  "startFrame": 0,
  "endFrame": 120,
  "fps": 24,
  "tracks": [
    {
      "property": "azimuth",
      "keyframes": [
        {
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "frame": 0,
          "value": 0.0,
          "interpolationMode": "easeInOut"
        },
        {
          "id": "550e8400-e29b-41d4-a716-446655440001",
          "frame": 120,
          "value": 6.2831853,
          "interpolationMode": "easeInOut"
        }
      ]
    },
    {
      "property": "distance",
      "keyframes": [
        {
          "id": "550e8400-e29b-41d4-a716-446655440002",
          "frame": 0,
          "value": 5.0,
          "interpolationMode": "bezier",
          "bezierHandle": {
            "inTangent":  [0.0, 0.0],
            "outTangent": [20.0, 2.0]
          }
        },
        {
          "id": "550e8400-e29b-41d4-a716-446655440003",
          "frame": 120,
          "value": 2.0,
          "interpolationMode": "bezier",
          "bezierHandle": {
            "inTangent":  [-20.0, -1.0],
            "outTangent": [0.0, 0.0]
          }
        }
      ]
    }
  ]
}
```

### Camera.swift Additions

The only change to `Camera.swift` is adding a `roll` property (currently absent):

```swift
// In Camera.swift — add alongside existing properties:
var roll: Float = 0   // radians; applied as a rotation around the view axis

// In updateMatrices() — apply roll to the up vector before lookAt:
let cosR = cos(roll), sinR = sin(roll)
let right = normalize(cross(float3(0,1,0), float3(x,y,z).normalized))
up = float3(cosR * float3(0,1,0).x - sinR * right.x,
            cosR * float3(0,1,0).y - sinR * right.y,
            cosR * float3(0,1,0).z - sinR * right.z)
```

### Renderer.swift Additions

```swift
// In Renderer.swift — add weak reference:
weak var animationSystem: AnimationSystem?

// In handleMouseDown / handleMouseDrag — guard against animation override:
func handleMouseDown(at p: NSPoint, button: MouseButton) {
    guard animationSystem?.isAnimating != true else { return }
    // ... existing code
}
```

---

## Timeline UI Layout

### TimelineView Structure

```
┌─────────────────────────────────────────────────────────────────────┐
│ PLAYBACK CONTROLS BAR                                               │
│  [◀◀] [▶] [⏸] [⏹] [↺]   042 / 240   00:01:18   [24] [30] [60]    │
│  Start: [  0] End: [240]                                            │
├─────────────────────────────────────────────────────────────────────┤
│ RULER                                                               │
│  0    10    20    30    40    50    60    70    80    90   100 ...   │
│  ▼ (scrubber playhead)                                              │
├──────────┬──────────────────────────────────────────────────────────┤
│ azimuth  │  ◆              ◆                    ◆                   │
├──────────┼──────────────────────────────────────────────────────────┤
│ elevation│       ◆                   ◆                              │
├──────────┼──────────────────────────────────────────────────────────┤
│ distance │  ◆                                  ◆                   │
├──────────┼──────────────────────────────────────────────────────────┤
│ targetX  │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ targetY  │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ targetZ  │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ fovDeg   │  ◆                                  ◆                   │
├──────────┼──────────────────────────────────────────────────────────┤
│ roll     │                                                          │
└──────────┴──────────────────────────────────────────────────────────┘
│ GRAPH EDITOR (shown when a bezier keyframe is selected)             │
│  value ↑                                                            │
│        │    ●──○                    ○──●                            │
│        │   /                              \                         │
│        │  /                                \                        │
│        └──────────────────────────────────── frame →               │
└─────────────────────────────────────────────────────────────────────┘
```

### TimelineView Component Breakdown

```swift
/// Root timeline panel — collapsible, docked below the viewport.
struct TimelineView: View {
    @ObservedObject var animationSystem: AnimationSystem
    @State private var zoomScale: CGFloat = 1.0          // pixels per frame
    @State private var scrollOffset: CGFloat = 0
    @State private var selectedKeyframe: SelectedKeyframe?
    @State private var showGraphEditor: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            PlaybackControlsBar(animationSystem: animationSystem)
            Divider()
            TimelineTracksArea(
                animationSystem: animationSystem,
                zoomScale: $zoomScale,
                scrollOffset: $scrollOffset,
                selectedKeyframe: $selectedKeyframe
            )
            if showGraphEditor, let sel = selectedKeyframe {
                Divider()
                GraphEditorView(
                    animationSystem: animationSystem,
                    property: sel.property,
                    selectedKeyframeID: sel.id
                )
                .frame(height: 180)
            }
        }
        .frame(height: showGraphEditor ? 340 : 160)
    }
}

/// Transport controls: play/pause/stop/loop, frame counter, FPS selector, range inputs.
struct PlaybackControlsBar: View { ... }

/// Scrollable area containing the ruler and per-property track rows.
struct TimelineTracksArea: View { ... }

/// Horizontal ruler showing frame numbers at zoom-appropriate intervals.
struct TimelineRuler: View { ... }

/// One horizontal row for a single AnimatableProperty.
struct PropertyTrackRow: View {
    let property: AnimatableProperty
    let keyframes: [Keyframe]
    let zoomScale: CGFloat
    let scrollOffset: CGFloat
    var onKeyframeDragged: (UUID, Int) -> Void
    var onKeyframeTapped: (UUID) -> Void
}

/// Diamond-shaped keyframe marker, draggable horizontally.
struct KeyframeDiamond: View {
    let keyframe: Keyframe
    var onDrag: (Int) -> Void   // new frame number
    var onTap: () -> Void
}

/// Vertical playhead line spanning all tracks.
struct ScrubberLine: View {
    @Binding var frame: Int
    let zoomScale: CGFloat
    let scrollOffset: CGFloat
    let totalFrames: Int
    var onScrub: (Int) -> Void
}
```

### Graph Editor Component Breakdown

```swift
/// Displays the value-over-time curve for one property with Bezier handle editing.
struct GraphEditorView: View {
    @ObservedObject var animationSystem: AnimationSystem
    let property: AnimatableProperty
    let selectedKeyframeID: UUID
    
    @State private var viewportRect: CGRect = .zero
    
    var body: some View {
        Canvas { context, size in
            drawGrid(context: context, size: size)
            drawCurve(context: context, size: size)
            drawKeyframeDots(context: context, size: size)
            drawBezierHandles(context: context, size: size)
        }
        .gesture(DragGesture().onChanged { handleHandleDrag($0) })
    }
    
    // Coordinate mapping: frame → x pixel, value → y pixel
    private func frameToX(_ frame: Double, width: CGFloat) -> CGFloat { ... }
    private func valueToY(_ value: Float, height: CGFloat) -> CGFloat { ... }
    private func xToFrame(_ x: CGFloat, width: CGFloat) -> Double { ... }
    private func yToValue(_ y: CGFloat, height: CGFloat) -> Float { ... }
}
```

The graph editor renders:
1. **Grid**: Horizontal lines at regular value intervals; vertical lines at regular frame intervals
2. **Curve**: Sampled at 2-pixel intervals using `InterpolationEngine.evaluate`; drawn as a `Path`
3. **Keyframe dots**: Filled circles at each keyframe position
4. **Bezier handles**: Lines from keyframe dot to in/out tangent control points; control points are draggable circles

---

## Correctness Properties


*A property is a characteristic or behavior that should hold true across all valid executions of a system — essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

### Property 1: KeyframeStore property isolation

*For any* sequence of keyframe insertions across multiple `AnimatableProperty` values, each property's keyframe list SHALL contain exactly the keyframes inserted for that property and no keyframes from any other property.

**Validates: Requirements 1.1, 1.7**

---

### Property 2: Keyframe replacement at duplicate frame

*For any* `AnimatableProperty`, frame number, and pair of distinct values (v1, v2), inserting a keyframe with value v1 at that frame and then inserting a keyframe with value v2 at the same frame SHALL result in exactly one keyframe at that frame with value v2.

**Validates: Requirements 1.5**

---

### Property 3: KeyframeStore sorted-order invariant

*For any* sequence of keyframe insertions (in any order) into a `KeyframeStore`, the resulting keyframe list for each `AnimatableProperty` SHALL be sorted in strictly ascending order by frame number at all times.

**Validates: Requirements 1.6**

---

### Property 4: Deletion invariants

*For any* `KeyframeStore` state and any deletion operation (delete single keyframe, delete all at frame, or clear all):
- After `delete(frame:for:)`, no keyframe exists at that frame for that property; all other properties are unchanged.
- After `deleteAll(at:)`, no property has a keyframe at that frame; all keyframes at other frames are unchanged.
- After `clearAll()`, every property's keyframe list is empty.

**Validates: Requirements 1.7, 4.3, 4.4, 4.5**

---

### Property 5: Linear interpolation correctness

*For any* pair of values (v0, v1) and normalized time t ∈ [0, 1], `InterpolationEngine.linear(t: t, v0: v0, v1: v1)` SHALL equal `v0 + t * (v1 - v0)` within floating-point tolerance.

**Validates: Requirements 2.1**

---

### Property 6: Ease curve endpoint and boundary conditions

*For any* pair of values (v0, v1) and any ease mode (easeIn, easeOut, easeInOut), the interpolation function f SHALL satisfy:
- `f(t: 0, v0: v0, v1: v1) == v0`
- `f(t: 1, v0: v0, v1: v1) == v1`
- f is monotone when v0 ≤ v1 (i.e., f(t1) ≤ f(t2) for t1 ≤ t2)

**Validates: Requirements 2.3, 2.4, 2.5**

---

### Property 7: Cubic Hermite endpoint conditions

*For any* values (v0, v1) and tangents (m0, m1), `InterpolationEngine.cubicHermite` SHALL satisfy:
- `cubicHermite(t: 0, v0: v0, v1: v1, m0: m0, m1: m1) == v0`
- `cubicHermite(t: 1, v0: v0, v1: v1, m0: m0, m1: m1) == v1`

**Validates: Requirements 2.6**

---

### Property 8: Boundary extrapolation clamping

*For any* non-empty keyframe sequence for an `AnimatableProperty` and any frame number f:
- If f < first keyframe's frame, `InterpolationEngine.evaluate(at: f, keyframes:)` SHALL return the first keyframe's value.
- If f > last keyframe's frame, `InterpolationEngine.evaluate(at: f, keyframes:)` SHALL return the last keyframe's value.
- If the sequence has exactly one keyframe, `evaluate` SHALL return that keyframe's value for all f.

**Validates: Requirements 2.7, 2.8, 2.9**

---

### Property 9: Keyframe sequence serialization round-trip

*For any* valid keyframe sequence for an `AnimatableProperty` (any length, any interpolation modes, any BezierHandle values), serializing the sequence to JSON and deserializing it SHALL produce a sequence that evaluates to identical interpolated values at every integer frame in the range [firstKeyframe.frame, lastKeyframe.frame].

**Validates: Requirements 2.10**

---

### Property 10: Timeline FPS validation

*For any* integer value fps, `Timeline.setFPS(fps)` SHALL return `true` and update the FPS only if fps ∈ {24, 30, 60}; for all other values it SHALL return `false` and leave the FPS unchanged.

**Validates: Requirements 3.2**

---

### Property 11: Timeline duration formula

*For any* valid Timeline configuration (startFrame, endFrame, fps), `timeline.durationSeconds` SHALL equal `Double(endFrame - startFrame) / Double(fps)`.

**Validates: Requirements 3.3**

---

### Property 12: Timeline endFrame validation

*For any* Timeline with a given startFrame, `Timeline.setEndFrame(f)` SHALL return `false` and leave endFrame unchanged when f ≤ startFrame or f > 18,000; it SHALL return `true` and update endFrame when startFrame < f ≤ 18,000.

**Validates: Requirements 3.4, 3.5**

---

### Property 13: Set keyframe captures current camera value

*For any* `Camera` state and any `AnimatableProperty`, calling `AnimationSystem.setKeyframe(for:)` at the current frame SHALL store a keyframe whose value equals `property.currentValue(from: camera)` at that frame.

**Validates: Requirements 4.1**

---

### Property 14: Set all keyframes covers all properties

*For any* `Camera` state and any frame number, calling `AnimationSystem.setAllKeyframes()` SHALL result in all eight `AnimatableProperty` values having a keyframe at the current frame, each with the value read from the camera at the time of the call.

**Validates: Requirements 4.2**

---

### Property 15: Scrubber clamping

*For any* integer frame value f (including values outside [startFrame, endFrame]), `AnimationSystem.scrub(to: f)` SHALL set `currentFrame` to `max(startFrame, min(endFrame, f))`.

**Validates: Requirements 6.3**

---

### Property 16: Scrubber time string format

*For any* integer frame f in [0, 18,000] and any valid fps, `Timeline.timeString(for: f)` SHALL return a string matching the pattern `MM:SS:FF` where MM, SS, FF are zero-padded integers and the values correctly represent the time at that frame.

**Validates: Requirements 6.4**

---

### Property 17: CameraState apply round-trip

*For any* `CameraState` value, calling `cameraState.apply(to: camera)` and then `CameraState.capture(from: camera)` SHALL produce a `CameraState` equal to the original (within floating-point tolerance).

**Validates: Requirements 10.1**

---

### Property 18: Full animation persistence round-trip

*For any* valid `AnimationDocument` (any keyframe configuration, any timeline settings), saving it to a `.gsanim` file and loading it back SHALL produce an `AnimationDocument` that evaluates to identical interpolated `CameraState` values at every integer frame in [startFrame, endFrame].

**Validates: Requirements 11.5**

---

### Property 19: Playback timing correctness

*For any* configured FPS value fps ∈ {24, 30, 60} and any sequence of elapsed time deltas, the `PlaybackEngine` tick logic SHALL advance `currentFrame` by exactly 1 for each elapsed interval ≥ `1.0 / Double(fps)` seconds, and SHALL NOT advance the frame for intervals shorter than `1.0 / Double(fps)` seconds.

**Validates: Requirements 12.2, 12.3**

---

## Error Handling

### InterpolationEngine

- Empty keyframe array: returns 0.0 (defensive; callers should guard against this)
- NaN/Inf in keyframe values: propagated as-is (caller responsibility to validate input)
- Bezier keyframe missing BezierHandle: falls back to linear interpolation

### Timeline

- Invalid FPS: returns `false`, logs a warning, retains previous value
- endFrame ≤ startFrame: returns `false`, logs a warning, retains previous value
- endFrame > 18,000: returns `false`, logs a warning, retains previous value

### PersistenceManager

- File not found: throws `AnimationLoadError.fileNotFound`
- Malformed JSON: throws `AnimationLoadError.malformedJSON(underlying:)` with the underlying `DecodingError`
- Unknown version: throws `AnimationLoadError.invalidVersion(_:)` — allows future format migration
- Invalid timeline config in file (e.g., fps=25): throws `AnimationLoadError.invalidTimelineConfiguration(_:)`
- Invalid keyframe data (e.g., NaN value): throws `AnimationLoadError.invalidKeyframeData(property:frame:reason:)`
- All errors leave the current `AnimationSystem` state unchanged (atomic load)

### PlaybackEngine

- If `CACurrentMediaTime` returns a non-monotonic value (clock reset): resets `lastFrameTime` to current time, skips that tick
- If `currentFrame` somehow exceeds `endFrame` (race condition): clamps to `endFrame` and stops

### Camera Integration

- If `animationSystem` reference is nil during `draw(in:)`: proceeds with manual camera control (graceful degradation)
- Roll application: if `roll` is NaN, defaults to 0 before calling `updateMatrices()`

---

## Testing Strategy

### Dual Testing Approach

The testing strategy combines property-based tests (for universal correctness guarantees) with example-based unit tests (for specific behaviors and edge cases) and integration tests (for component wiring).

### Property-Based Testing Library

Use **SwiftCheck** (Swift port of QuickCheck) for property-based testing. Each property test runs a minimum of **100 iterations** with randomly generated inputs.

Tag format for each property test:
```swift
// Feature: keyframe-animation-system, Property N: <property_text>
```

### Property Test Implementations

Each of the 19 correctness properties maps to one property-based test:

| Property | Test Target | Generator |
|---|---|---|
| P1: Property isolation | `KeyframeStore` | Random `[AnimatableProperty: [Keyframe]]` insertions |
| P2: Replacement | `KeyframeStore.set` | Random `(property, frame, Float, Float)` |
| P3: Sorted order | `KeyframeStore` | Random insertion sequences |
| P4: Deletion invariants | `KeyframeStore` | Random store + deletion operations |
| P5: Linear interpolation | `InterpolationEngine.linear` | Random `(Float, Float, Float)` in [0,1] |
| P6: Ease curve endpoints | `InterpolationEngine.easeIn/Out/InOut` | Random `(Float, Float)` pairs |
| P7: Hermite endpoints | `InterpolationEngine.cubicHermite` | Random `(Float, Float, Float, Float)` |
| P8: Boundary clamping | `InterpolationEngine.evaluate` | Random keyframe sequences + out-of-range frames |
| P9: Keyframe sequence round-trip | `Keyframe` + `JSONEncoder/Decoder` | Random `[Keyframe]` sequences |
| P10: FPS validation | `Timeline.setFPS` | Random `Int` values |
| P11: Duration formula | `Timeline.durationSeconds` | Random valid `(startFrame, endFrame, fps)` |
| P12: endFrame validation | `Timeline.setEndFrame` | Random `Int` values |
| P13: Set keyframe capture | `AnimationSystem.setKeyframe` | Random `Camera` states |
| P14: Set all keyframes | `AnimationSystem.setAllKeyframes` | Random `Camera` states |
| P15: Scrubber clamping | `AnimationSystem.scrub` | Random `Int` frame values |
| P16: Time string format | `Timeline.timeString` | Random frames in [0, 18000] |
| P17: CameraState round-trip | `CameraState.apply` + `capture` | Random `CameraState` values |
| P18: Persistence round-trip | `PersistenceManager` | Random `AnimationDocument` values |
| P19: Playback timing | `PlaybackEngine` tick logic | Random elapsed time sequences |

### Example-Based Unit Tests

Focus on specific behaviors not covered by property tests:

- **Transport state machine**: play → pause → stop transitions; loop mode wrap-around
- **Auto-tangent computation**: verify smooth tangent for specific keyframe configurations
- **Graph editor coordinate mapping**: verify frame↔pixel and value↔pixel conversions
- **Error handling**: malformed JSON, invalid FPS in file, missing required fields
- **Camera roll application**: verify roll=0 produces standard up vector
- **Keyframe drag**: verify frame number updates correctly when diamond is dragged

### Integration Tests

- **PlaybackEngine + Camera**: verify camera state updates during simulated playback
- **AnimationSystem + Renderer**: verify mouse input suppression during animation
- **PersistenceManager**: save and load a real `.gsanim` file on disk
- **TimelineView + AnimationSystem**: verify UI reflects state changes via `@Published` properties

### Test File Organization

```
Tests/
  AnimationSystem/
    KeyframeStoreTests.swift          // P1, P2, P3, P4 + unit tests
    InterpolationEngineTests.swift    // P5, P6, P7, P8 + unit tests
    TimelineTests.swift               // P10, P11, P12 + unit tests
    AnimationSystemTests.swift        // P13, P14, P15, P16, P17 + unit tests
    PlaybackEngineTests.swift         // P19 + unit tests
    PersistenceManagerTests.swift     // P9, P18 + unit tests
    CameraStateTests.swift            // P17 + unit tests
```
