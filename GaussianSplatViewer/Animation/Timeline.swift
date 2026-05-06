import Foundation
import Combine

final class Timeline: ObservableObject {
    @Published private(set) var startFrame: Int = 0
    @Published private(set) var endFrame:   Int = 240
    @Published private(set) var fps:        Int = 24

    static let validFPS:  Set<Int> = [24, 30, 60]
    static let maxFrames: Int      = 18_000

    var durationSeconds: Double { Double(endFrame - startFrame) / Double(fps) }
    var frameCount: Int { endFrame - startFrame }

    @discardableResult
    func setStartFrame(_ frame: Int) -> Bool {
        guard frame < endFrame else { return false }
        startFrame = frame; return true
    }

    @discardableResult
    func setEndFrame(_ f: Int) -> Bool {
        guard f > startFrame, f <= Timeline.maxFrames else { return false }
        endFrame = f; return true
    }

    @discardableResult
    func setFPS(_ fps: Int) -> Bool {
        guard Timeline.validFPS.contains(fps) else { return false }
        self.fps = fps; return true
    }

    func clamp(_ frame: Int) -> Int { max(startFrame, min(endFrame, frame)) }

    func timeString(for frame: Int) -> String {
        let totalSec = frame / fps
        let remFrames = frame % fps
        let minutes = totalSec / 60
        let seconds = totalSec % 60
        return String(format: "%02d:%02d:%02d", minutes, seconds, remFrames)
    }
}
