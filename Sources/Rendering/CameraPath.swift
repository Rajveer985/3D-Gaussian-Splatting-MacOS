import Foundation
import simd
import QuartzCore

struct CameraKeyframe: Codable, Equatable {
    var position: float3
    var target: float3
    var azimuth: Float
    var elevation: Float
    var distance: Float
    var timestamp: TimeInterval
    
    init(
        position: float3 = float3(0, 0, 5),
        target: float3 = .zero,
        azimuth: Float = 0,
        elevation: Float = 0,
        distance: Float = 5,
        timestamp: TimeInterval = 0
    ) {
        self.position = position
        self.target = target
        self.azimuth = azimuth
        self.elevation = elevation
        self.distance = distance
        self.timestamp = timestamp
    }
    
    init(camera: Camera) {
        self.position = camera.position
        self.target = camera.target
        self.azimuth = camera.azimuth
        self.elevation = camera.elevation
        self.distance = camera.distance
        self.timestamp = CACurrentMediaTime()
    }
    
    func interpolate(to other: CameraKeyframe, t: Float) -> CameraKeyframe {
        let clampedT = max(0, min(1, t))
        return CameraKeyframe(
            position: position + (other.position - position) * clampedT,
            target: target + (other.target - target) * clampedT,
            azimuth: azimuth + (other.azimuth - azimuth) * clampedT,
            elevation: elevation + (other.elevation - elevation) * clampedT,
            distance: distance + (other.distance - distance) * clampedT,
            timestamp: timestamp + (other.timestamp - timestamp) * TimeInterval(clampedT)
        )
    }
}

class CameraPath: ObservableObject {
    @Published var keyframes: [CameraKeyframe] = []
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var loopEnabled: Bool = true
    @Published var playbackSpeed: Float = 1.0
    
    var duration: TimeInterval {
        guard let first = keyframes.first, let last = keyframes.last else { return 0 }
        return last.timestamp - first.timestamp
    }
    
    var totalKeyframes: Int { keyframes.count }
    
    func addKeyframe(_ keyframe: CameraKeyframe) {
        keyframes.append(keyframe)
        keyframes.sort { $0.timestamp < $1.timestamp }
    }
    
    func addKeyframe(from camera: Camera) {
        let keyframe = CameraKeyframe(camera: camera)
        addKeyframe(keyframe)
    }
    
    func removeKeyframe(at index: Int) {
        guard index >= 0 && index < keyframes.count else { return }
        keyframes.remove(at: index)
    }
    
    func clearKeyframes() {
        keyframes.removeAll()
        currentTime = 0
    }
    
    func getInterpolatedKeyframe(at time: TimeInterval) -> CameraKeyframe? {
        guard keyframes.count >= 2 else {
            return keyframes.first
        }
        
        let normalizedTime = loopEnabled 
            ? time.truncatingRemainder(dividingBy: duration)
            : min(time, duration)
        
        var prevKeyframe = keyframes[0]
        var nextKeyframe = keyframes[0]
        
        for i in 0..<keyframes.count - 1 {
            if normalizedTime >= keyframes[i].timestamp && normalizedTime < keyframes[i + 1].timestamp {
                prevKeyframe = keyframes[i]
                nextKeyframe = keyframes[i + 1]
                break
            }
        }
        
        if normalizedTime >= keyframes.last!.timestamp {
            prevKeyframe = keyframes[keyframes.count - 1]
            nextKeyframe = keyframes[0]
        }
        
        let t: Float
        if nextKeyframe.timestamp != prevKeyframe.timestamp {
            t = Float((normalizedTime - prevKeyframe.timestamp) / (nextKeyframe.timestamp - prevKeyframe.timestamp))
        } else {
            t = 0
        }
        
        return prevKeyframe.interpolate(to: nextKeyframe, t: t)
    }
    
    func applyTo(camera: Camera, at time: TimeInterval) {
        guard let keyframe = getInterpolatedKeyframe(at: time) else { return }
        
        camera.target = keyframe.target
        camera.distance = keyframe.distance
        camera.azimuth = keyframe.azimuth
        camera.elevation = keyframe.elevation
        camera.updateMatrices()
    }
    
    func saveToFile(url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(keyframes)
        try data.write(to: url)
    }
    
    func loadFromFile(url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        keyframes = try decoder.decode([CameraKeyframe].self, from: data)
    }
}