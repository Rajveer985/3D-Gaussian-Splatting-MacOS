import Foundation

/// The curve type used to interpolate between two consecutive keyframes.
enum InterpolationMode: String, CaseIterable, Codable {
    case linear
    case bezier
    case easeIn
    case easeOut
    case easeInOut
    case constant
}
