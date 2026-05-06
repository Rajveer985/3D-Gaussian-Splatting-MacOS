import SwiftUI

/// Horizontal ruler showing frame numbers at zoom-appropriate intervals.
struct TimelineRuler: View {
    let startFrame: Int
    let endFrame: Int
    let zoomScale: CGFloat      // pixels per frame
    let scrollOffset: CGFloat   // leftmost visible frame (in frames)

    /// Height of the ruler.
    static let height: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                // Background
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(NSColor.controlBackgroundColor))
                )

                // Determine tick interval based on zoom
                let interval = tickInterval(zoomScale: zoomScale)

                // First visible frame (rounded down to nearest interval)
                let firstFrame = Int(scrollOffset / zoomScale)
                let firstTick = (firstFrame / interval) * interval

                var frame = firstTick
                while frame <= endFrame {
                    let x = (CGFloat(frame) - scrollOffset) * zoomScale
                    guard x >= 0 && x <= size.width else {
                        frame += interval
                        continue
                    }

                    // Tick mark
                    let tickHeight: CGFloat = frame % (interval * 5) == 0 ? 10 : 5
                    var tickPath = Path()
                    tickPath.move(to: CGPoint(x: x, y: size.height))
                    tickPath.addLine(to: CGPoint(x: x, y: size.height - tickHeight))
                    context.stroke(tickPath, with: .color(.secondary.opacity(0.6)), lineWidth: 1)

                    // Label — only on major ticks
                    if frame % (interval * 5) == 0 || interval <= 5 {
                        let label = "\(frame)"
                        context.draw(
                            Text(label)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary),
                            at: CGPoint(x: x + 2, y: size.height - tickHeight - 8),
                            anchor: .leading
                        )
                    }

                    frame += interval
                }

                // Bottom border
                var borderPath = Path()
                borderPath.move(to: CGPoint(x: 0, y: size.height - 0.5))
                borderPath.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                context.stroke(borderPath, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            }
        }
        .frame(height: TimelineRuler.height)
    }

    /// Returns the frame interval between ruler ticks based on the current zoom level.
    private func tickInterval(zoomScale: CGFloat) -> Int {
        // Target: at least ~40px between ticks
        let minPixelsBetweenTicks: CGFloat = 40
        let framesPerPixel = 1.0 / zoomScale
        let rawInterval = Double(minPixelsBetweenTicks) * Double(framesPerPixel)

        // Round up to a "nice" interval
        let niceIntervals = [1, 2, 5, 10, 20, 30, 50, 100, 200, 300, 500, 1000]
        return niceIntervals.first { Double($0) >= rawInterval } ?? 1000
    }
}
