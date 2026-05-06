# Requirements Document

## Introduction

This feature adds a professional, industry-standard keyframe animation system to the macOS Gaussian Splat Viewer. The system enables users to animate camera properties (position, target/look-at, focal length/FOV, and roll) over time using a timeline with multiple interpolation modes — including Linear, Bezier with tangent handles, Ease In, Ease Out, Ease In/Out, and Constant/Step — matching the quality and workflow of tools like DaVinci Resolve, After Effects, and Blender. The animation plays back in real time at a configurable frame rate and is designed to be smooth enough for screen recording.

Keyframes are stored per-property so that individual camera properties can have independent timing and interpolation curves, exactly as in professional DCCs (Digital Content Creation tools).

---

## Glossary

- **AnimationSystem**: The top-level controller that owns the timeline, keyframe store, playback engine, and interpolation engine.
- **Timeline**: The time axis measured in frames, with a defined start frame, end frame, and frames-per-second (FPS) rate.
- **Keyframe**: A time-stamped value for a single animatable property, together with an interpolation mode and optional Bezier tangent handles.
- **AnimatableProperty**: One of the scalar or vector camera properties that can be keyframed: `positionX`, `positionY`, `positionZ`, `targetX`, `targetY`, `targetZ`, `fovDegrees`, `roll`.
- **InterpolationMode**: The curve type used to interpolate between two consecutive keyframes. Valid modes: `linear`, `bezier`, `easeIn`, `easeOut`, `easeInOut`, `constant`.
- **BezierHandle**: A pair of 2-D control points (in time–value space) attached to a keyframe that define the tangent of a cubic Bezier segment. Each handle has an `inTangent` and an `outTangent`.
- **PlaybackEngine**: The subsystem that advances the current frame in real time, driven by a `CADisplayLink`-equivalent timer, and applies interpolated camera values each frame.
- **Scrubber**: The interactive playhead that the user drags along the Timeline to preview any frame.
- **TimelineView**: The SwiftUI panel that renders the Timeline ruler, per-property keyframe tracks, the Scrubber, and playback controls.
- **GraphEditorView**: An optional overlay within the TimelineView that displays the value-over-time curve for a selected property and exposes Bezier handles for editing.
- **CameraState**: A snapshot of all eight AnimatableProperties at a given frame, used as the output of the interpolation engine.
- **FPS**: Frames per second — the playback rate. Supported values: 24, 30, 60.
- **Renderer**: The existing `Renderer.swift` class that owns the `Camera` and drives Metal rendering.
- **Camera**: The existing `Camera.swift` orbital camera with `position`, `target`, `distance`, `azimuth`, `elevation`, `fovDegrees`, `nearZ`, `farZ`.

---

## Requirements

### Requirement 1: Keyframe Data Model

**User Story:** As a cinematographer, I want to store keyframes per camera property with an interpolation mode and optional Bezier handles, so that each property can have its own independent animation curve.

#### Acceptance Criteria

1. THE AnimationSystem SHALL store keyframes independently for each AnimatableProperty.
2. WHEN a keyframe is created, THE AnimationSystem SHALL record the frame number, the scalar value of the AnimatableProperty at that frame, the InterpolationMode, and the BezierHandle if the InterpolationMode is `bezier`.
3. THE AnimationSystem SHALL support the following AnimatableProperties: `positionX`, `positionY`, `positionZ`, `targetX`, `targetY`, `targetZ`, `fovDegrees`, `roll`.
4. THE AnimationSystem SHALL support the following InterpolationModes: `linear`, `bezier`, `easeIn`, `easeOut`, `easeInOut`, `constant`.
5. WHEN two keyframes exist for the same AnimatableProperty at the same frame number, THE AnimationSystem SHALL replace the earlier keyframe with the new one.
6. THE AnimationSystem SHALL keep keyframes for each AnimatableProperty sorted in ascending frame order at all times.
7. WHEN a keyframe is deleted, THE AnimationSystem SHALL remove it from the sorted keyframe list for that AnimatableProperty without affecting keyframes of other properties.

---

### Requirement 2: Interpolation Engine

