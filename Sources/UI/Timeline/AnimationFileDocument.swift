import SwiftUI
import UniformTypeIdentifiers

// MARK: - UTType for .gsanim
// Using a tag-based UTType that doesn't require Info.plist registration.
// The file extension ".gsanim" is used for identification.

extension UTType {
    /// UTType for `.gsanim` animation files, identified by file extension.
    static let gsanim = UTType(filenameExtension: "gsanim") ?? .json
}

// MARK: - FileDocument wrapper for fileExporter

/// A `FileDocument` wrapper that serializes the current AnimationSystem state.
struct AnimationFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.gsanim, .json] }
    static var writableContentTypes: [UTType] { [.gsanim] }

    private let animationSystem: AnimationSystem?

    init(animationSystem: AnimationSystem?) {
        self.animationSystem = animationSystem
    }

    init(configuration: ReadConfiguration) throws {
        // Not used for saving — load is handled via fileImporter
        self.animationSystem = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let animSystem = animationSystem else {
            throw CocoaError(.fileWriteUnknown)
        }

        let tracks = AnimatableProperty.allCases.compactMap { property -> AnimationTrack? in
            let keyframes = animSystem.store.keyframes(for: property)
            guard !keyframes.isEmpty else { return nil }
            return AnimationTrack(property: property, keyframes: keyframes)
        }
        let document = AnimationDocument(
            version:    1,
            startFrame: animSystem.timeline.startFrame,
            endFrame:   animSystem.timeline.endFrame,
            fps:        animSystem.timeline.fps,
            tracks:     tracks
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        return FileWrapper(regularFileWithContents: data)
    }
}
