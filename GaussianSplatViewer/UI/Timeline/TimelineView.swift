import SwiftUI

struct TimelineView: View {
    @ObservedObject var animationSystem: AnimationSystem

    @State private var zoomScale:          CGFloat = 4.0
    @State private var scrollOffset:       CGFloat = 0
    @State private var selectedKeyframeID: UUID?   = nil
    @State private var showGraphEditor:    Bool    = false

    private var store: KeyframeStore { animationSystem.store }

    /// The property and keyframe currently selected.
    private var selectedInfo: (AnimatableProperty, Keyframe)? {
        guard let id = selectedKeyframeID else { return nil }
        for prop in AnimatableProperty.allCases {
            if let kf = store.keyframes(for: prop).first(where: { $0.id == id }) {
                return (prop, kf)
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PlaybackControlsBar(animationSystem: animationSystem)

            Divider()

            // Keyframe inspector (shown when a keyframe is selected)
            if let (prop, kf) = selectedInfo {
                KeyframeInspectorBar(
                    property: prop,
                    keyframe: kf,
                    onInterpolationChange: { newMode in
                        var updated = kf
                        updated.interpolationMode = newMode
                        if newMode == .bezier && updated.bezierHandle == nil {
                            let kfs = store.keyframes(for: prop)
                            if let idx = kfs.firstIndex(where: { $0.id == kf.id }) {
                                let prev = idx > 0 ? kfs[idx - 1] : nil
                                let next = idx < kfs.count - 1 ? kfs[idx + 1] : nil
                                updated.bezierHandle = BezierHandle.autoTangent(prev: prev, current: updated, next: next)
                            }
                        }
                        store.set(updated, for: prop)
                    },
                    onDelete: {
                        store.delete(frame: kf.frame, for: prop)
                        selectedKeyframeID = nil
                    }
                )
                Divider()
            }

            TimelineTracksArea(
                animationSystem: animationSystem,
                zoomScale: $zoomScale,
                scrollOffset: $scrollOffset,
                selectedKeyframeID: $selectedKeyframeID
            )

            // Graph editor for bezier keyframes
            if showGraphEditor, let (prop, _) = selectedInfo {
                Divider()
                GraphEditorView(
                    animationSystem: animationSystem,
                    property: prop,
                    selectedKeyframeID: selectedKeyframeID
                )
                .frame(height: 180)
            }
        }
        .frame(height: frameHeight)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: selectedKeyframeID) { id in
            guard let (_, kf) = selectedInfo else { showGraphEditor = false; return }
            if kf.interpolationMode == .bezier { showGraphEditor = true }
        }
    }

    private var frameHeight: CGFloat {
        var h: CGFloat = 160  // controls + tracks
        if selectedInfo != nil { h += 30 }  // inspector bar
        if showGraphEditor { h += 190 }     // graph editor + divider
        return h
    }
}

// MARK: - Keyframe Inspector Bar

struct KeyframeInspectorBar: View {
    let property:              AnimatableProperty
    let keyframe:              Keyframe
    var onInterpolationChange: (InterpolationMode) -> Void
    var onDelete:              () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Property + frame info
            Text("\(property.displayName)  @  frame \(keyframe.frame)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary)

            Text(String(format: "value: %.3f", keyframe.value))
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)

            Divider().frame(height: 14)

            // Interpolation mode picker
            Text("Interp:").font(.system(size: 10)).foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { keyframe.interpolationMode },
                set: { onInterpolationChange($0) }
            )) {
                Text("Linear").tag(InterpolationMode.linear)
                Text("Ease In").tag(InterpolationMode.easeIn)
                Text("Ease Out").tag(InterpolationMode.easeOut)
                Text("Ease In/Out").tag(InterpolationMode.easeInOut)
                Text("Bezier").tag(InterpolationMode.bezier)
                Text("Constant").tag(InterpolationMode.constant)
            }
            .pickerStyle(.menu)
            .frame(width: 110)
            .font(.system(size: 10))

            Divider().frame(height: 14)

            // Delete this keyframe
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete this keyframe")

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.08))
    }
}
