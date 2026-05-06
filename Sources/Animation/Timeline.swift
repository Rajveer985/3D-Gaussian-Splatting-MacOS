import Foundation
import Combine

/// Holds timeline configuration: frame range and FPS.
/// All mutation methods validate their inputs and return a Bool indicating success.
final class Timeline: ObservableObject {

    @Published private(set) var startFrame: Int = 0
    @Published private(set) var endFrame: Int = 240
    @Published private(set) var fps: Int = 24

    /// Valid FPS values accepted by `setFPS(_:)`.
    static let validFPS: Set<Int> = [24, 30, 60]

    /// Maximum allowed end frame (10 minutes at 30 FPS).
    static let maxFrames: Int = 18_000

    // MARK: - Computed properties

    /// Total duration in seconds: `(endFrame - startFrame) / fps`.
    var durationSeconds: Double {
        Double(endFrame - startFrame) / Double(fps)
    }

    /// Total number of frames in the timeline.
    var frameCount: Int {
        endFrame - startFrame
    }

    // MARK: - Mutations

    /// Attempts to set the start frame.
    /// Rejects if `frame >= endFrame`.
    /// - Returns: `true` on success, `false` if rejected.
    @discardableResult
    func setStartFrame(_ frame: Int) -> Bool {
        guard frame < endFrame else { return false }
        startFrame = frame
        return true
    }

    /// Attempts to set the end frame.
    /// Rejects if `f <= startFrame` or `f > maxFrames`.
    /// - Returns: `true` on success, `false` if rejected.
    @discardableResult
    func setEndFrame(_ f: Int) -> Bool {
        guard f > startFrame, f <= Timeline.maxFrames else { return false }
        endFrame = f
        return true
    }

    /// Attempts to set the FPS.
    /// Rejects if `fps` is not in `{24, 30, 60}`.
    /// - Returns: `true` on success, `false` if rejected.
    @discardableResult
    func setFPS(_ fps: Int) -> Bool {
        guard Timeline.validFPS.contains(fps) else { return false }
        self.fps = fps
        return true
    }

    // MARK: - Utilities

    /// Clamps a frame number to `[startFrame, endFrame]`.
    func clamp(_ frame: Int) -> Int {
        max(startFrame, min(endFrame, frame))
    }

    /// Converts a frame number to a time string in `MM:SS:FF` format.
    ///
    /// - `MM`: minutes, zero-padded to 2 digits
    /// - `SS`: seconds within the minute, zero-padded to 2 digits
    /// - `FF`: frame within the current second, zero-padded to 2 digits
    ///
    /// Example: frame 42 at 24 fps → `"00:01:18"` (1 second = 24 frames, remainder = 18 frames)
    func timeString(for frame: Int) -> String {
        let totalSeconds = frame / fps
        let remainderFrames = frame % fps
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", minutes, seconds, remainderFrames)
    }
}
