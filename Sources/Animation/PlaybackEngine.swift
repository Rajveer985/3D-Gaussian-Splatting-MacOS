import Foundation
import Combine
import QuartzCore

/// Protocol that PlaybackEngine uses to apply interpolated camera state.
/// AnimationSystem will conform to this in Task 8.
protocol AnimationSystemProtocol: AnyObject {
    func applyInterpolatedState(at frame: Int)
}

/// Drives real-time animation playback using a timer.
/// Advances the current frame at the configured FPS rate and applies interpolated camera states.
final class PlaybackEngine: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentFrame: Int = 0
    
    // MARK: - Configuration
    
    var loopEnabled: Bool = false
    
    // MARK: - References
    
    /// Weak reference to the animation system coordinator.
    /// AnimationSystem conforms to AnimationSystemProtocol.
    weak var animationSystem: AnimationSystemProtocol?
    var timeline: Timeline!
    
    // MARK: - Internal State
    
    private var displayTimer: DispatchSourceTimer?
    private var lastFrameTime: Double = 0
    
    // MARK: - Transport Controls
    
    /// Starts playback from the current frame.
    /// Creates and starts a high-frequency timer that calls tick() on each display refresh.
    func play() {
        guard !isPlaying else { return }
        
        isPlaying = true
        lastFrameTime = CACurrentMediaTime()
        
        // Create a timer that fires at ~60Hz (display refresh rate)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            self?.tick(now: CACurrentMediaTime())
        }
        timer.resume()
        
        displayTimer = timer
    }
    
    /// Pauses playback, retaining the current frame.
    func pause() {
        guard isPlaying else { return }
        
        isPlaying = false
        displayTimer?.cancel()
        displayTimer = nil
    }
    
    /// Stops playback and resets to the start frame.
    func stop() {
        isPlaying = false
        displayTimer?.cancel()
        displayTimer = nil
        currentFrame = timeline.startFrame
    }
    
    /// Moves to the given frame without starting playback.
    /// Clamps the frame to [timeline.startFrame, timeline.endFrame].
    func scrub(to frame: Int) {
        let clampedFrame = timeline.clamp(frame)
        currentFrame = clampedFrame
    }
    
    // MARK: - Tick Logic
    
    /// Called by the display timer on each refresh.
    /// Advances currentFrame by 1 when elapsed time >= 1/fps.
    /// Handles loop wrap and end-of-range stop.
    /// Guards against non-monotonic clock.
    func tick(now: Double) {
        // Guard against non-monotonic clock
        if now < lastFrameTime {
            lastFrameTime = now
            return
        }
        
        // Check if enough time has elapsed for the next frame
        let frameDuration = 1.0 / Double(timeline.fps)
        let elapsed = now - lastFrameTime
        
        guard elapsed >= frameDuration else { return }
        
        // Advance frame
        currentFrame += 1
        lastFrameTime = now
        
        // Handle end-of-range
        if currentFrame > timeline.endFrame {
            if loopEnabled {
                // Wrap to start
                currentFrame = timeline.startFrame
            } else {
                // Stop at end
                currentFrame = timeline.endFrame
                pause()
                return
            }
        }
        
        // Apply interpolated state to camera
        animationSystem?.applyInterpolatedState(at: currentFrame)
    }
}
