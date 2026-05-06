import SwiftUI

struct PlaybackControlsBar: View {
    @ObservedObject var animationSystem: AnimationSystem
    @State private var startFrameText = ""
    @State private var endFrameText   = ""

    private var engine:   PlaybackEngine { animationSystem.engine }
    private var timeline: Timeline       { animationSystem.timeline }

    var body: some View {
        HStack(spacing: 8) {

            // MARK: Transport
            HStack(spacing: 4) {
                Button(action: { engine.stop() }) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop")

                Button(action: { engine.isPlaying ? engine.pause() : engine.play() }) {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(engine.isPlaying ? "Pause" : "Play")

                Button(action: { engine.loopEnabled.toggle() }) {
                    Image(systemName: "repeat")
                        .foregroundColor(engine.loopEnabled ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Loop")
            }

            Divider().frame(height: 18)

            // MARK: Frame counter + time
            HStack(spacing: 3) {
                Text(String(format: "%03d", animationSystem.currentFrame))
                    .monospacedDigit()
                Text("/").foregroundColor(.secondary)
                Text("\(timeline.endFrame)").monospacedDigit().foregroundColor(.secondary)
            }
            .font(.system(size: 11))

            Text(timeline.timeString(for: animationSystem.currentFrame))
                .monospacedDigit()
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Divider().frame(height: 18)

            // MARK: Keyframe buttons
            HStack(spacing: 4) {
                // Set keyframe for ALL properties at current frame
                Button(action: { animationSystem.setAllKeyframes() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 9))
                        Text("Set All")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Set keyframes for all camera properties at current frame")

                // Delete all keyframes at current frame
                Button(action: { animationSystem.deleteAllKeyframesAtCurrentFrame() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "diamond")
                            .font(.system(size: 9))
                        Text("Del Frame")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete all keyframes at current frame")

                // Clear all keyframes
                Button(action: { animationSystem.clearAllKeyframes() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                        Text("Clear All")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundColor(.red)
                .help("Remove all keyframes")
            }

            Divider().frame(height: 18)

            // MARK: FPS
            HStack(spacing: 0) {
                ForEach([24, 30, 60], id: \.self) { fps in
                    Button(action: { timeline.setFPS(fps) }) {
                        Text("\(fps)")
                            .font(.system(size: 10))
                            .frame(width: 28, height: 18)
                            .background(timeline.fps == fps ? Color.accentColor.opacity(0.25) : Color.clear)
                            .cornerRadius(3)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35), lineWidth: 1))

            Divider().frame(height: 18)

            // MARK: Start / End frame
            HStack(spacing: 4) {
                Text("Start:").font(.system(size: 10)).foregroundColor(.secondary)
                TextField("", text: $startFrameText)
                    .frame(width: 40).font(.system(size: 10).monospacedDigit())
                    .multilineTextAlignment(.center).textFieldStyle(.roundedBorder)
                    .onAppear { startFrameText = "\(timeline.startFrame)" }
                    .onSubmit {
                        if let v = Int(startFrameText), !timeline.setStartFrame(v) {
                            startFrameText = "\(timeline.startFrame)"
                        }
                    }
                Text("End:").font(.system(size: 10)).foregroundColor(.secondary)
                TextField("", text: $endFrameText)
                    .frame(width: 40).font(.system(size: 10).monospacedDigit())
                    .multilineTextAlignment(.center).textFieldStyle(.roundedBorder)
                    .onAppear { endFrameText = "\(timeline.endFrame)" }
                    .onSubmit {
                        if let v = Int(endFrameText), !timeline.setEndFrame(v) {
                            endFrameText = "\(timeline.endFrame)"
                        }
                    }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
