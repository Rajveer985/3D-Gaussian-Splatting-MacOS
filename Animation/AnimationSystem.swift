import Foundation
import Combine

final class AnimationSystem: ObservableObject, AnimationSystemProtocol {
    let store:    KeyframeStore
    let timeline: Timeline
    let engine:   PlaybackEngine

    @Published private(set) var currentFrame: Int  = 0
    @Published private(set) var isAnimating:  Bool = false

    weak var camera: Camera?

    private var cancellables = Set<AnyCancellable>()

    init(camera: Camera? = nil) {
        self.store    = KeyframeStore()
        self.timeline = Timeline()
        self.engine   = PlaybackEngine()
        self.camera   = camera

        engine.timeline        = timeline
        engine.animationSystem = self

        engine.$currentFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in self?.currentFrame = frame }
            .store(in: &cancellables)
    }

    // MARK: - Keyframe Authoring

    func setKeyframe(for property: AnimatableProperty) {
        guard let camera else { return }
        store.set(Keyframe(frame: currentFrame, value: property.currentValue(from: camera)), for: property)
    }

    func setAllKeyframes() {
        guard let camera else { return }
        for property in AnimatableProperty.allCases {
            store.set(Keyframe(frame: currentFrame, value: property.currentValue(from: camera)), for: property)
        }
    }

    func deleteKeyframe(for property: AnimatableProperty) {
        store.delete(frame: currentFrame, for: property)
    }

    func deleteAllKeyframesAtCurrentFrame() {
        store.deleteAll(at: currentFrame)
    }

    func clearAllKeyframes() {
        store.clearAll()
    }

    // MARK: - Scrubbing

    func scrub(to frame: Int) {
        let clamped = timeline.clamp(frame)
        currentFrame = clamped
        engine.scrub(to: clamped)
        isAnimating = true
        applyInterpolatedState(at: clamped)
        isAnimating = false
    }

    // MARK: - AnimationSystemProtocol

    func applyInterpolatedState(at frame: Int) {
        guard let camera else { return }
        InterpolationEngine.evaluate(at: Double(frame), store: store).apply(to: camera)
    }

    // MARK: - Persistence

    func save(to url: URL) throws {
        let tracks = AnimatableProperty.allCases.compactMap { prop -> AnimationTrack? in
            let kfs = store.keyframes(for: prop)
            return kfs.isEmpty ? nil : AnimationTrack(property: prop, keyframes: kfs)
        }
        let doc = AnimationDocument(version: 1, startFrame: timeline.startFrame,
                                    endFrame: timeline.endFrame, fps: timeline.fps, tracks: tracks)
        try PersistenceManager.save(doc, to: url)
    }

    func load(from url: URL) throws {
        let doc = try PersistenceManager.load(from: url)
        timeline.setStartFrame(doc.startFrame)
        timeline.setEndFrame(doc.endFrame)
        timeline.setFPS(doc.fps)
        store.clearAll()
        for track in doc.tracks {
            for kf in track.keyframes { store.set(kf, for: track.property) }
        }
        scrub(to: timeline.startFrame)
    }
}