**User Story:** As an animator, I want smooth, mathematically correct interpolation between keyframes, so that camera motion looks professional and matches industry-standard curve behavior.

#### Acceptance Criteria

1. WHEN the InterpolationMode of a keyframe segment is `linear`, THE AnimationSystem SHALL interpolate the value using linear interpolation between the two bounding keyframe values.
2. WHEN the InterpolationMode of a keyframe segment is `constant`, THE AnimationSystem SHALL hold the value of the earlier keyframe until the later keyframe's frame is reached.
3. WHEN the InterpolationMode of a keyframe segment is `easeIn`, THE AnimationSystem SHALL apply a cubic ease-in curve (slow start, fast end) between the two bounding keyframe values.
4. WHEN the InterpolationMode of a keyframe segment is `easeOut`, THE AnimationSystem SHALL apply a cubic ease-out curve (fast start, slow end) between the two bounding keyframe values.
5. WHEN the InterpolationMode of a keyframe segment is `easeInOut`, THE AnimationSystem SHALL apply a cubic ease-in-out curve (slow start, slow end) between the two bounding keyframe values.
6. WHEN the InterpolationMode of a keyframe segment is `bezier`, THE AnimationSystem SHALL evaluate a cubic Hermite spline using the `outTangent` of the earlier keyframe and the `inTangent` of the later keyframe as the tangent vectors.
7. WHEN the current frame is before the first keyframe of an AnimatableProperty, THE AnimationSystem SHALL return the value of the first keyframe (no extrapolation).
8. WHEN the current frame is after the last keyframe of an AnimatableProperty, THE AnimationSystem SHALL return the value of the last keyframe (no extrapolation).
9. WHEN only one keyframe exists for an AnimatableProperty, THE AnimationSystem SHALL return that keyframe's value for all frames.
10. FOR ALL valid AnimatableProperty keyframe sequences, serializing the sequence to JSON and deserializing it SHALL produce a sequence that evaluates to identical interpolated values at every integer frame (round-trip property).

---

### Requirement 3: Timeline Configuration

**User Story:** As a director, I want to configure the timeline's frame range and playback rate, so that I can match the animation to my intended screen recording format.

#### Acceptance Criteria

1. THE Timeline SHALL have a configurable start frame (default: 0), end frame (default: 240), and FPS rate (default: 24).
2. WHEN the FPS is set, THE AnimationSystem SHALL accept only the values 24, 30, or 60; IF any other value is provided, THEN THE AnimationSystem SHALL reject it and retain the previous FPS value.
3. THE Timeline SHALL expose the total duration in seconds, computed as `(endFrame - startFrame) / fps`.
4. WHEN the end frame is set to a value less than or equal to the start frame, THE AnimationSystem SHALL reject the change and retain the previous end frame value.
5. THE Timeline SHALL support a frame range of 1 to 18,000 frames (10 minutes at 30 FPS).

---

### Requirement 4: Keyframe Authoring — Set and Delete

**User Story:** As an animator, I want to set a keyframe at the current frame for any camera property, so that I can record the camera state at specific moments in time.

#### Acceptance Criteria

1. WHEN the user triggers "Set Keyframe" for a specific AnimatableProperty, THE AnimationSystem SHALL read the current value of that property from the Camera and store it as a keyframe at the current Scrubber frame.
2. WHEN the user triggers "Set All Keyframes", THE AnimationSystem SHALL set a keyframe for every AnimatableProperty simultaneously at the current Scrubber frame, using the current Camera state.
3. WHEN the user triggers "Delete Keyframe" for a specific AnimatableProperty at the current frame, THE AnimationSystem SHALL remove the keyframe at that frame for that property; IF no keyframe exists at that frame for that property, THEN THE AnimationSystem SHALL take no action.
4. WHEN the user triggers "Delete All Keyframes at Frame", THE AnimationSystem SHALL remove all keyframes across all AnimatableProperties at the current Scrubber frame.
5. WHEN the user triggers "Clear All Keyframes", THE AnimationSystem SHALL remove all keyframes for all AnimatableProperties.

---

