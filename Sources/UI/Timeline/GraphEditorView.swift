import SwiftUI

/// Displays the value-over-time curve for one AnimatableProperty with Bezier handle editing.
struct GraphEditorView: View {
    @ObservedObject var animationSystem: AnimationSystem
    let property: AnimatableProperty
    let selectedKeyframeID: UUID?

    // Padding around the curve area
    private let padding: CGFloat = 20

    // Which handle is being dragged: (keyframeID, isInTangent)
    @State private var draggingHandle: (UUID, Bool)? = nil

    private var store: KeyframeStore { animationSystem.store }
    private var timeline: Timeline { animationSystem.timeline }
    private var keyframes: [Keyframe] { store.keyframes(for: property) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let (minVal, maxVal) = valueRange()

            ZStack {
                // Background
                Color(NSColor.controlBackgroundColor)

                Canvas { context, canvasSize in
                    drawGrid(context: context, size: canvasSize, minVal: minVal, maxVal: maxVal)
                    drawCurve(context: context, size: canvasSize, minVal: minVal, maxVal: maxVal)
                    drawKeyframeDots(context: context, size: canvasSize, minVal: minVal, maxVal: maxVal)
                    drawBezierHandles(context: context, size: canvasSize, minVal: minVal, maxVal: maxVal)
                }

                // Drag gesture for handle editing
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                handleHandleDrag(value, size: size, minVal: minVal, maxVal: maxVal)
                            }
                            .onEnded { _ in
                                draggingHandle = nil
                            }
                    )
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Coordinate Mapping

    private func frameToX(_ frame: Double, width: CGFloat) -> CGFloat {
        let start = Double(timeline.startFrame)
        let end   = Double(timeline.endFrame)
        guard end > start else { return padding }
        return padding + CGFloat((frame - start) / (end - start)) * (width - 2 * padding)
    }

    private func valueToY(_ value: Float, height: CGFloat, minVal: Float, maxVal: Float) -> CGFloat {
        let range = maxVal - minVal
        guard range > 0 else { return height / 2 }
        let normalized = CGFloat((value - minVal) / range)
        // Flip: higher values at top
        return padding + (1.0 - normalized) * (height - 2 * padding)
    }

    private func xToFrame(_ x: CGFloat, width: CGFloat) -> Double {
        let start = Double(timeline.startFrame)
        let end   = Double(timeline.endFrame)
        let t = Double((x - padding) / (width - 2 * padding))
        return start + t * (end - start)
    }

    private func yToValue(_ y: CGFloat, height: CGFloat, minVal: Float, maxVal: Float) -> Float {
        let range = maxVal - minVal
        let normalized = Float(1.0 - (y - padding) / (height - 2 * padding))
        return minVal + normalized * range
    }

    // MARK: - Value Range

    private func valueRange() -> (Float, Float) {
        guard !keyframes.isEmpty else { return (-1, 1) }
        let values = keyframes.map { $0.value }
        var minV = values.min()!
        var maxV = values.max()!
        let margin = max((maxV - minV) * 0.2, 0.1)
        minV -= margin
        maxV += margin
        return (minV, maxV)
    }

    // MARK: - Drawing

    private func drawGrid(context: GraphicsContext, size: CGSize, minVal: Float, maxVal: Float) {
        let gridColor = Color.secondary.opacity(0.15)
        let labelColor = Color.secondary.opacity(0.6)

        // Horizontal grid lines (value axis)
        let valueStep = niceStep(range: Double(maxVal - minVal), targetLines: 5)
        var v = (Double(minVal) / valueStep).rounded(.up) * valueStep
        while v <= Double(maxVal) {
            let y = valueToY(Float(v), height: size.height, minVal: minVal, maxVal: maxVal)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: 1)

            // Value label
            context.draw(
                Text(String(format: "%.2f", v))
                    .font(.system(size: 9))
                    .foregroundColor(labelColor),
                at: CGPoint(x: 2, y: y - 6),
                anchor: .topLeading
            )
            v += valueStep
        }

