# Implementation Plan: Keyframe Animation System

## Overview

Implement a professional keyframe animation system for the macOS Gaussian Splat Viewer. The system is built bottom-up: data models first, then the interpolation engine, then the playback engine, then the top-level coordinator, then persistence, and finally the SwiftUI timeline UI. Each task is self-contained and builds directly on the previous one. All property-based tests use **SwiftCheck**.

## Tasks

- [x] 1. Add `roll` property to `Camera` and set up the test target
  - Add `var roll: Float = 0` to `Camera.swift` alongside the existing spherical-coordinate properties
  - Update `updateMatrices()` to apply roll as a rotation of the `up` vector around the view axis before the `lookAt` call (see design §Camera.swift Additions)
  - Create the `Tests/AnimationSystem/` directory and add a Swift test target to the Xcode project (or Package.swift) that links SwiftCheck
  - Verify the existing renderer still compiles and renders correctly with the new property defaulting to 0
  - _Requirements: 1.3, 10.1_

- [x] 2. Implement core data model types
  - Create `Animation/AnimatableProperty.swift` — define the `AnimatableProperty` enum with all eight cases (`azimuth`, `elevation`, `distance`, `targetX`, `targetY`, `targetZ`, `fovDegrees`, `roll`), `displayName`, `currentValue(from:)`, and `apply(_:to:)` implementations
  - Create `Animation/InterpolationMode.swift` — define the `InterpolationMode` enum with all six cases
  - Create `Animation/BezierHandle.swift` — define `BezierHandle` struct with `inTangent`, `outTangent` (both `SIMD2<Float>`), and the `autoTangent(prev:current:next:)` static method using Catmull-Rom tangent formula
  - Create `Animation/Keyframe.swift` — define `Keyframe` struct with `id: UUID`, `frame: Int`, `value: Float`, `interpolationMode`, `bezierHandle?`, and the memberwise `init`
  - Create `Animation/CameraState.swift` — define `CameraState` struct with all eight fields, `apply(to:)`, `capture(from:)`, `value(for:)`, and `with(_:value:)`
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 10.1_

- [x] 3. Implement `KeyframeStore`
  - Create `Animation/KeyframeStore.swift` — implement `KeyframeStore` as a `final class: ObservableObject` with `@Published private(set) var keyframes: [AnimatableProperty: [Keyframe]]`
  - Implement `set(_:for:)` — insert or replace, maintaining ascending frame order (use binary search + sorted insert)
  - Implement `delete(frame:for:)`, `deleteAll(for:)`, `deleteAll(at:)`, `clearAll()`
  - Implement `move(keyframeID:for:toFrame:)` — remove old entry, re-insert at new frame, maintain sort
  - Implement query methods: `keyframes(for:)`, `hasKeyframe(at:for:)`, `keyframe(at:for:)`
  - _Requirements: 1.1, 1.5, 1.6, 1.7, 4.3, 4.4, 4.5_

  - [ ]* 3.1 Write property test P1 — KeyframeStore property isolation
    - **Property 1: Property isolation** — for any sequence of insertions across multiple properties, each property's list contains exactly its own keyframes
    - Use SwiftCheck generators for random `AnimatableProperty` values and `Keyframe` sequences
    - Tag: `// Feature: keyframe-animation-system, Property 1: KeyframeStore property isolation`
    - **Validates: Requirements 1.1, 1.7**
    - _File: `Tests/AnimationSystem/KeyframeStoreTests.swift`_

  - [ ]* 3.2 Write property test P2 — Keyframe replacement at duplicate frame
    - **Property 2: Replacement** — inserting v1 then v2 at the same frame leaves exactly one keyframe with value v2
    - Generate random `(AnimatableProperty, Int, Float, Float)` tuples
    - Tag: `// Feature: keyframe-animation-system, Property 2: Keyframe replacement at duplicate frame`
    - **Validates: Requirements 1.5**
    - _File: `Tests/AnimationSystem/KeyframeStoreTests.swift`_

  - [ ]* 3.3 Write property test P3 — KeyframeStore sorted-order invariant
    - **Property 3: Sorted order** — after any sequence of insertions in any order, each property's list is strictly ascending by frame
    - Generate random insertion sequences with arbitrary frame numbers
    - Tag: `// Feature: keyframe-animation-system, Property 3: KeyframeStore sorted-order invariant`
    - **Validates: Requirements 1.6**
    - _File: `Tests/AnimationSystem/KeyframeStoreTests.swift`_

  - [ ]* 3.4 Write property test P4 — Deletion invariants
    - **Property 4: Deletion invariants** — verify all three deletion operations (`delete(frame:for:)`, `deleteAll(at:)`, `clearAll()`) leave the correct residual state
    - Generate random store states and random deletion operations
    - Tag: `// Feature: keyframe-animation-system, Property 4: Deletion invariants`
    - **Validates: Requirements 1.7, 4.3, 4.4, 4.5**
    - _File: `Tests/AnimationSystem/KeyframeStoreTests.swift`_

