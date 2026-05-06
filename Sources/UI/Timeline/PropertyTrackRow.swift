import SwiftUI

/// One horizontal row for a single AnimatableProperty, showing its keyframe diamonds.
struct PropertyTrackRow: View {
    let property: AnimatableProperty
    let keyframes: [Keyframe]
    let zoomScale: CGFloat
    let scrollOffset: CGFloat
    var onKeyframeTapped: (UUID) -> Void
    var onKeyframeDragged: (UUID, Int) -> Void

    static let labelWidth: CGFloat = 80
    static let rowHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: 0) {
            // Property label
            Text(property.displayName)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
                .padding(.trailing, 8)

            // Track area with keyframe diamonds
            ZStack(alignment: .leading) {
                // Track background
                Rectangle()
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))

                // Alternating row tint
                Rectangle()
                    .fill(Color.primary.opacity(0.03))

                // Keyframe diamonds
                ForEach(keyframes) { keyframe in
                    KeyframeDiamond(
                        keyframe: keyframe,
                        zoomScale: zoomScale,
                        scrollOffset: scrollOffset,
                        onTap: { onKeyframeTapped(keyframe.id) },
                        onDrag: { newFrame in onKeyframeDragged(keyframe.id, newFrame) }
                    )
                    .frame(height: Self.rowHeight)
                }
            }
            .frame(height: Self.rowHeight)
            .clipped()
        }
        .frame(height: Self.rowHeight)
        .overlay(
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
