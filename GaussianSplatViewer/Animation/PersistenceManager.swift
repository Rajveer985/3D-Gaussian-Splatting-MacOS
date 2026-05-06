import Foundation

struct AnimationDocument: Codable {
    var version:    Int = 1
    var startFrame: Int
    var endFrame:   Int
    var fps:        Int
    var tracks:     [AnimationTrack]
}

struct AnimationTrack: Codable {
    var property:  AnimatableProperty
    var keyframes: [Keyframe]
}

enum AnimationLoadError: LocalizedError {
    case fileNotFound
    case malformedJSON(underlying: Error)
    case invalidVersion(Int)
    case invalidTimelineConfiguration(String)
    case invalidKeyframeData(property: AnimatableProperty, frame: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:                          return "Animation file not found."
        case .malformedJSON(let e):                  return "Malformed JSON: \(e.localizedDescription)"
        case .invalidVersion(let v):                 return "Unsupported version: \(v). Expected 1."
        case .invalidTimelineConfiguration(let r):   return "Invalid timeline: \(r)"
        case .invalidKeyframeData(let p, let f, let r): return "Bad keyframe '\(p.rawValue)' @\(f): \(r)"
        }
    }
}

enum PersistenceManager {
    static func save(_ document: AnimationDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> AnimationDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AnimationLoadError.fileNotFound
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw AnimationLoadError.malformedJSON(underlying: error) }

        let doc: AnimationDocument
        do { doc = try JSONDecoder().decode(AnimationDocument.self, from: data) }
        catch { throw AnimationLoadError.malformedJSON(underlying: error) }

        guard doc.version == 1 else { throw AnimationLoadError.invalidVersion(doc.version) }
        guard Timeline.validFPS.contains(doc.fps) else {
            throw AnimationLoadError.invalidTimelineConfiguration("fps must be 24/30/60, got \(doc.fps)")
        }
        guard doc.endFrame > doc.startFrame else {
            throw AnimationLoadError.invalidTimelineConfiguration("endFrame must be > startFrame")
        }
        guard doc.endFrame <= Timeline.maxFrames else {
            throw AnimationLoadError.invalidTimelineConfiguration("endFrame exceeds \(Timeline.maxFrames)")
        }
        for track in doc.tracks {
            for kf in track.keyframes {
                if kf.value.isNaN || kf.value.isInfinite {
                    throw AnimationLoadError.invalidKeyframeData(property: track.property, frame: kf.frame, reason: "value is NaN/Inf")
                }
            }
        }
        return doc
    }
}