- [x] 4. Implement `InterpolationEngine`
  - Create `Animation/InterpolationEngine.swift` — implement as a caseless `enum` (namespace)
  - Implement `linear(t:v0:v1:)` — `v0 + t * (v1 - v0)`
  - Implement `constant(t:v0:v1:)` — `t < 1.0 ? v0 : v1`
  - Implement `easeIn(t:v0:v1:)` — cubic polynomial with zero derivative at t=0: `v0 + (3t² - 2t³) * (v1 - v0)` with `t' = t`
  - Implement `easeOut(t:v0:v1:)` — mirror of easeIn: zero derivative at t=1
  - Implement `easeInOut(t:v0:v1:)` — smoothstep `v0 + (3t² - 2t³) * (v1 - v0)`
  - Implement `cubicHermite(t:v0:v1:m0:m1:)` — standard Hermite basis polynomials h00..h11
  - Implement `normalizedTime(frame:startFrame:endFrame:)` — clamp to [0, 1]
  - Implement `evaluate(at:keyframes:)` — handle empty (return 0), single keyframe, before-first, after-last, and segment dispatch by `interpolationMode`; extract tangent magnitudes from `BezierHandle` for Hermite; fall back to linear if `bezierHandle` is nil
  - Implement `evaluate(at:store:)` — call `evaluate(at:keyframes:)` for each property and assemble a `CameraState`
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9_

  - [ ]* 4.1 Write property test P5 — Linear interpolation correctness
    - **Property 5: Linear interpolation** — `linear(t:v0:v1:)` equals `v0 + t*(v1-v0)` within Float tolerance for all t ∈ [0,1]
    - Generate random `(Float, Float, Float)` triples with t clamped to [0,1]
    - Tag: `// Feature: keyframe-animation-system, Property 5: Linear interpolation correctness`
    - **Validates: Requirements 2.1**
    - _File: `Tests/AnimationSystem/InterpolationEngineTests.swift`_

  - [ ]* 4.2 Write property test P6 — Ease curve endpoint and boundary conditions
    - **Property 6: Ease curve endpoints** — for easeIn, easeOut, easeInOut: f(0,v0,v1)==v0, f(1,v0,v1)==v1, and f is monotone when v0 ≤ v1
    - Generate random `(Float, Float)` value pairs
    - Tag: `// Feature: keyframe-animation-system, Property 6: Ease curve endpoint and boundary conditions`
    - **Validates: Requirements 2.3, 2.4, 2.5**
    - _File: `Tests/AnimationSystem/InterpolationEngineTests.swift`_

  - [ ]* 4.3 Write property test P7 — Cubic Hermite endpoint conditions
    - **Property 7: Hermite endpoints** — `cubicHermite(t:0,...)` == v0 and `cubicHermite(t:1,...)` == v1 for all tangent values
    - Generate random `(Float, Float, Float, Float)` for (v0, v1, m0, m1)
    - Tag: `// Feature: keyframe-animation-system, Property 7: Cubic Hermite endpoint conditions`
    - **Validates: Requirements 2.6**
    - _File: `Tests/AnimationSystem/InterpolationEngineTests.swift`_

  - [ ]* 4.4 Write property test P8 — Boundary extrapolation clamping
    - **Property 8: Boundary clamping** — evaluate before first keyframe returns first value; after last returns last value; single keyframe returns that value for all frames
    - Generate random keyframe sequences and out-of-range frame numbers
    - Tag: `// Feature: keyframe-animation-system, Property 8: Boundary extrapolation clamping`
    - **Validates: Requirements 2.7, 2.8, 2.9**
    - _File: `Tests/AnimationSystem/InterpolationEngineTests.swift`_

