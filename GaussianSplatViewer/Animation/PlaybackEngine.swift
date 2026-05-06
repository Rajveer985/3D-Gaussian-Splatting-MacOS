import Foundation
import Combine
import QuartzCore

protocol AnimationSystemProtocol: AnyObject {
    func applyInterpolatedState(at frame: Int)
}

final class PlaybackEngine: ObservableObject {
    @Published private(set) var isPlaying:    Bool = false
    @Published private(set) var currentFrame: Int  = 0

    var loopEnabled: Bool = false
    weak var animationSystem: AnimationSystemProtocol?
    var timeline: Timeline!

    private var displayTimer: DispatchSourceTimer?
    private var lastFrameTime: Double = 0

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        lastFrameTime = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in self?.tick(now: CACurrentMediaTime()) }
        timer.resume()
        displayTimer = timer
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        displayTimer?.cancel()
        displayTimer = nil
    }

    func stop() {
        isPlaying = false
        displayTimer?.cancel()
        displayTimer = nil
        currentFrame = timeline.startFrame
    }

    func scrub(to frame: Int) {
        currentFrame = timeline.clamp(frame)
    }

    func tick(now: Double) {
        if now < lastFrameTime { lastFrameTime = now; return }
        let frameDuration = 1.0 / Double(timeline.fps)
        guard now - lastFrameTime >= frameDuration else { return }
        currentFrame += 1
        lastFrameTime = now
        if currentFrame > timeline.endFrame {
            if loopEnabled { currentFrame = timeline.startFrame }
            else { currentFrame = timeline.endFrame; pause(); return }
        }
        animationSystem?.applyInterpolatedState(at: currentFrame)
    }
}
