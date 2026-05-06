import SwiftUI

struct ScrubberLine: View {
    let currentFrame: Int
    let zoomScale:    CGFloat
    let scrollOffset: CGFloat
    let totalHeight:  CGFloat
    var onScrub: (Int) -> Void

    @State private var isDragging      = false
    @State private var dragStartX:     CGFloat = 0
    @State private var dragStartFrame: Int     = 0

    private var xPos: CGFloat {
        (CGFloat(currentFrame) - scrollOffset) * zoomScale
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !isDragging {
                                isDragging = true
                                dragStartX = v.startLocation.x
                                dragStartFrame = currentFrame
                            }
                            let delta = Int(((v.location.x - dragStartX) / zoomScale).rounded())
                            onScrub(max(0, dragStartFrame + delta))
                        }
                        .onEnded { _ in isDragging = false }
                )

            Path { p in
                p.move(to: CGPoint(x: xPos, y: 0))
                p.addLine(to: CGPoint(x: xPos, y: totalHeight))
            }
            .stroke(Color.red.opacity(0.85), lineWidth: 1.5)

            Path { p in
                let h: CGFloat = 7
                p.move(to: CGPoint(x: xPos - h/2, y: 0))
                p.addLine(to: CGPoint(x: xPos + h/2, y: 0))
                p.addLine(to: CGPoint(x: xPos, y: h))
                p.closeSubpath()
            }
            .fill(Color.red)
        }
    }
}
