import SwiftUI

struct GraphEditorView: View {
    @ObservedObject var animationSystem: AnimationSystem
    let property:           AnimatableProperty
    let selectedKeyframeID: UUID?

    private let pad: CGFloat = 18
    @State private var draggingHandle: (UUID, Bool)? = nil

    private var store:     KeyframeStore { animationSystem.store }
    private var timeline:  Timeline      { animationSystem.timeline }
    private var keyframes: [Keyframe]    { store.keyframes(for: property) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let (minV, maxV) = valueRange()
            ZStack {
                Color(NSColor.controlBackgroundColor)
                Canvas { ctx, sz in
                    drawGrid(ctx, sz, minV, maxV)
                    drawCurve(ctx, sz, minV, maxV)
                    drawDots(ctx, sz, minV, maxV)
                    drawHandles(ctx, sz, minV, maxV)
                }
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in handleDrag(v, size: size, minV: minV, maxV: maxV) }
                        .onEnded   { _ in draggingHandle = nil })
            }
        }
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    // MARK: Coordinate helpers
    private func fx(_ f: Double, w: CGFloat) -> CGFloat {
        let s = Double(timeline.startFrame), e = Double(timeline.endFrame)
        guard e > s else { return pad }
        return pad + CGFloat((f - s) / (e - s)) * (w - 2*pad)
    }
    private func vy(_ v: Float, h: CGFloat, lo: Float, hi: Float) -> CGFloat {
        let r = hi - lo; guard r > 0 else { return h/2 }
        return pad + CGFloat(1 - (v - lo) / r) * (h - 2*pad)
    }
    private func xf(_ x: CGFloat, w: CGFloat) -> Double {
        let s = Double(timeline.startFrame), e = Double(timeline.endFrame)
        return s + Double((x - pad) / (w - 2*pad)) * (e - s)
    }
    private func yv(_ y: CGFloat, h: CGFloat, lo: Float, hi: Float) -> Float {
        Float(1 - (y - pad) / (h - 2*pad)) * (hi - lo) + lo
    }

    private func valueRange() -> (Float, Float) {
        guard !keyframes.isEmpty else { return (-1, 1) }
        let vals = keyframes.map { $0.value }
        let mn = vals.min()!, mx = vals.max()!
        let m = max((mx - mn) * 0.2, 0.1)
        return (mn - m, mx + m)
    }

    // MARK: Drawing
    private func drawGrid(_ ctx: GraphicsContext, _ sz: CGSize, _ lo: Float, _ hi: Float) {
        let gc = Color.secondary.opacity(0.12)
        let step = niceStep(range: Double(hi - lo), n: 5)
        var v = (Double(lo) / step).rounded(.up) * step
        while v <= Double(hi) {
            let y = vy(Float(v), h: sz.height, lo: lo, hi: hi)
            var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: sz.width, y: y))
            ctx.stroke(p, with: .color(gc), lineWidth: 1)
            ctx.draw(Text(String(format: "%.2f", v)).font(.system(size: 8)).foregroundColor(.secondary),
                     at: CGPoint(x: 2, y: y - 5), anchor: .topLeading)
            v += step
        }
        let fs = niceStep(range: Double(timeline.endFrame - timeline.startFrame), n: 8)
        var f = (Double(timeline.startFrame) / fs).rounded(.up) * fs
        while f <= Double(timeline.endFrame) {
            let x = fx(f, w: sz.width)
            var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: sz.height))
            ctx.stroke(p, with: .color(gc), lineWidth: 1)
            ctx.draw(Text("\(Int(f))").font(.system(size: 8)).foregroundColor(.secondary),
                     at: CGPoint(x: x + 2, y: sz.height - 11), anchor: .topLeading)
            f += fs
        }
    }

    private func drawCurve(_ ctx: GraphicsContext, _ sz: CGSize, _ lo: Float, _ hi: Float) {
        guard keyframes.count >= 2 else { return }
        var path = Path(); var first = true
        let steps = Int(sz.width / 2)
        for i in 0...steps {
            let x = CGFloat(i) * 2
            let val = InterpolationEngine.evaluate(at: xf(x, w: sz.width), keyframes: keyframes)
            let y = vy(val, h: sz.height, lo: lo, hi: hi)
            let pt = CGPoint(x: x, y: y)
            if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
        }
        ctx.stroke(path, with: .color(Color.accentColor), lineWidth: 1.5)
    }

    private func drawDots(_ ctx: GraphicsContext, _ sz: CGSize, _ lo: Float, _ hi: Float) {
        for kf in keyframes {
            let x = fx(Double(kf.frame), w: sz.width)
            let y = vy(kf.value, h: sz.height, lo: lo, hi: hi)
            let r = CGRect(x: x-4, y: y-4, width: 8, height: 8)
            ctx.fill(Path(ellipseIn: r), with: .color(kf.id == selectedKeyframeID ? .yellow : .white))
            ctx.stroke(Path(ellipseIn: r), with: .color(Color.accentColor), lineWidth: 1.5)
        }
    }

    private func drawHandles(_ ctx: GraphicsContext, _ sz: CGSize, _ lo: Float, _ hi: Float) {
        let fw = sz.width / CGFloat(timeline.endFrame - timeline.startFrame)
        let fh = sz.height / CGFloat(hi - lo)
        for kf in keyframes {
            guard kf.interpolationMode == .bezier, let h = kf.bezierHandle else { continue }
            let kx = fx(Double(kf.frame), w: sz.width)
            let ky = vy(kf.value, h: sz.height, lo: lo, hi: hi)
            for (tang, _) in [(h.inTangent, true), (h.outTangent, false)] {
                let tx = kx + CGFloat(tang.x) * fw
                let ty = ky - CGFloat(tang.y) * fh
                var line = Path(); line.move(to: CGPoint(x: kx, y: ky)); line.addLine(to: CGPoint(x: tx, y: ty))
                ctx.stroke(line, with: .color(Color.yellow.opacity(0.7)), lineWidth: 1)
                let dr = CGRect(x: tx-4, y: ty-4, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: dr), with: .color(Color.yellow.opacity(0.9)))
                ctx.stroke(Path(ellipseIn: dr), with: .color(Color.orange), lineWidth: 1)
            }
        }
    }

    private func handleDrag(_ v: DragGesture.Value, size: CGSize, minV: Float, maxV: Float) {
        let loc = v.location
        let fw = size.width / CGFloat(timeline.endFrame - timeline.startFrame)
        let fh = size.height / CGFloat(maxV - minV)
        if draggingHandle == nil {
            for kf in keyframes {
                guard kf.interpolationMode == .bezier, let h = kf.bezierHandle else { continue }
                let kx = fx(Double(kf.frame), w: size.width)
                let ky = vy(kf.value, h: size.height, lo: minV, hi: maxV)
                let inPt  = CGPoint(x: kx + CGFloat(h.inTangent.x)*fw,  y: ky - CGFloat(h.inTangent.y)*fh)
                let outPt = CGPoint(x: kx + CGFloat(h.outTangent.x)*fw, y: ky - CGFloat(h.outTangent.y)*fh)
                if hypot(loc.x - inPt.x,  loc.y - inPt.y)  < 10 { draggingHandle = (kf.id, true);  break }
                if hypot(loc.x - outPt.x, loc.y - outPt.y) < 10 { draggingHandle = (kf.id, false); break }
            }
        }
        guard let (id, isIn) = draggingHandle,
              let kf = keyframes.first(where: { $0.id == id }) else { return }
        let kx = fx(Double(kf.frame), w: size.width)
        let ky = vy(kf.value, h: size.height, lo: minV, hi: maxV)
        let dx = Float((loc.x - kx) / fw), dy = Float(-(loc.y - ky) / fh)
        var upd = kf.bezierHandle ?? BezierHandle(inTangent: .zero, outTangent: .zero)
        if isIn { upd.inTangent = SIMD2(dx, dy) } else { upd.outTangent = SIMD2(dx, dy) }
        var updKF = kf; updKF.bezierHandle = upd
        store.set(updKF, for: property)
    }

    private func niceStep(range: Double, n: Int) -> Double {
        guard range > 0 else { return 1 }
        let raw = range / Double(n)
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let nice: Double = norm < 1.5 ? 1 : norm < 3.5 ? 2 : norm < 7.5 ? 5 : 10
        return nice * mag
    }
}