### Requirement 5: Playback Engine

**User Story:** As a cinematographer, I want real-time animation playback at a configurable FPS, so that I can preview and screen-record the animated camera path.

#### Acceptance Criteria

1. WHEN the user triggers "Play", THE PlaybackEngine SHALL advance the current frame at the configured FPS rate using a high-resolution timer.
2. WHILE the PlaybackEngine is playing, THE PlaybackEngine SHALL evaluate the interpolated CameraState at each frame and apply it to the Camera before each render.
3. WHEN the current frame reaches the end frame during playback, THE PlaybackEngine SHALL stop playback and set the current frame to the end frame; IF loop mode is enabled, THEN THE PlaybackEngine SHALL wrap the current frame back to the start frame and continue playing.
4. WHEN the user triggers "Pause", THE PlaybackEngine SHALL stop advancing the frame counter and retain the current frame.
5. WHEN the user triggers "Stop", THE PlaybackEngine SHALL stop advancing the frame counter and set the current frame to the start frame.
6. WHILE the PlaybackEngine is playing, THE PlaybackEngine SHALL not drop frames due to UI updates; the render loop SHALL remain independent of the playback timer.
7. THE PlaybackEngine SHALL expose the current frame number and current time in seconds as observable properties for the UI to display.

---

### Requirement 6: Scrubbing

**User Story:** As an animator, I want to drag the playhead along the timeline to preview any frame, so that I can inspect the camera path at any point without playing the full animation.

#### Acceptance Criteria

1. WHEN the user drags the Scrubber to a new frame position, THE AnimationSystem SHALL evaluate the interpolated CameraState at that frame and apply it to the Camera immediately.
2. WHILE the user is dragging the Scrubber, THE PlaybackEngine SHALL remain paused.
3. WHEN the Scrubber is moved to a frame outside the range [startFrame, endFrame], THE AnimationSystem SHALL clamp the frame to the nearest boundary.
4. THE Scrubber SHALL display the current frame number and the corresponding time in seconds (formatted as `MM:SS:FF`).

---

### Requirement 7: Timeline UI — Keyframe Tracks

**User Story:** As an animator, I want to see keyframe diamonds on per-property tracks in the timeline, so that I can visually understand the timing and density of my animation.

#### Acceptance Criteria

1. THE TimelineView SHALL display one horizontal track per AnimatableProperty that has at least one keyframe.
2. WHEN a keyframe exists at a frame position, THE TimelineView SHALL render a diamond-shaped marker at the corresponding horizontal position on that property's track.
3. WHEN the user clicks a keyframe diamond, THE TimelineView SHALL select that keyframe and display its frame number, value, and InterpolationMode in an inspector area.
4. WHEN the user drags a keyframe diamond horizontally, THE AnimationSystem SHALL update the keyframe's frame number to the new position, maintaining sorted order.
5. THE TimelineView SHALL render a ruler above the tracks showing frame numbers at regular intervals appropriate to the zoom level.
6. THE TimelineView SHALL support horizontal zoom so that the user can expand or compress the visible frame range.

---

### Requirement 8: Playback Controls UI

**User Story:** As a director, I want standard transport controls (play, pause, stop, loop, FPS selector, frame counter), so that I can control playback without leaving the viewport.

#### Acceptance Criteria

1. THE TimelineView SHALL display Play, Pause, Stop, and Loop toggle buttons.
2. WHEN the PlaybackEngine is playing, THE TimelineView SHALL show the Pause button as active and the Play button as inactive.
3. WHEN the PlaybackEngine is stopped or paused, THE TimelineView SHALL show the Play button as active.
4. THE TimelineView SHALL display a frame counter showing the current frame number and total frame count (e.g., `042 / 240`).
5. THE TimelineView SHALL display a time counter showing the current time in `MM:SS:FF` format.
6. THE TimelineView SHALL provide a segmented control to select the FPS rate (24, 30, 60).
7. THE TimelineView SHALL provide numeric input fields for the start frame and end frame of the Timeline.

---

### Requirement 9: Bezier Handle Editing

