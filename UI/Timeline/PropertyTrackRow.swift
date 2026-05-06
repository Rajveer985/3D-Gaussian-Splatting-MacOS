import SwiftUI

struct PropertyTrackRow: View {
    let property:          AnimatableProperty
    let keyframes:         [Keyframe]
    let zoomScale:         CGFloat
    let scrollOffset:      CGFloat
    var onKeyframeTapped:  (UUID) -> Void
    var onKeyframeDragged: (UUID, Int) -> Void

    static let labelWidth: CGFloat = 72
    static let rowHeight:  CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            Text(property.displayName)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
                .padding(.trailing, 6)

            ZStack(alignment: .leading) {
                Color(NSColor.controlBackgroundColor).opacity(0.4)
                ForEach(keyframes) { kf in
                    KeyframeDiamond(
                        keyframe: kf,
                        zoomScale: zoomScale,
                        scrollOffset: scrollOffset,
                        onTap:  { onKeyframeTapped(kf.id) },
                        onDrag: { newFrame in onKeyframeDragged(kf.id, newFrame) }
                    )
                    .frame(height: Self.rowHeight)
                }
            }
            .frame(height: Self.rowHeight)
            .clipped()
        }
        .frame(height: Self.rowHeight)
        .overlay(Rectangle().fill(Color.secondary.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }
}