- [x] 5. Implement `Timeline`
  - Create `Animation/Timeline.swift` — implement `final class Timeline: ObservableObject`
  - Add `@Published private(set)` properties: `startFrame = 0`, `endFrame = 240`, `fps = 24`
  - Implement `setStartFrame(_:)` — reject if `frame >= endFrame`; return Bool
  - Implement `setEndFrame(_:)` — reject if `f <= startFrame` or `f > 18_000`; return Bool
  - Implement `setFPS(_:)` — reject if not in `{24, 30, 60}`; return Bool
  - Implement `durationSeconds`, `frameCount`, `clamp(_:)`
  - Implement `timeString(for:)` — format as `MM:SS:FF` with zero-padding
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 6.3, 6.4_

  - [ ]* 5.1 Write property test P10 — Timeline FPS validation
    - **Property 10: FPS validation** — `setFPS` returns true only for {24, 30, 60}; false for all other Int values; FPS unchanged on rejection
    - Generate random `Int` values across a wide range
    - Tag: `// Feature: keyframe-animation-system, Property 10: Timeline FPS validation`
    - **Validates: Requirements 3.2**
    - _File: `Tests/AnimationSystem/TimelineTests.swift`_

  - [ ]* 5.2 Write property test P11 — Timeline duration formula
    - **Property 11: Duration formula** — `durationSeconds == Double(endFrame - startFrame) / Double(fps)` for all valid configurations
    - Generate random valid `(startFrame, endFrame, fps)` triples
    - Tag: `// Feature: keyframe-animation-system, Property 11: Timeline duration formula`
    - **Validates: Requirements 3.3**
    - _File: `Tests/AnimationSystem/TimelineTests.swift`_

  - [ ]* 5.3 Write property test P12 — Timeline endFrame validation
    - **Property 12: endFrame validation** — `setEndFrame` returns false when `f <= startFrame` or `f > 18_000`; true otherwise; endFrame unchanged on rejection
    - Generate random `Int` values including boundary cases
    - Tag: `// Feature: keyframe-animation-system, Property 12: Timeline endFrame validation`
    - **Validates: Requirements 3.4, 3.5**
    - _File: `Tests/AnimationSystem/TimelineTests.swift`_

  - [ ]* 5.4 Write property test P16 — Scrubber time string format
    - **Property 16: Time string format** — `timeString(for:)` matches `MM:SS:FF` pattern with correct values for all frames in [0, 18000] and all valid fps
    - Generate random frames in [0, 18000] and fps ∈ {24, 30, 60}
    - Tag: `// Feature: keyframe-animation-system, Property 16: Scrubber time string format`
    - **Validates: Requirements 6.4**
    - _File: `Tests/AnimationSystem/TimelineTests.swift`_

- [x] 6. Checkpoint — Ensure all tests pass
  - Run the full test suite; all property tests for P1–P8, P10–P12, P16 must pass
  - Ensure `Camera.swift` compiles with the new `roll` property and the renderer still renders correctly
  - Ask the user if any questions arise before proceeding to the playback engine

- [x] 7. Implement `PlaybackEngine`
  - Create `Animation/PlaybackEngine.swift` — implement `final class PlaybackEngine: ObservableObject`
  - Add `@Published private(set) var isPlaying: Bool = false` and `@Published private(set) var currentFrame: Int = 0`
  - Add `var loopEnabled: Bool = false` and `weak var animationSystem: AnimationSystem?`
  - Implement `play()` — create and start a `CVDisplayLink` (or `CADisplayLink` via a `RunLoop`-based wrapper); set `isPlaying = true`; record `lastFrameTime = CACurrentMediaTime()`
  - Implement `pause()` — invalidate the display link; set `isPlaying = false`; retain `currentFrame`
  - Implement `stop()` — invalidate the display link; set `isPlaying = false`; reset `currentFrame` to `timeline.startFrame`
  - Implement `scrub(to:)` — clamp frame to `[timeline.startFrame, timeline.endFrame]`; set `currentFrame`; do not start playback
  - Implement `tick(now:)` — check `now - lastFrameTime >= 1.0 / Double(timeline.fps)`; if true, advance `currentFrame` by 1, update `lastFrameTime`; handle loop wrap and end-of-range stop; call `animationSystem?.applyInterpolatedState(at: currentFrame)`
  - Handle non-monotonic clock: if `now < lastFrameTime`, reset `lastFrameTime = now` and skip the tick
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 12.1, 12.2, 12.3_

  - [ ]* 7.1 Write property test P19 — Playback timing correctness
    - **Property 19: Playback timing** — for any fps ∈ {24, 30, 60} and any sequence of elapsed time deltas, the tick logic advances `currentFrame` by exactly 1 per interval ≥ `1/fps` and does not advance for shorter intervals
    - Test the `tick` logic in isolation by injecting synthetic `now` timestamps; do not require a real display link
    - Generate random sequences of elapsed time deltas (mix of values above and below `1/fps`)
    - Tag: `// Feature: keyframe-animation-system, Property 19: Playback timing correctness`
    - **Validates: Requirements 12.2, 12.3**
    - _File: `Tests/AnimationSystem/PlaybackEngineTests.swift`_

