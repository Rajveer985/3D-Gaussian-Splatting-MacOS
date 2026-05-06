import SwiftUI

/// Scrollable area containing the ruler, per-property track rows, and the scrubber overlay.
struct TimelineTracksArea: View {
    @ObservedObject var animationSystem: AnimationSystem
    @Binding var zoomScale: CGFloat
    @Binding var scrollOffset: CGFloat
    @Binding var selectedKeyframeID: UUID?

    private var timeline: Timeline { animationSystem.timeline }
    private var store: KeyframeStore { animationSystem.store }

    /// Properties that have at least one keyframe.
    private var activeProperties: [AnimatableProperty] {
        AnimatableProperty.allCases.filter { !store.keyframes(for: $0).isEmpty }
    }

    /// Total height of all track rows.
    private var tracksHeight: CGFloat {
        CGFloat(max(1, activeProperties.count)) * PropertyTrackRow.rowHeight
    }

    var body: some View {
        GeometryReader { geo in
            let trackAreaWidth = geo.size.width - PropertyTrackRow.labelWidth - 8

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    // Ruler (offset by label column width)
                    HStack(spacing: 0) {
                        Spacer().frame(width: PropertyTrackRow.labelWidth + 8)
                        TimelineRuler(
                            startFrame: timeline.startFrame,
                            endFrame: timeline.endFrame,
                            zoomScale: zoomScale,
                            scrollOffset: scrollOffset
                        )
                    }

                    // Track rows
                    if activeProperties.isEmpty {
                        HStack {
                            Spacer().frame(width: PropertyTrackRow.labelWidth + 8)
                            Text("No keyframes yet — set a keyframe to begin")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                    } else {
                        ForEach(activeProperties, id: \.self) { property in
                            PropertyTrackRow(
                                property: property,
                                keyframes: store.keyframes(for: property),
                                zoomScale: zoomScale,
                                scrollOffset: scrollOffset,
                                onKeyframeTapped: { id in
                                    selectedKeyframeID = id
                                },
                                onKeyframeDragged: { id, newFrame in
                                    store.move(keyframeID: id, for: property, toFrame: newFrame)
                                }
                            )
                        }
                    }
                }

                // Scrubber overlay (sits on top of ruler + tracks)
                ScrubberLine(
                    currentFrame: animationSystem.currentFrame,
                    zoomScale: zoomScale,
                    scrollOffset: scrollOffset,
                    totalHeight: TimelineRuler.height + tracksHeight,
                    onScrub: { frame in
                        animationSystem.scrub(to: frame)
                    }
                )
                .padding(.leading, PropertyTrackRow.labelWidth + 8)
                .frame(width: trackAreaWidth, height: TimelineRuler.height + tracksHeight)
            }
        }
        // Pinch-to-zoom
        .gesture(
            MagnificationGesture()
                .onChanged { scale in
                    let newZoom = max(0.5, min(20.0, zoomScale * scale))
                    zoomScale = newZoom
                }
        )
        // Horizontal scroll
        .onScrollGestureChanged(scrollOffset: $scrollOffset, zoomScale: zoomScale)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Scroll helper

private extension View {
    /// Attaches a horizontal scroll gesture that updates scrollOffset (in frames).
    func onScrollGestureChanged(scrollOffset: Binding<CGFloat>, zoomScale: CGFloat) -> some View {
        self.gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    let deltaFrames = -value.translation.width / zoomScale
                    scrollOffset.wrappedValue = max(0, scrollOffset.wrappedValue + deltaFrames)
                }
        )
    }
}
