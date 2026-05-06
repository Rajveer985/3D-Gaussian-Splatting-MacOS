import Foundation

/// A single time-stamped value for one AnimatableProperty.
struct Keyframe: Codable, Equatable, Identifiable {
    let id: UUID
    var frame: Int
    var value: Float
    var interpolationMode: InterpolationMode
    /// Non-nil only when interpolationMode == .bezier.
    var bezierHandle: BezierHandle?

    init(
        frame: Int,
        value: Float,
        interpolationMode: InterpolationMode = .linear,
        bezierHandle: BezierHandle? = nil
    ) {
        self.id = UUID()
        self.frame = frame
        self.value = value
        self.interpolationMode = interpolationMode
        self.bezierHandle = bezierHandle
    }
}
