import SwiftUI

/// A selected keyframe reference used to drive the graph editor.
struct SelectedKeyframe: Equatable {
    let id: UUID
    let property: AnimatableProperty
}

/// Root timeline panel — collapsible, docked below the viewport.
struct TimelineView: View {
    @ObservedObject var animationSystem: AnimationSystem

    @State private var zoomScale: CGFloat = 4.0       // pixels per frame
    @State private var scrollOffset: CGFloat = 0       // leftmost visible frame (in frames)
    @State private var selectedKeyframeID: UUID? = nil
    @State private var showGraphEditor: Bool = false

    /// The property whose graph editor is shown (derived from selectedKeyframeID).
    private var selectedProperty: AnimatableProperty? {
        guard let id = selectedKeyframeID else { return nil }
        return AnimatableProperty.allCases.first { property in
            animationSystem.store.keyframes(for: property).contains { $0.id == id }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PlaybackControlsBar(animationSystem: animationSystem)

            Divider()

            TimelineTracksArea(
                animationSystem: animationSystem,
                zoomScale: $zoomScale,
                scrollOffset: $scrollOffset,
                selectedKeyframeID: $selectedKeyframeID
            )

            // Show graph editor when a bezier keyframe is selected
            if showGraphEditor, let property = selectedProperty {
                Divider()
                GraphEditorView(
                    animationSystem: animationSystem,
                    property: property,
                    selectedKeyframeID: selectedKeyframeID
                )
                .frame(height: 180)
            }
        }
        .frame(height: showGraphEditor ? 340 : 160)
        .onChange(of: selectedKeyframeID) { id in
            // Auto-show graph editor when a bezier keyframe is selected
            if let id = id,
               let property = selectedProperty,
               let kf = animationSystem.store.keyframe(at: animationSystem.currentFrame, for: property) ?? {
                   animationSystem.store.keyframes(for: property).first { $0.id == id }
               }(),
               kf.interpolationMode == .bezier {
                showGraphEditor = true
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}
