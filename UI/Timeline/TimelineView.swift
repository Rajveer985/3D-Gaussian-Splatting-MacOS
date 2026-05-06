import SwiftUI

struct TimelineView: View {
    @ObservedObject var animationSystem: AnimationSystem

    @State private var zoomScale:          CGFloat = 4.0
    @State private var scrollOffset:       CGFloat = 0
    @State private var selectedKeyframeID: UUID?   = nil
    @State private var showGraphEditor:    Bool    = false

    private var selectedProperty: AnimatableProperty? {
        guard let id = selectedKeyframeID else { return nil }
        return AnimatableProperty.allCases.first { prop in
            animationSystem.store.keyframes(for: prop).contains { $0.id == id }
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
            if showGraphEditor, let prop = selectedProperty {
                Divider()
                GraphEditorView(
                    animationSystem: animationSystem,
                    property: prop,
                    selectedKeyframeID: selectedKeyframeID
                )
                .frame(height: 180)
            }
        }
        .frame(height: showGraphEditor ? 340 : 160)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: selectedKeyframeID) { id in
            guard let id, let prop = selectedProperty,
                  let kf = animationSystem.store.keyframes(for: prop).first(where: { $0.id == id }),
                  kf.interpolationMode == .bezier else { return }
            showGraphEditor = true
        }
    }
}
