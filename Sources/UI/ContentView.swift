import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ViewModel()
    @State private var isFilePickerPresented = false
    @State private var showTimeline = false
    @State private var isSaveAnimationPresented = false
    @State private var isLoadAnimationPresented = false
    @State private var animationErrorMessage: String? = nil
    @State private var showAnimationError = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button("Open PLY File...") {
                    isFilePickerPresented = true
                }
                .buttonStyle(.borderedProminent)

                Divider().frame(height: 20)

                // Timeline toggle
                Button(action: { showTimeline.toggle() }) {
                    Label("Timeline", systemImage: "film")
                        .foregroundColor(showTimeline ? .accentColor : .primary)
                }
                .buttonStyle(.borderless)
                .help("Toggle Timeline")
                .disabled(viewModel.animationSystem == nil)

                // Save / Load animation
                if viewModel.animationSystem != nil {
                    Button(action: { isSaveAnimationPresented = true }) {
                        Label("Save Animation…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help("Save animation to .gsanim file")

                    Button(action: { isLoadAnimationPresented = true }) {
                        Label("Load Animation…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Load animation from .gsanim file")
                }

                Spacer()

                // File info
                VStack(alignment: .trailing, spacing: 4) {
                    Text(viewModel.fileName)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if viewModel.splatCount > 0 {
                        Text("\(viewModel.splatCount.formatted()) splats")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Viewport
            ZStack {
                ViewportView(viewModel: viewModel)
                    .background(Color.black)

                if viewModel.isLoading {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading...")
                            .padding(.top)
                    }
                    .padding(40)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                }

                // Instructions overlay
                if viewModel.splatCount == 0 && !viewModel.isLoading {
                    VStack(spacing: 12) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        Text("Gaussian Splat Viewer")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Open a .ply file to view 3D Gaussian Splatting scenes")
                            .foregroundColor(.secondary)

                        HStack(spacing: 20) {
                            VStack {
                                Image(systemName: "hand.draw")
                                    .font(.title2)
                                Text("Left drag: Rotate")
                                    .font(.caption)
                            }
                            VStack {
                                Image(systemName: "hand.tap")
                                    .font(.title2)
                                Text("Right drag: Pan")
                                    .font(.caption)
                            }
                            VStack {
                                Image(systemName: "arrow.up.and.down")
                                    .font(.title2)
                                Text("Scroll: Zoom")
                                    .font(.caption)
                            }
                        }
                        .padding(.top)
                        .foregroundColor(.secondary)
                    }
                    .padding(40)
                }
            }

            // Timeline panel (collapsible)
            if showTimeline, let animSystem = viewModel.animationSystem {
                Divider()
                TimelineView(animationSystem: animSystem)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        // PLY file picker
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    if url.startAccessingSecurityScopedResource() {
                        viewModel.loadFile(from: url)
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            case .failure(let error):
                print("File picker error: \(error)")
            }
        }
        // Save animation panel
        .fileExporter(
            isPresented: $isSaveAnimationPresented,
            document: AnimationFileDocument(animationSystem: viewModel.animationSystem),
            contentType: .gsanim,
            defaultFilename: "animation"
        ) { result in
            if case .failure(let error) = result {
                animationErrorMessage = error.localizedDescription
                showAnimationError = true
            }
        }
        // Load animation panel
        .fileImporter(
            isPresented: $isLoadAnimationPresented,
            allowedContentTypes: [.gsanim, .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let animSystem = viewModel.animationSystem else { return }
                do {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        try animSystem.load(from: url)
                    }
                } catch {
                    animationErrorMessage = error.localizedDescription
                    showAnimationError = true
                }
            case .failure(let error):
                animationErrorMessage = error.localizedDescription
                showAnimationError = true
            }
        }
        .alert("Animation Error", isPresented: $showAnimationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(animationErrorMessage ?? "An unknown error occurred.")
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
