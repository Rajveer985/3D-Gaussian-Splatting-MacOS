import Foundation
import Combine

/// Top-level coordinator for the keyframe animation system.
/// Owned by ViewModel and injected into Renderer.
/// Conforms to AnimationSystemProtocol so PlaybackEngine can call back into it.
final class AnimationSystem: ObservableObject, AnimationSystemProtocol {

    // MARK: - Sub-components

    let store:    KeyframeStore
    let timeline: Timeline
    let engine:   PlaybackEngine

    // MARK: - Published State

    /// The current playhead frame (mirrors engine.currentFrame during playback).
    @Published private(set) var currentFrame: Int = 0

    /// True while the system is applying an interpolated state (playback or scrub).
    /// Renderer uses this to suppress manual camera input.
    @Published private(set) var isAnimating: Bool = false

    // MARK: - References

    /// Weak reference to the camera — AnimationSystem does not own it.
    weak var camera: Camera?

    // MARK: - Cancellables

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(camera: Camera? = nil) {
        self.store    = KeyframeStore()
        self.timeline = Timeline()
        self.engine   = PlaybackEngine()

        self.camera = camera

        // Wire sub-components
        engine.timeline        = timeline
        engine.animationSystem = self

        // Mirror engine's currentFrame into our own published property
        engine.$currentFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                self?.currentFrame = frame
            }
            .store(in: &cancellables)
    }

    // MARK: - Keyframe Authoring

    /// Sets a keyframe for the given property at the current frame using the camera's current value.
    func setKeyframe(for property: AnimatableProperty) {
        guard let camera = camera else { return }
        let value = property.currentValue(from: camera)
        let keyframe = Keyframe(frame: currentFrame, value: value)
        store.set(keyframe, for: property)
    }

    /// Sets keyframes for all eight properties at the current frame using the camera's current state.
    func setAllKeyframes() {
        guard let camera = camera else { return }
        for property in AnimatableProperty.allCases {
            let value = property.currentValue(from: camera)
            let keyframe = Keyframe(frame: currentFrame, value: value)
            store.set(keyframe, for: property)
        }
    }

    /// Deletes the keyframe at the current frame for the given property.
    /// No-op if no keyframe exists at that frame for that property.
    func deleteKeyframe(for property: AnimatableProperty) {
        store.delete(frame: currentFrame, for: property)
    }

    /// Deletes all keyframes at the current frame across all properties.
    func deleteAllKeyframesAtCurrentFrame() {
        store.deleteAll(at: currentFrame)
    }

    /// Removes all keyframes for all properties.
    func clearAllKeyframes() {
        store.clearAll()
    }

    // MARK: - Scrubbing

    /// Moves the playhead to the given frame and applies the interpolated CameraState.
    /// Clamps the frame to [timeline.startFrame, timeline.endFrame].
    func scrub(to frame: Int) {
        let clamped = timeline.clamp(frame)
        currentFrame = clamped
        engine.scrub(to: clamped)

        isAnimating = true
        applyInterpolatedState(at: clamped)
        isAnimating = false
    }

    // MARK: - Camera Application (AnimationSystemProtocol)

    /// Evaluates the interpolated CameraState at the given frame and applies it to the camera.
    /// Called by PlaybackEngine on each tick, and directly by scrub(to:).
    func applyInterpolatedState(at frame: Int) {
        guard let camera = camera else { return }
        let state = InterpolationEngine.evaluate(at: Double(frame), store: store)
        state.apply(to: camera)
    }

    // MARK: - Persistence

    /// Saves the current animation state to a `.gsanim` file at the given URL.
    func save(to url: URL) throws {
        let tracks = AnimatableProperty.allCases.compactMap { property -> AnimationTrack? in
            let keyframes = store.keyframes(for: property)
            guard !keyframes.isEmpty else { return nil }
            return AnimationTrack(property: property, keyframes: keyframes)
        }
        let document = AnimationDocument(
            version:    1,
            startFrame: timeline.startFrame,
            endFrame:   timeline.endFrame,
            fps:        timeline.fps,
            tracks:     tracks
        )
        try PersistenceManager.save(document, to: url)
    }

    /// Loads animation state from a `.gsanim` file at the given URL.
    /// On success, replaces all keyframes and timeline configuration.
    /// On failure, leaves the current state unchanged and rethrows.
    func load(from url: URL) throws {
        let document = try PersistenceManager.load(from: url)

        // Apply timeline configuration
        timeline.setStartFrame(document.startFrame)
        timeline.setEndFrame(document.endFrame)
        timeline.setFPS(document.fps)

        // Replace all keyframes
        store.clearAll()
        for track in document.tracks {
            for keyframe in track.keyframes {
                store.set(keyframe, for: track.property)
            }
        }

        // Reset playhead to start
        scrub(to: timeline.startFrame)
    }
}