- [x] 8. Implement `AnimationSystem`
  - Create `Animation/AnimationSystem.swift` — implement `final class AnimationSystem: ObservableObject`
  - Add `let store: KeyframeStore`, `let timeline: Timeline`, `let engine: PlaybackEngine`
  - Add `@Published private(set) var currentFrame: Int = 0` and `@Published private(set) var isAnimating: Bool = false`
  - Add `weak var camera: Camera?`
  - Implement `init(camera:)` — create sub-components; wire `engine.animationSystem = self`; wire `engine.timeline = timeline`
  - Implement keyframe authoring methods: `setKeyframe(for:)`, `setAllKeyframes()`, `deleteKeyframe(for:)`, `deleteAllKeyframesAtCurrentFrame()`, `clearAllKeyframes()`
  - Implement `scrub(to:)` — clamp via `timeline.clamp(_:)`; set `currentFrame`; set `isAnimating = true`; call `applyInterpolatedState(at:)`; set `isAnimating = false` after apply
  - Implement `applyInterpolatedState(at:)` — call `InterpolationEngine.evaluate(at:store:)`; call `cameraState.apply(to: camera)`
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 6.1, 6.2, 6.3, 10.1, 10.2, 10.3, 10.4_

  - [ ]* 8.1 Write property test P13 — Set keyframe captures current camera value
    - **Property 13: Set keyframe capture** — `setKeyframe(for:)` stores a keyframe whose value equals `property.currentValue(from: camera)` at `currentFrame`
    - Generate random `Camera` states (random azimuth, elevation, distance, etc.) and random properties
    - Tag: `// Feature: keyframe-animation-system, Property 13: Set keyframe captures current camera value`
    - **Validates: Requirements 4.1**
    - _File: `Tests/AnimationSystem/AnimationSystemTests.swift`_

  - [ ]* 8.2 Write property test P14 — Set all keyframes covers all properties
    - **Property 14: Set all keyframes** — `setAllKeyframes()` results in all eight properties having a keyframe at `currentFrame` with values matching the camera at call time
    - Generate random `Camera` states
    - Tag: `// Feature: keyframe-animation-system, Property 14: Set all keyframes covers all properties`
    - **Validates: Requirements 4.2**
    - _File: `Tests/AnimationSystem/AnimationSystemTests.swift`_

  - [ ]* 8.3 Write property test P15 — Scrubber clamping
    - **Property 15: Scrubber clamping** — `scrub(to:)` sets `currentFrame` to `max(startFrame, min(endFrame, f))` for any integer f
    - Generate random `Int` values including values far outside [startFrame, endFrame]
    - Tag: `// Feature: keyframe-animation-system, Property 15: Scrubber clamping`
    - **Validates: Requirements 6.3**
    - _File: `Tests/AnimationSystem/AnimationSystemTests.swift`_

  - [ ]* 8.4 Write property test P17 — CameraState apply round-trip
    - **Property 17: CameraState apply round-trip** — `cameraState.apply(to: camera)` then `CameraState.capture(from: camera)` produces a state equal to the original within Float tolerance
    - Generate random `CameraState` values (all eight fields)
    - Tag: `// Feature: keyframe-animation-system, Property 17: CameraState apply round-trip`
    - **Validates: Requirements 10.1**
    - _File: `Tests/AnimationSystem/AnimationSystemTests.swift`_

