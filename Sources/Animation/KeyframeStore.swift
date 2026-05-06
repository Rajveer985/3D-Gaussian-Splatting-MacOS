import Foundation
import Combine

/// Manages sorted keyframe arrays for all AnimatableProperties.
/// All mutations maintain ascending frame order.
final class KeyframeStore: ObservableObject {

    /// Published so TimelineView can react to changes.
    @Published private(set) var keyframes: [AnimatableProperty: [Keyframe]] = [:]

    // MARK: - Mutations

    /// Inserts or replaces a keyframe for the given property.
    /// Maintains ascending frame order. Replaces if a keyframe at the same frame already exists.
    func set(_ keyframe: Keyframe, for property: AnimatableProperty) {
        var array = keyframes[property] ?? []

        // Binary search for the insertion index
        let idx = insertionIndex(in: array, for: keyframe.frame)

        // Check if a keyframe already exists at this frame (replace)
        if idx < array.count && array[idx].frame == keyframe.frame {
            array[idx] = keyframe
        } else {
            array.insert(keyframe, at: idx)
        }

        keyframes[property] = array
    }

    /// Removes the keyframe at the given frame for the given property.
    /// No-op if no keyframe exists at that frame.
    func delete(frame: Int, for property: AnimatableProperty) {
        guard var array = keyframes[property] else { return }
        let idx = insertionIndex(in: array, for: frame)
        guard idx < array.count && array[idx].frame == frame else { return }
        array.remove(at: idx)
        keyframes[property] = array
    }

    /// Removes all keyframes for the given property.
    func deleteAll(for property: AnimatableProperty) {
        keyframes[property] = []
    }

    /// Removes all keyframes across all properties at the given frame.
    func deleteAll(at frame: Int) {
        for property in AnimatableProperty.allCases {
            delete(frame: frame, for: property)
        }
    }

    /// Removes all keyframes for all properties.
    func clearAll() {
        keyframes = [:]
    }

    /// Moves a keyframe from one frame to another, maintaining sorted order.
    /// No-op if no keyframe with the given ID is found for the property.
    func move(keyframeID: UUID, for property: AnimatableProperty, toFrame newFrame: Int) {
        guard var array = keyframes[property],
              let oldIdx = array.firstIndex(where: { $0.id == keyframeID }) else { return }

        var keyframe = array[oldIdx]
        array.remove(at: oldIdx)

        // Update the frame
        keyframe.frame = newFrame

        // Remove any existing keyframe at the target frame (replace semantics)
        let targetIdx = insertionIndex(in: array, for: newFrame)
        if targetIdx < array.count && array[targetIdx].frame == newFrame {
            array[targetIdx] = keyframe
        } else {
            array.insert(keyframe, at: targetIdx)
        }

        keyframes[property] = array
    }

    // MARK: - Queries

    /// Returns the sorted keyframe array for the given property (empty if none).
    func keyframes(for property: AnimatableProperty) -> [Keyframe] {
        return keyframes[property] ?? []
    }

    /// Returns true if a keyframe exists at the given frame for the given property.
    func hasKeyframe(at frame: Int, for property: AnimatableProperty) -> Bool {
        guard let array = keyframes[property] else { return false }
        let idx = insertionIndex(in: array, for: frame)
        return idx < array.count && array[idx].frame == frame
    }

    /// Returns the keyframe at the given frame for the given property, or nil.
    func keyframe(at frame: Int, for property: AnimatableProperty) -> Keyframe? {
        guard let array = keyframes[property] else { return nil }
        let idx = insertionIndex(in: array, for: frame)
        guard idx < array.count && array[idx].frame == frame else { return nil }
        return array[idx]
    }

    // MARK: - Private helpers

    /// Returns the index at which `frame` should be inserted to maintain ascending order.
    /// Uses binary search — O(log n).
    private func insertionIndex(in array: [Keyframe], for frame: Int) -> Int {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if array[mid].frame < frame {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
