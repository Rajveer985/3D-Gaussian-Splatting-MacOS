import SwiftUI

struct PropertyTrackRow: View {
    let property:          AnimatableProperty
    let keyframes:         [Keyframe]
    let zoomScale:         CGFloat
    let scrollOffset:      CGFloat
    let selectedID:        UUID?
    var onKeyframeTapped:  (UUID) -> Void
    var onKeyframeDragged: (UUID, Int) -> Void
    var onSetKeyframe:     () -> Void

    static let labelWidth: CGFloat = 80
    static let rowHeight:  CGFloat = 24
    private let diamondSize: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            // Label + set-keyframe button
            HStack(spacing: 4) {
                Text(property.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Button(action: onSetKeyframe) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 7))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Set keyframe for \(property.displayName) at current frame")
            }
            .frame(width: Self.labelWidth)
            .padding(.trailing, 4)

            // Track area — drawn with GeometryReader so we know exact width
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track background
                    Rectangle()
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.3))

                    // Keyframe diamonds
                    ForEach(keyframes) { kf in
                        let x = (CGFloat(kf.frame) - scrollOffset) * zoomScale
                        if x >= -diamondSize && x <= geo.size.width + diamondSize {
                            DraggableDiamond(
                                keyframe: kf,
                                x: x,
                                midY: geo.size.height / 2,
                                size: diamondSize,
                                isSelected: kf.id == selectedID,
                                zoomScale: zoomScale,
                                onTap: { onKeyframeTapped(kf.id) },
                                onDrag: { newFrame in onKeyframeDragged(kf.id, newFrame) }
                            )
                        }
                    }
                }
                .clipped()
            }
            .frame(height: Self.rowHeight)
        }
        .frame(height: Self.rowHeight)
        .overlay(Rectangle().fill(Color.secondary.opacity(0.1)).frame(height: 1), alignment: .bottom)
    }
}

/// A single draggable diamond marker positioned absolutely within the track.
private struct DraggableDiamond: View {
    let keyframe:   Keyframe
    let x:          CGFloat
    let midY:       CGFloat
    let size:       CGFloat
    let isSelected: Bool
    let zoomScale:  CGFloat
    var onTap:  () -> Void
    var onDrag: (Int) -> Void

    @State private var dragging = false
    @State private var startX:     CGFloat = 0
    @State private var startFrame: Int     = 0

    var body: some View {
        Rectangle()
            .fill(isSelected ? Color.yellow : Color.accentColor)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
            .position(x: x, y: midY)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            startX = v.startLocation.x
                            startFrame = keyframe.frame
                        }
                        let delta = Int(((v.location.x - startX) / zoomScale).rounded())
                        onDrag(max(0, startFrame + delta))
                    }
                    .onEnded { _ in dragging = false }
            )
            .onTapGesture { onTap() }
    }
}