- [x] 9. Integrate `AnimationSystem` into `Renderer` and `ViewModel`
  - In `Renderer.swift`, add `weak var animationSystem: AnimationSystem?`
  - In `Renderer.handleMouseDown(at:button:)` and `handleMouseDrag(to:button:)`, add a guard: `guard animationSystem?.isAnimating != true else { return }`
  - In `ViewModel` (in `ViewportView.swift`), add `@Published var animationSystem: AnimationSystem?`
  - After the renderer is created in `ViewportView.makeNSView(context:)`, instantiate `AnimationSystem(camera: renderer.camera)`, assign it to `viewModel.animationSystem`, and inject it into `renderer.animationSystem`
  - _Requirements: 10.2, 10.3_

- [x] 10. Implement `PersistenceManager`
  - Create `Animation/PersistenceManager.swift` — implement as a caseless `enum`
  - Define `AnimationDocument: Codable` with `version: Int = 1`, `startFrame`, `endFrame`, `fps`, `tracks: [AnimationTrack]`
  - Define `AnimationTrack: Codable` with `property: AnimatableProperty` and `keyframes: [Keyframe]`
  - Define `AnimationLoadError: LocalizedError` with all five cases and `errorDescription` implementations
  - Implement `save(_:to:)` — encode with `JSONEncoder(outputFormatting: .prettyPrinted)`; write to URL; throw on failure
  - Implement `load(from:)` — read data; decode with `JSONDecoder`; validate `version == 1`; validate timeline config (fps ∈ {24,30,60}, endFrame > startFrame, endFrame ≤ 18000); validate keyframe data (no NaN values); throw typed errors on any failure
  - Add `save(to:)` and `load(from:)` convenience methods to `AnimationSystem` that build/apply `AnimationDocument` and delegate to `PersistenceManager`
  - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5_

  - [ ]* 10.1 Write property test P9 — Keyframe sequence serialization round-trip
    - **Property 9: Keyframe sequence round-trip** — for any valid `[Keyframe]` sequence, encode to JSON and decode back; the decoded sequence evaluates to identical interpolated values at every integer frame
    - Generate random `[Keyframe]` sequences with all interpolation modes and random BezierHandle values
    - Tag: `// Feature: keyframe-animation-system, Property 9: Keyframe sequence serialization round-trip`
    - **Validates: Requirements 2.10**
    - _File: `Tests/AnimationSystem/PersistenceManagerTests.swift`_

  - [ ]* 10.2 Write property test P18 — Full animation persistence round-trip
    - **Property 18: Full animation persistence round-trip** — for any valid `AnimationDocument`, save to a temp `.gsanim` file and load it back; the loaded document evaluates to identical `CameraState` values at every integer frame in [startFrame, endFrame]
    - Generate random `AnimationDocument` values with valid timeline configs and keyframe data
    - Tag: `// Feature: keyframe-animation-system, Property 18: Full animation persistence round-trip`
    - **Validates: Requirements 11.5**
    - _File: `Tests/AnimationSystem/PersistenceManagerTests.swift`_

- [x] 11. Checkpoint — Ensure all tests pass
  - Run the full test suite; all 19 property tests must pass
  - Manually verify that scrubbing in code (calling `animationSystem.scrub(to:)`) updates the camera and the renderer reflects the change
  - Ask the user if any questions arise before proceeding to the UI

- [x] 12. Implement `TimelineView` — playback controls and ruler
  - Create `UI/Timeline/PlaybackControlsBar.swift` — implement `struct PlaybackControlsBar: View`
    - Play/Pause/Stop buttons wired to `animationSystem.engine.play()`, `.pause()`, `.stop()`
    - Loop toggle button bound to `animationSystem.engine.loopEnabled`
    - Frame counter label: `"\(currentFrame) / \(timeline.endFrame)"`
    - Time counter label using `timeline.timeString(for: currentFrame)`
    - FPS segmented control (24 / 30 / 60) calling `timeline.setFPS(_:)`
    - Start/end frame numeric text fields calling `timeline.setStartFrame(_:)` / `timeline.setEndFrame(_:)`
  - Create `UI/Timeline/TimelineRuler.swift` — implement `struct TimelineRuler: View`
    - Draw frame number labels at zoom-appropriate intervals (every 1, 5, 10, or 30 frames depending on `zoomScale`)
    - Accept `zoomScale: CGFloat` and `scrollOffset: CGFloat` bindings
  - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7_

