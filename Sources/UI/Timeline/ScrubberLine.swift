import SwiftUI

/// Vertical playhead line spanning all tracks, draggable to scrub.
struct ScrubberLine: View {
    let currentFrame: Int
    let zoomScale: CGFloat
    let scrollOffset: CGFloat
    let totalHeight: CGFloat
    var onScrub: (Int) -> Void

    @State private var isDragging = false
    @State private var dragStartX: CGFloat = 0
    @State private var dragStartFrame: Int = 0

    /// Pixel x-position of the scrubber.
    private var xPosition: CGFloat {
        (CGFloat(currentFrame) - scrollOffset) * zoomScale
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Invisible hit area for dragging
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStartX = value.startLocation.x
                                dragStartFrame = currentFrame
                            }
                            let deltaX = value.location.x - dragStartX
                            let deltaFrames = Int((deltaX / zoomScale).rounded())
                            let newFrame = max(0, dragStartFrame + deltaFrames)
                            onScrub(newFrame)
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )

            // Scrubber line
            Path { path in
                path.move(to: CGPoint(x: xPosition, y: 0))
                path.addLine(to: CGPoint(x: xPosition, y: totalHeight))
            }
            .stroke(Color.red.opacity(0.85), lineWidth: 1.5)

            // Scrubber head (triangle/handle at top)
            Path { path in
                let headSize: CGFloat = 7
                path.move(to: CGPoint(x: xPosition - headSize / 2, y: 0))
                path.addLine(to: CGPoint(x: xPosition + headSize / 2, y: 0))
                path.addLine(to: CGPoint(x: xPosition, y: headSize))
                path.closeSubpath()
            }
            .fill(Color.red)
        }
        .allowsHitTesting(true)
    }
}
