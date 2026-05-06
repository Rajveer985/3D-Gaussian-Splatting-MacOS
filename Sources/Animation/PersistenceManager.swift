import Foundation

// MARK: - Codable Document Types

/// The root serializable type for a `.gsanim` file.
struct AnimationDocument: Codable {
    var version:    Int = 1
    var startFrame: Int
    var endFrame:   Int
    var fps:        Int
    var tracks:     [AnimationTrack]
}

/// One property's keyframe sequence within an AnimationDocument.
struct AnimationTrack: Codable {
    var property:  AnimatableProperty
    var keyframes: [Keyframe]
}

// MARK: - Error Types

/// Typed errors thrown by PersistenceManager.load(from:).
enum AnimationLoadError: LocalizedError {
    case fileNotFound
    case malformedJSON(underlying: Error)
    case invalidVersion(Int)
    case invalidTimelineConfiguration(String)
    case invalidKeyframeData(property: AnimatableProperty, frame: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "The animation file could not be found."
        case .malformedJSON(let underlying):
            return "The animation file contains malformed JSON: \(underlying.localizedDescription)"
        case .invalidVersion(let v):
            return "Unsupported animation file version: \(v). Expected version 1."
        case .invalidTimelineConfiguration(let reason):
            return "Invalid timeline configuration: \(reason)"
        case .invalidKeyframeData(let property, let frame, let reason):
            return "Invalid keyframe data for property '\(property.rawValue)' at frame \(frame): \(reason)"
        }
    }
}

// MARK: - PersistenceManager

/// Handles serialization and deserialization of animation data to/from `.gsanim` JSON files.
enum PersistenceManager {

    // MARK: - Save

    /// Serializes an AnimationDocument to a JSON `.gsanim` file at the given URL.
    /// - Throws: Any file-system or encoding error.
    static func save(_ document: AnimationDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Load

    /// Deserializes a `.gsanim` file into an AnimationDocument.
    /// - Throws: `AnimationLoadError` if the file is missing, malformed, or contains invalid data.
    static func load(from url: URL) throws -> AnimationDocument {
        // Read raw data
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AnimationLoadError.fileNotFound
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AnimationLoadError.malformedJSON(underlying: error)
        }

        // Decode JSON
        let document: AnimationDocument
        do {
            document = try JSONDecoder().decode(AnimationDocument.self, from: data)
        } catch {
            throw AnimationLoadError.malformedJSON(underlying: error)
        }

        // Validate version
        guard document.version == 1 else {
            throw AnimationLoadError.invalidVersion(document.version)
        }

        // Validate timeline configuration
        guard Timeline.validFPS.contains(document.fps) else {
            throw AnimationLoadError.invalidTimelineConfiguration(
                "fps must be one of {24, 30, 60}, got \(document.fps)"
            )
        }
        guard document.endFrame > document.startFrame else {
            throw AnimationLoadError.invalidTimelineConfiguration(
                "endFrame (\(document.endFrame)) must be greater than startFrame (\(document.startFrame))"
            )
        }
        guard document.endFrame <= Timeline.maxFrames else {
            throw AnimationLoadError.invalidTimelineConfiguration(
                "endFrame (\(document.endFrame)) exceeds maximum of \(Timeline.maxFrames)"
            )
        }
        guard document.startFrame >= 0 else {
            throw AnimationLoadError.invalidTimelineConfiguration(
                "startFrame (\(document.startFrame)) must be >= 0"
            )
        }

        // Validate keyframe data
        for track in document.tracks {
            for keyframe in track.keyframes {
                if keyframe.value.isNaN {
                    throw AnimationLoadError.invalidKeyframeData(
                        property: track.property,
                        frame: keyframe.frame,
                        reason: "value is NaN"
                    )
                }
                if keyframe.value.isInfinite {
                    throw AnimationLoadError.invalidKeyframeData(
                        property: track.property,
                        frame: keyframe.frame,
                        reason: "value is infinite"
                    )
                }
                if let handle = keyframe.bezierHandle {
                    if handle.inTangent.x.isNaN || handle.inTangent.y.isNaN ||
                       handle.outTangent.x.isNaN || handle.outTangent.y.isNaN {
                        throw AnimationLoadError.invalidKeyframeData(
                            property: track.property,
                            frame: keyframe.frame,
                            reason: "bezierHandle contains NaN"
                        )
                    }
                }
            }
        }

        return document
    }
}