- [x] 13. Implement `TimelineView` — track rows, keyframe diamonds, and scrubber
  - Create `UI/Timeline/KeyframeDiamond.swift` — implement `struct KeyframeDiamond: View`
    - Render a rotated square (diamond) at the correct horizontal pixel position: `x = (keyframe.frame - scrollOffset) * zoomScale`
    - Support tap gesture calling `onTap()`
    - Support horizontal drag gesture computing new frame from pixel delta and calling `onDrag(newFrame)`
  - Create `UI/Timeline/PropertyTrackRow.swift` — implement `struct PropertyTrackRow: View`
    - Display the property `displayName` label in a fixed-width left column
    - Render `KeyframeDiamond` for each keyframe in the track
    - Forward drag and tap callbacks to `AnimationSystem`
  - Create `UI/Timeline/ScrubberLine.swift` — implement `struct ScrubberLine: View`
    - Render a vertical line at `x = (currentFrame - scrollOffset) * zoomScale`
    - Support drag gesture that calls `onScrub(newFrame)` → `animationSystem.scrub(to:)`
  - Create `UI/Timeline/TimelineTracksArea.swift` — implement `struct TimelineTracksArea: View`
    - Compose `TimelineRuler` + one `PropertyTrackRow` per property that has keyframes + `ScrubberLine` overlay
    - Support pinch-to-zoom updating `zoomScale` and scroll gesture updating `scrollOffset`
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 6.1, 6.2_

- [x] 14. Implement `GraphEditorView`
  - Create `UI/Timeline/GraphEditorView.swift` — implement `struct GraphEditorView: View`
  - Use `Canvas` to draw: grid lines, the interpolated curve (sampled every 2px using `InterpolationEngine.evaluate`), keyframe dots, and Bezier handle lines + draggable control point circles
  - Implement coordinate mapping helpers: `frameToX`, `valueToY`, `xToFrame`, `yToValue`
  - Implement `handleHandleDrag(_:)` — hit-test which handle is being dragged (in or out tangent of which keyframe); update `animationSystem.store` via `set(_:for:)` with the modified `BezierHandle`
  - Show/hide the graph editor from `TimelineView` when a bezier keyframe is selected
  - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_

- [x] 15. Assemble `TimelineView` and wire into `ContentView`
  - Create `UI/Timeline/TimelineView.swift` — implement the root `struct TimelineView: View`
    - Compose `PlaybackControlsBar`, `Divider`, `TimelineTracksArea`, and conditionally `GraphEditorView`
    - Manage `@State` for `zoomScale`, `scrollOffset`, `selectedKeyframe`, `showGraphEditor`
    - Set frame height: 340 when graph editor is visible, 160 otherwise
  - In `ContentView.swift`, add a `@State private var showTimeline = false` toggle button to the toolbar
  - Add `TimelineView(animationSystem: viewModel.animationSystem!)` below the main `HStack` content area, shown when `showTimeline && viewModel.animationSystem != nil`
  - Add "Save Animation…" and "Load Animation…" menu/toolbar buttons that call `animationSystem.save(to:)` / `animationSystem.load(from:)` via `NSSavePanel` / `NSOpenPanel`
  - _Requirements: 7.1, 7.5, 7.6, 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 11.2, 11.3_

- [x] 16. Final checkpoint — Ensure all tests pass and integration is complete
  - Run the full test suite; all 19 property tests and all unit tests must pass
  - Verify end-to-end: open a PLY file, open the timeline, set keyframes on azimuth and distance, scrub the timeline, press Play, observe smooth camera animation, save to `.gsanim`, reload, verify identical playback
  - Ensure mouse input is suppressed during playback and restored after Stop
  - Ask the user if any questions arise

## Notes

- Tasks marked with `*` are optional and can be skipped for a faster MVP; all 19 correctness properties are covered by the optional sub-tasks
- Property tests use **SwiftCheck** and run a minimum of 100 iterations each
- Each property test file tag format: `// Feature: keyframe-animation-system, Property N: <title>`
- The `roll` property defaults to 0, so all existing scenes render identically until a roll keyframe is set
- `AnimationSystem` holds strong references to `KeyframeStore`, `Timeline`, and `PlaybackEngine`; `Renderer` and `Camera` hold only weak references back to `AnimationSystem`
- The `.gsanim` file format version is 1; the loader rejects unknown versions with `AnimationLoadError.invalidVersion`
- All new Swift files go under `Animation/` (data/logic) or `UI/Timeline/` (views)