**User Story:** As an animator, I want to edit Bezier tangent handles on keyframes in a graph editor, so that I can fine-tune the acceleration and deceleration of each camera property curve.

#### Acceptance Criteria

1. WHEN the user selects a keyframe with InterpolationMode `bezier`, THE GraphEditorView SHALL display the value-over-time curve for that AnimatableProperty and render the `inTangent` and `outTangent` handles as draggable control points.
2. WHEN the user drags a BezierHandle control point, THE AnimationSystem SHALL update the corresponding tangent vector and re-evaluate the curve in real time.
3. WHEN the user changes the InterpolationMode of a keyframe from a non-bezier mode to `bezier`, THE AnimationSystem SHALL initialize the BezierHandle tangents to produce a smooth curve matching the neighboring keyframe values (auto-tangent).
4. THE GraphEditorView SHALL render the interpolated curve as a continuous path between all keyframes of the selected AnimatableProperty.
5. THE GraphEditorView SHALL display horizontal grid lines at regular value intervals and vertical grid lines at regular frame intervals.

---

### Requirement 10: Camera State Application

**User Story:** As a developer, I want the animation system to apply interpolated camera states to the existing Camera object cleanly, so that the renderer always sees a valid camera without modification to the rendering pipeline.

#### Acceptance Criteria

1. WHEN the AnimationSystem applies a CameraState to the Camera, THE AnimationSystem SHALL set `camera.azimuth`, `camera.elevation`, `camera.distance`, `camera.target`, `camera.fovDegrees`, and `camera.roll` from the interpolated values and then call `camera.updateMatrices()`.
2. WHEN the AnimationSystem is in playback or scrubbing mode, THE AnimationSystem SHALL override any manual camera input from mouse/keyboard events for the duration of the playback or scrub.
3. WHEN the PlaybackEngine stops or the user exits animation mode, THE AnimationSystem SHALL restore manual camera control.
4. THE AnimationSystem SHALL derive `positionX/Y/Z` keyframe values from the camera's spherical coordinates (`azimuth`, `elevation`, `distance`) rather than the Cartesian `position` vector, to preserve the orbital camera model.

---

### Requirement 11: Persistence — Save and Load Animation

**User Story:** As a filmmaker, I want to save and load my animation keyframes to/from a file, so that I can resume work across sessions.

#### Acceptance Criteria

1. THE AnimationSystem SHALL serialize all keyframes, Timeline configuration (startFrame, endFrame, FPS), and BezierHandle data to a JSON file.
2. WHEN the user triggers "Save Animation", THE AnimationSystem SHALL write the serialized data to a user-chosen file path with the extension `.gsanim`.
3. WHEN the user triggers "Load Animation", THE AnimationSystem SHALL read a `.gsanim` file, deserialize the data, and restore all keyframes and Timeline configuration.
4. IF a `.gsanim` file is malformed or contains invalid data, THEN THE AnimationSystem SHALL report a descriptive error and leave the current animation state unchanged.
5. FOR ALL valid animation states, saving to a `.gsanim` file and loading it back SHALL produce an AnimationSystem state that evaluates to identical interpolated CameraState values at every integer frame (round-trip property).

---

### Requirement 12: Frame-Accurate Rendering for Screen Recording

**User Story:** As a cinematographer, I want the renderer to produce a frame-accurate, smooth output during playback, so that screen recording captures the animation without dropped or duplicated frames.

#### Acceptance Criteria

1. WHILE the PlaybackEngine is playing, THE Renderer SHALL render exactly one frame per display refresh at the configured FPS, using the interpolated CameraState for that frame.
2. WHEN the configured FPS is lower than the display refresh rate, THE PlaybackEngine SHALL advance the animation frame only when the elapsed wall-clock time since the last frame advance equals or exceeds `1 / fps` seconds.
3. THE PlaybackEngine SHALL use a monotonic high-resolution clock (e.g., `CACurrentMediaTime`) for frame timing to avoid drift over long animations.
4. WHEN the PlaybackEngine is playing, THE TimelineView SHALL update the Scrubber position and frame counter at most once per display refresh to avoid UI thread contention.

