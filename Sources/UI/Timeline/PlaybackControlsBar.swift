import SwiftUI

/// Transport controls bar: play/pause/stop/loop, frame counter, time display, FPS selector, range inputs.
struct PlaybackControlsBar: View {
    @ObservedObject var animationSystem: AnimationSystem

    // Local state for text field editing
    @State private var startFrameText: String = ""
    @State private var endFrameText: String = ""

    private var engine: PlaybackEngine { animationSystem.engine }
    private var timeline: Timeline { animationSystem.timeline }

    var body: some View {
        HStack(spacing: 12) {

            // MARK: Transport buttons
            HStack(spacing: 6) {
                // Stop
                Button(action: { engine.stop() }) {
                    Image(systemName: "stop.fill")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Stop")

                // Play / Pause toggle
                Button(action: {
                    if engine.isPlaying { engine.pause() } else { engine.play() }
                }) {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help(engine.isPlaying ? "Pause" : "Play")

                // Loop toggle
                Button(action: { engine.loopEnabled.toggle() }) {
                    Image(systemName: "repeat")
                        .frame(width: 20, height: 20)
                        .foregroundColor(engine.loopEnabled ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Loop")
            }

            Divider().frame(height: 20)

            // MARK: Frame counter
            HStack(spacing: 4) {
                Text(String(format: "%03d", animationSystem.currentFrame))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                Text("/")
                    .foregroundColor(.secondary)
                Text("\(timeline.endFrame)")
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 12))

            // MARK: Time display (MM:SS:FF)
            Text(timeline.timeString(for: animationSystem.currentFrame))
                .monospacedDigit()
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Divider().frame(height: 20)

            // MARK: FPS segmented control
            HStack(spacing: 0) {
                ForEach([24, 30, 60], id: \.self) { fps in
                    Button(action: { timeline.setFPS(fps) }) {
                        Text("\(fps)")
                            .font(.system(size: 11))
                            .frame(width: 30, height: 20)
                            .background(timeline.fps == fps ? Color.accentColor.opacity(0.2) : Color.clear)
                            .cornerRadius(3)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
            )

            Divider().frame(height: 20)

            // MARK: Start / End frame inputs
            HStack(spacing: 6) {
                Text("Start:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("", text: $startFrameText)
                    .frame(width: 44)
                    .font(.system(size: 11).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { startFrameText = "\(timeline.startFrame)" }
                    .onSubmit {
                        if let v = Int(startFrameText) {
                            if !timeline.setStartFrame(v) {
                                startFrameText = "\(timeline.startFrame)"
                            }
                        } else {
                            startFrameText = "\(timeline.startFrame)"
                        }
                    }

                Text("End:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("", text: $endFrameText)
                    .frame(width: 44)
                    .font(.system(size: 11).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { endFrameText = "\(timeline.endFrame)" }
                    .onSubmit {
                        if let v = Int(endFrameText) {
                            if !timeline.setEndFrame(v) {
                                endFrameText = "\(timeline.endFrame)"
                            }
                        } else {
                            endFrameText = "\(timeline.endFrame)"
                        }
                    }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
