import SwiftUI

struct TimelineTracksArea: View {
    @ObservedObject var animationSystem: AnimationSystem
    @Binding var zoomScale:          CGFloat
    @Binding var scrollOffset:       CGFloat
    @Binding var selectedKeyframeID: UUID?

    private var timeline: Timeline   { animationSystem.timeline }
    private var store:    KeyframeStore { animationSystem.store }

    private var activeProperties: [AnimatableProperty] {
        AnimatableProperty.allCases.filter { !store.keyframes(for: $0).isEmpty }
    }

    private var tracksHeight: CGFloat {
        CGFloat(max(1, activeProperties.count)) * PropertyTrackRow.rowHeight
    }

    var body: some View {
        GeometryReader { geo in
            let trackW = geo.size.width - PropertyTrackRow.labelWidth - 6

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer().frame(width: PropertyTrackRow.labelWidth + 6)
                        TimelineRuler(startFrame: timeline.startFrame, endFrame: timeline.endFrame,
                                      zoomScale: zoomScale, scrollOffset: scrollOffset)
                    }

                    if activeProperties.isEmpty {
                        HStack {
                            Spacer().frame(width: PropertyTrackRow.labelWidth + 6)
                            Text("No keyframes — set a keyframe to begin")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                    } else {
                        ForEach(activeProperties, id: \.self) { prop in
                            PropertyTrackRow(
                                property: prop,
                                keyframes: store.keyframes(for: prop),
                                zoomScale: zoomScale,
                                scrollOffset: scrollOffset,
                                onKeyframeTapped:  { id in selectedKeyframeID = id },
                                onKeyframeDragged: { id, f in store.move(keyframeID: id, for: prop, toFrame: f) }
                            )
                        }
                    }
                }

                ScrubberLine(
                    currentFrame: animationSystem.currentFrame,
                    zoomScale: zoomScale,
                    scrollOffset: scrollOffset,
                    totalHeight: TimelineRuler.height + tracksHeight,
                    onScrub: { animationSystem.scrub(to: $0) }
                )
                .padding(.leading, PropertyTrackRow.labelWidth + 6)
                .frame(width: trackW, height: TimelineRuler.height + tracksHeight)
            }
        }
        .gesture(MagnificationGesture().onChanged { s in
            zoomScale = max(0.5, min(20, zoomScale * s))
        })
        .gesture(DragGesture(minimumDistance: 5).onChanged { v in
            scrollOffset = max(0, scrollOffset - v.translation.width / zoomScale)
        })
        .background(Color(NSColor.windowBackgroundColor))
    }
}
