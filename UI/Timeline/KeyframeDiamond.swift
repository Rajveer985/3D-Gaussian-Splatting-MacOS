import SwiftUI

struct KeyframeDiamond: View {
    let keyframe:     Keyframe
    let zoomScale:    CGFloat
    let scrollOffset: CGFloat
    var onTap:  () -> Void
    var onDrag: (Int) -> Void

    @State private var isDragging     = false
    @State private var dragStartX:    CGFloat = 0
    @State private var dragStartFrame: Int    = 0

    private let size: CGFloat = 9

    private var xPos: CGFloat {
        (CGFloat(keyframe.frame) - scrollOffset) * zoomScale
    }

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.yellow : Color.accentColor)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
            .position(x: xPos, y: 0)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if !isDragging {
                            isDragging = true
                            dragStartX = v.startLocation.x
                            dragStartFrame = keyframe.frame
                        }
                        let delta = Int(((v.location.x - dragStartX) / zoomScale).rounded())
                        onDrag(max(0, dragStartFrame + delta))
                    }
                    .onEnded { _ in isDragging = false }
            )
            .onTapGesture { onTap() }
    }
}