        // Vertical grid lines (frame axis)
        let frameRange = Double(timeline.endFrame - timeline.startFrame)
        let frameStep = niceStep(range: frameRange, targetLines: 8)
        var f = (Double(timeline.startFrame) / frameStep).rounded(.up) * frameStep
        while f <= Double(timeline.endFrame) {
            let x = frameToX(f, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(gridColor), lineWidth: 1)

            context.draw(
                Text("\(Int(f))")
                    .font(.system(size: 9))
                    .foregroundColor(labelColor),
                at: CGPoint(x: x + 2, y: size.height - 12),
                anchor: .topLeading
            )
            f += frameStep
        }
    }

    private func drawCurve(context: GraphicsContext, size: CGSize, minVal: Float, maxVal: Float) {
        guard keyframes.count >= 2 else { return }

        var path = Path()
        var first = true

        // Sample every 2 pixels
        let steps = Int(size.width / 2)
        for i in 0...steps {
            let x = CGFloat(i) * 2
            let frame = xToFrame(x, width: size.width)
            let value = InterpolationEngine.evaluate(at: frame, keyframes: keyframes)
            let y = valueToY(value, height: size.height, minVal: minVal, maxVal: maxVal)
            let pt = CGPoint(x: x, y: y)
            if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
        }

        context.stroke(path, with: .color(Color.accentColor), lineWidth: 1.5)
    }

    private func drawKeyframeDots(context: GraphicsContext, size: CGSize, minVal: Float, maxVal: Float) {
        for kf in keyframes {
            let x = frameToX(Double(kf.frame), width: size.width)
            let y = valueToY(kf.value, height: size.height, minVal: minVal, maxVal: maxVal)
            let isSelected = kf.id == selectedKeyframeID
            let dotRect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: dotRect), with: .color(isSelected ? .yellow : .white))
            context.stroke(Path(ellipseIn: dotRect), with: .color(Color.accentColor), lineWidth: 1.5)
        }
    }

    private func drawBezierHandles(context: GraphicsContext, size: CGSize, minVal: Float, maxVal: Float) {
        for kf in keyframes {
            guard kf.interpolationMode == .bezier, let handle = kf.bezierHandle else { continue }

            let kfX = frameToX(Double(kf.frame), width: size.width)
            let kfY = valueToY(kf.value, height: size.height, minVal: minVal, maxVal: maxVal)

            // In-tangent handle
            let inX = kfX + CGFloat(handle.inTangent.x) * (size.width / CGFloat(timeline.endFrame - timeline.startFrame))
            let inY = kfY - CGFloat(handle.inTangent.y) * (size.height / CGFloat(maxVal - minVal))
            drawHandle(context: context, from: CGPoint(x: kfX, y: kfY), to: CGPoint(x: inX, y: inY))

            // Out-tangent handle
            let outX = kfX + CGFloat(handle.outTangent.x) * (size.width / CGFloat(timeline.endFrame - timeline.startFrame))
            let outY = kfY - CGFloat(handle.outTangent.y) * (size.height / CGFloat(maxVal - minVal))
            drawHandle(context: context, from: CGPoint(x: kfX, y: kfY), to: CGPoint(x: outX, y: outY))
        }
    }

    private func drawHandle(context: GraphicsContext, from: CGPoint, to: CGPoint) {
        var linePath = Path()
        linePath.move(to: from)
        linePath.addLine(to: to)
        context.stroke(linePath, with: .color(Color.yellow.opacity(0.7)), lineWidth: 1)

        let dotRect = CGRect(x: to.x - 4, y: to.y - 4, width: 8, height: 8)
        context.fill(Path(ellipseIn: dotRect), with: .color(Color.yellow.opacity(0.9)))
        context.stroke(Path(ellipseIn: dotRect), with: .color(Color.orange), lineWidth: 1)
    }

    // MARK: - Handle Drag

    private func handleHandleDrag(_ value: DragGesture.Value, size: CGSize, minVal: Float, maxVal: Float) {
        let loc = value.location

        // On drag start, hit-test which handle is closest
        if draggingHandle == nil {
            let hitRadius: CGFloat = 10
            for kf in keyframes {
                guard kf.interpolationMode == .bezier, let handle = kf.bezierHandle else { continue }
                let kfX = frameToX(Double(kf.frame), width: size.width)
                let kfY = valueToY(kf.value, height: size.height, minVal: minVal, maxVal: maxVal)
                let frameScale = size.width / CGFloat(timeline.endFrame - timeline.startFrame)
                let valueScale = size.height / CGFloat(maxVal - minVal)

                let inPt = CGPoint(
                    x: kfX + CGFloat(handle.inTangent.x) * frameScale,
                    y: kfY - CGFloat(handle.inTangent.y) * valueScale
                )
                let outPt = CGPoint(
                    x: kfX + CGFloat(handle.outTangent.x) * frameScale,
                    y: kfY - CGFloat(handle.outTangent.y) * valueScale
                )

                if hypot(loc.x - inPt.x, loc.y - inPt.y) < hitRadius {
                    draggingHandle = (kf.id, true)
                    break
                }
                if hypot(loc.x - outPt.x, loc.y - outPt.y) < hitRadius {
                    draggingHandle = (kf.id, false)
                    break
                }
            }
        }

        guard let (dragID, isIn) = draggingHandle,
              let kfIdx = keyframes.firstIndex(where: { $0.id == dragID }) else { return }

        let kf = keyframes[kfIdx]
        let kfX = frameToX(Double(kf.frame), width: size.width)
        let kfY = valueToY(kf.value, height: size.height, minVal: minVal, maxVal: maxVal)
        let frameScale = size.width / CGFloat(timeline.endFrame - timeline.startFrame)
        let valueScale = size.height / CGFloat(maxVal - minVal)

        let deltaX = Float((loc.x - kfX) / frameScale)
        let deltaY = Float(-(loc.y - kfY) / valueScale)
        let newTangent = SIMD2<Float>(deltaX, deltaY)

        var updatedHandle = kf.bezierHandle ?? BezierHandle(
            inTangent: .zero,
            outTangent: .zero
        )
        if isIn {
            updatedHandle.inTangent = newTangent
        } else {
            updatedHandle.outTangent = newTangent
        }

        var updatedKF = kf
        updatedKF.bezierHandle = updatedHandle
        store.set(updatedKF, for: property)
    }

    // MARK: - Helpers

    private func niceStep(range: Double, targetLines: Int) -> Double {
        guard range > 0 else { return 1 }
        let rawStep = range / Double(targetLines)
        let magnitude = pow(10.0, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let nice: Double
        if normalized < 1.5 { nice = 1 }
        else if normalized < 3.5 { nice = 2 }
        else if normalized < 7.5 { nice = 5 }
        else { nice = 10 }
        return nice * magnitude
    }
}
