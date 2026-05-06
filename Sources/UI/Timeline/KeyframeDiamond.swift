import SwiftUI

/// Diamond-shaped keyframe marker, draggable horizontally.
struct KeyframeDiamond: View {
    let keyframe: Keyframe
    let zoomScale: CGFloat
    let scrollOffset: CGFloat
    var onTap: () -> Void
    var onDrag: (Int) -> Void   // new frame number

    @State private var isDragging = false
    @State private var dragStartX: CGFloat = 0
    @State private var dragStartFrame: Int = 0

    private let size: CGFloat = 10

    /// Pixel x-position of this keyframe.
    private var xPosition: CGFloat {
        (CGFloat(keyframe.frame) - scrollOffset) * zoomScale
    }

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.yellow : Color.accentColor)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
            .position(x: xPosition, y: 0)   // y is managed by the parent track row
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartX = value.startLocation.x
                            dragStartFrame = keyframe.frame
                        }
                        let deltaX = value.location.x - dragStartX
                        let deltaFrames = Int((deltaX / zoomScale).rounded())
                        let newFrame = max(0, dragStartFrame + deltaFrames)
                        onDrag(newFrame)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onTapGesture {
                onTap()
            }
    }
}
