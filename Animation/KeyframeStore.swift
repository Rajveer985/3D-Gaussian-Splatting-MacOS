import Foundation
import Combine

final class KeyframeStore: ObservableObject {
    @Published private(set) var keyframes: [AnimatableProperty: [Keyframe]] = [:]

    func set(_ keyframe: Keyframe, for property: AnimatableProperty) {
        var array = keyframes[property] ?? []
        let idx = insertionIndex(in: array, for: keyframe.frame)
        if idx < array.count && array[idx].frame == keyframe.frame {
            array[idx] = keyframe
        } else {
            array.insert(keyframe, at: idx)
        }
        keyframes[property] = array
    }

    func delete(frame: Int, for property: AnimatableProperty) {
        guard var array = keyframes[property] else { return }
        let idx = insertionIndex(in: array, for: frame)
        guard idx < array.count && array[idx].frame == frame else { return }
        array.remove(at: idx)
        keyframes[property] = array
    }

    func deleteAll(for property: AnimatableProperty) {
        keyframes[property] = []
    }

    func deleteAll(at frame: Int) {
        for property in AnimatableProperty.allCases {
            delete(frame: frame, for: property)
        }
    }

    func clearAll() {
        keyframes = [:]
    }

    func move(keyframeID: UUID, for property: AnimatableProperty, toFrame newFrame: Int) {
        guard var array = keyframes[property],
              let oldIdx = array.firstIndex(where: { $0.id == keyframeID }) else { return }
        var keyframe = array[oldIdx]
        array.remove(at: oldIdx)
        keyframe.frame = newFrame
        let targetIdx = insertionIndex(in: array, for: newFrame)
        if targetIdx < array.count && array[targetIdx].frame == newFrame {
            array[targetIdx] = keyframe
        } else {
            array.insert(keyframe, at: targetIdx)
        }
        keyframes[property] = array
    }

    func keyframes(for property: AnimatableProperty) -> [Keyframe] {
        keyframes[property] ?? []
    }

    func hasKeyframe(at frame: Int, for property: AnimatableProperty) -> Bool {
        guard let array = keyframes[property] else { return false }
        let idx = insertionIndex(in: array, for: frame)
        return idx < array.count && array[idx].frame == frame
    }

    func keyframe(at frame: Int, for property: AnimatableProperty) -> Keyframe? {
        guard let array = keyframes[property] else { return nil }
        let idx = insertionIndex(in: array, for: frame)
        guard idx < array.count && array[idx].frame == frame else { return nil }
        return array[idx]
    }

    private func insertionIndex(in array: [Keyframe], for frame: Int) -> Int {
        var lo = 0, hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if array[mid].frame < frame { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
