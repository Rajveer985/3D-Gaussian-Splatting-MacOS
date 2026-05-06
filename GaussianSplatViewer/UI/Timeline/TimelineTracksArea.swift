import SwiftUI

struct TimelineTracksArea: View {
    @ObservedObject var animationSystem: AnimationSystem
    @Binding var zoomScale:          CGFloat
    @Binding var scrollOffset:       CGFloat
    @Binding var selectedKeyframeID: UUID?

    private var timeline: Timeline      { animationSystem.timeline }
    private var store:    KeyframeStore { animationSystem.store }

    private var activeProperties: [AnimatableProperty] {
        AnimatableProperty.allCases.filter { !store.keyframes(for: $0).isEmpty }
    }

    // All properties shown (active ones + all for set-keyframe buttons)
    private var allProperties: [AnimatableProperty] { AnimatableProperty.allCases }

    private var tracksHeight: CGFloat {
        CGFloat(allProperties.count) * PropertyTrackRow.rowHeight
    }

    var body: some View {
        GeometryReader { geo in
            let trackW = geo.size.width - PropertyTrackRow.labelWidth - 10

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    // Ruler
                    HStack(spacing: 0) {
                        Spacer().frame(width: PropertyTrackRow.labelWidth + 10)
                        TimelineRuler(
                            startFrame: timeline.startFrame,
                            endFrame: timeline.endFrame,
                            zoomScale: zoomScale,
                            scrollOffset: scrollOffset
                        )
                    }

                    // One row per property (always show all 8)
                    ForEach(allProperties, id: \.self) { prop in
                        PropertyTrackRow(
                            property: prop,
                            keyframes: store.keyframes(for: prop),
                            zoomScale: zoomScale,
                            scrollOffset: scrollOffset,
                            selectedID: selectedKeyframeID,
                            onKeyframeTapped: { id in
                                selectedKeyframeID = (selectedKeyframeID == id) ? nil : id
                            },
                            onKeyframeDragged: { id, f in
                                store.move(keyframeID: id, for: prop, toFrame: f)
                            },
                            onSetKeyframe: {
                                animationSystem.setKeyframe(for: prop)
                            }
                        )
                    }
                }

                // Scrubber overlay
                ScrubberLine(
                    currentFrame: animationSystem.currentFrame,
                    zoomScale: zoomScale,
                    scrollOffset: scrollOffset,
                    totalHeight: TimelineRuler.height + tracksHeight,
                    onScrub: { animationSystem.scrub(to: $0) }
                )
                .padding(.leading, PropertyTrackRow.labelWidth + 10)
                .frame(width: trackW, height: TimelineRuler.height + tracksHeight)
            }
        }
        // Pinch to zoom
        .gesture(MagnificationGesture().onChanged { s in
            zoomScale = max(0.5, min(30, zoomScale * s))
        })
        // Horizontal scroll (two-finger drag on trackpad)
        .onScrollGestureChanged(scrollOffset: $scrollOffset, zoomScale: zoomScale)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private extension View {
    func onScrollGestureChanged(scrollOffset: Binding<CGFloat>, zoomScale: CGFloat) -> some View {
        self.gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { v in
                    let delta = -v.translation.width / zoomScale
                    scrollOffset.wrappedValue = max(0, scrollOffset.wrappedValue + delta)
                }
        )
    }
}
