import SwiftUI

struct TimelineRuler: View {
    let startFrame:   Int
    let endFrame:     Int
    let zoomScale:    CGFloat
    let scrollOffset: CGFloat

    static let height: CGFloat = 22

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(NSColor.controlBackgroundColor)))

            let interval = tickInterval()
            let firstFrame = Int(scrollOffset / zoomScale)
            let firstTick  = (firstFrame / max(1, interval)) * interval

            var frame = firstTick
            while frame <= endFrame {
                let x = (CGFloat(frame) - scrollOffset) * zoomScale
                guard x >= 0 && x <= size.width else { frame += interval; continue }

                let isMajor = frame % (interval * 5) == 0 || interval <= 5
                let tickH: CGFloat = isMajor ? 9 : 5
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x, y: size.height - tickH))
                context.stroke(p, with: .color(.secondary.opacity(0.5)), lineWidth: 1)

                if isMajor {
                    context.draw(
                        Text("\(frame)").font(.system(size: 8)).foregroundColor(.secondary),
                        at: CGPoint(x: x + 2, y: size.height - tickH - 7),
                        anchor: .topLeading
                    )
                }
                frame += interval
            }

            var border = Path()
            border.move(to: CGPoint(x: 0, y: size.height - 0.5))
            border.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(border, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
        }
        .frame(height: TimelineRuler.height)
    }

    private func tickInterval() -> Int {
        let raw = 40.0 / Double(zoomScale)
        let nice = [1,2,5,10,20,30,50,100,200,300,500,1000]
        return nice.first { Double($0) >= raw } ?? 1000
    }
}
