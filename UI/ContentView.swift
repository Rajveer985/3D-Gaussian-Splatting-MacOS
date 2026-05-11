import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = ViewModel()
    @State private var isFilePickerPresented = false
    @State private var transformMode: TransformMode = .none
    @State private var showPropertiesPanel = false
    @State private var showTimeline = false
    @State private var isSaveAnimPresented = false
    @State private var isLoadAnimPresented = false
    @State private var animErrorMsg: String?
    @State private var showAnimError = false
    
    // Splat settings (bidirectionally synced with renderer)
    @State private var scaleMultiplier: Double = 1.0
    @State private var opacityMultiplier: Double = 1.0
    @State private var gaussianSharpness: Double = 1.0
    @State private var saturation: Double = 1.0
    @State private var nearClip: Double = 0.01
    @State private var farClip: Double = 1000.0
    @State private var minOpacityCutoff: Double = 1.0 / 255.0
    @State private var shDegreeOverride: Int = -1
    @State private var bgColor: Color = Color(red: 0.1, green: 0.1, blue: 0.1)
    @State private var covRegularization: Double = -1.0
    @State private var covRegEnabled: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button("Open PLY File...") {
                    isFilePickerPresented = true
                }
                .buttonStyle(.borderedProminent)
                
                if viewModel.splatCount > 0 {
                    Divider()
                        .frame(height: 20)
                    
                    HStack(spacing: 4) {
                        transformButton("Move", icon: "arrow.up.and.down.and.arrow.left.and.right", mode: .translate, help: "Move scene (drag to translate)")
                        transformButton("Rotate", icon: "rotate.3d", mode: .rotate, help: "Rotate scene (drag to rotate)")
                        transformButton("Scale", icon: "arrow.up.left.and.arrow.down.right", mode: .scale, help: "Scale scene (drag up/down to resize)")
                        
                        Divider()
                            .frame(height: 20)
                        
                        Button("Reset") {
                            viewModel.renderer?.resetSceneTransform()
                            transformMode = .none
                            viewModel.renderer?.activeTransformMode = .none
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reset scene transform")
                    }
                    
                    Divider()
                        .frame(height: 20)
                    
                    // Properties panel toggle
                    if showPropertiesPanel {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showPropertiesPanel.toggle()
                            }
                        } label: {
                            Label("Properties", systemImage: "slider.horizontal.3")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Toggle splat properties panel")
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showPropertiesPanel.toggle()
                            }
                        } label: {
                            Label("Properties", systemImage: "slider.horizontal.3")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Toggle splat properties panel")
                    }

                    Divider().frame(height: 20)

                    // Timeline toggle
                    if showTimeline {
                        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showTimeline.toggle() } }) {
                            Label("Timeline", systemImage: "film")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Toggle animation timeline")
                    } else {
                        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showTimeline.toggle() } }) {
                            Label("Timeline", systemImage: "film")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Toggle animation timeline")
                    }

                    // Save / Load animation
                    Button(action: { isSaveAnimPresented = true }) {
                        Label("Save Anim", systemImage: "square.and.arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Save animation (.gsanim)")

                    Button(action: { isLoadAnimPresented = true }) {
                        Label("Load Anim", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Load animation (.gsanim)")
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
            
            // Main content area
            HStack(spacing: 0) {
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
                    
                    if let loadError = viewModel.loadError, !viewModel.isLoading {
                        VStack(spacing: 8) {
                            Text("Unable to Display File")
                                .font(.headline)
                            Text(loadError)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(20)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                    }
                    
                    // Instructions overlay
                    if viewModel.splatCount == 0 && !viewModel.isLoading && viewModel.loadError == nil {
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
                
                // Properties side panel
                if showPropertiesPanel && viewModel.splatCount > 0 {
                    Divider()
                    
                    propertiesPanel
                        .frame(width: 280)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            // Timeline panel — shown when toggled
            if showTimeline, let animSystem = viewModel.animationSystem {
                Divider()
                TimelineView(animationSystem: animSystem)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        // PLY file picker
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [UTType(filenameExtension: "ply") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { viewModel.loadFile(from: url) }
            case .failure(let error):
                print("File picker error: \(error)")
            }
        }
        // Save animation
        .onChange(of: isSaveAnimPresented) { show in
            guard show else { return }
            isSaveAnimPresented = false
            guard let anim = viewModel.animationSystem else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "gsanim") ?? .json]
            panel.nameFieldStringValue = "animation.gsanim"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try anim.save(to: url)
                } catch {
                    animErrorMsg = error.localizedDescription
                    showAnimError = true
                }
            }
        }
        // Load animation
        .fileImporter(
            isPresented: $isLoadAnimPresented,
            allowedContentTypes: [UTType(filenameExtension: "gsanim") ?? .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let anim = viewModel.animationSystem else { return }
                do {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    try anim.load(from: url)
                } catch {
                    animErrorMsg = error.localizedDescription
                    showAnimError = true
                }
            case .failure(let error):
                animErrorMsg = error.localizedDescription
                showAnimError = true
            }
        }
        .alert("Animation Error", isPresented: $showAnimError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(animErrorMsg ?? "Unknown error")
        }
    }

    // MARK: - Properties Panel
    
    private var propertiesPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Panel header
                HStack {
                    Label("Splat Properties", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Spacer()
                    Button {
                        resetAllSettings()
                    } label: {
                        Text("Reset All")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.bottom, 4)
                
                // --- Geometry Section ---
                sectionHeader("Geometry", icon: "cube")
                
                sliderRow(
                    label: "Splat Scale",
                    value: $scaleMultiplier,
                    range: 0.01...5.0,
                    format: "%.2f",
                    help: "Global size multiplier for all splats"
                ) {
                    viewModel.renderer?.splatSettings.scaleMultiplier = Float($0)
                }
                
                // --- Appearance Section ---
                sectionHeader("Appearance", icon: "paintbrush")
                
                sliderRow(
                    label: "Opacity",
                    value: $opacityMultiplier,
                    range: 0.0...2.0,
                    format: "%.2f",
                    help: "Global opacity multiplier"
                ) {
                    viewModel.renderer?.splatSettings.opacityMultiplier = Float($0)
                }
                
                sliderRow(
                    label: "Sharpness",
                    value: $gaussianSharpness,
                    range: 0.1...5.0,
                    format: "%.2f",
                    help: "Controls Gaussian falloff curve. Higher = sharper edges."
                ) {
                    viewModel.renderer?.splatSettings.gaussianSharpness = Float($0)
                }
                
                sliderRow(
                    label: "Saturation",
                    value: $saturation,
                    range: 0.0...2.0,
                    format: "%.2f",
                    help: "Color saturation. 0 = grayscale, 1 = original, 2 = vivid"
                ) {
                    viewModel.renderer?.splatSettings.saturation = Float($0)
                }
                
                // --- Clipping Section ---
                sectionHeader("Clipping", icon: "scissors")
                
                sliderRow(
                    label: "Near Clip",
                    value: $nearClip,
                    range: 0.001...10.0,
                    format: "%.3f",
                    help: "Near clipping plane distance"
                ) {
                    viewModel.renderer?.splatSettings.nearClip = Float($0)
                }
                
                sliderRow(
                    label: "Far Clip",
                    value: $farClip,
                    range: 10.0...5000.0,
                    format: "%.0f",
                    help: "Far clipping plane distance"
                ) {
                    viewModel.renderer?.splatSettings.farClip = Float($0)
                }
                
                // --- Quality Section ---
                sectionHeader("Quality", icon: "wand.and.stars")
                
                sliderRow(
                    label: "Min Alpha Cutoff",
                    value: $minOpacityCutoff,
                    range: 0.0...0.1,
                    format: "%.4f",
                    help: "Splats with alpha below this value are discarded. Lower = more detail but slower."
                ) {
                    viewModel.renderer?.splatSettings.minOpacityCutoff = Float($0)
                }
                
                // SH Degree Picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("SH Degree")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("SH Degree", selection: $shDegreeOverride) {
                        Text("Auto").tag(-1)
                        Text("0 (Flat)").tag(0)
                        Text("1 (Linear)").tag(1)
                        Text("2 (Quadratic)").tag(2)
                        Text("3 (Cubic)").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: shDegreeOverride) { newValue in
                        viewModel.renderer?.splatSettings.shDegreeOverride = Int32(newValue)
                    }
                }
                .help("Override spherical harmonics degree. Auto uses per-splat degree.")
                
                // Covariance Regularization
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $covRegEnabled) {
                        Text("Custom Cov. Regularization")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .onChange(of: covRegEnabled) { newValue in
                        if !newValue {
                            covRegularization = -1.0
                            viewModel.renderer?.splatSettings.covRegularization = -1.0
                        } else {
                            covRegularization = 0.2
                            viewModel.renderer?.splatSettings.covRegularization = 0.2
                        }
                    }
                    
                    if covRegEnabled {
                        sliderRow(
                            label: "Regularization",
                            value: $covRegularization,
                            range: 0.0...2.0,
                            format: "%.3f",
                            help: "Covariance regularization. Higher = smoother/blurrier splats."
                        ) {
                            viewModel.renderer?.splatSettings.covRegularization = Float($0)
                        }
                    }
                }
                .help("Override adaptive covariance regularization. Controls splat sharpness/blur.")
                
                // --- Background Section ---
                sectionHeader("Background", icon: "paintpalette")
                
                HStack {
                    Text("Color")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    ColorPicker("", selection: $bgColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 44)
                        .onChange(of: bgColor) { newValue in
                            let nsColor = NSColor(newValue)
                            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                            nsColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                            viewModel.renderer?.splatSettings.bgColorR = Float(r)
                            viewModel.renderer?.splatSettings.bgColorG = Float(g)
                            viewModel.renderer?.splatSettings.bgColorB = Float(b)
                        }
                }
                
                // Quick background presets
                HStack(spacing: 6) {
                    bgPresetButton("Dark", color: Color(red: 0.1, green: 0.1, blue: 0.1))
                    bgPresetButton("Black", color: .black)
                    bgPresetButton("White", color: .white)
                    bgPresetButton("Gray", color: Color(white: 0.5))
                }
                
                Spacer(minLength: 20)
            }
            .padding(14)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    // MARK: - Panel Components
    
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .padding(.top, 6)
    }
    
    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        help: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption)
                    .foregroundColor(.primary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .controlSize(.small)
                .onChange(of: value.wrappedValue) { newValue in
                    onChange(newValue)
                }
        }
        .help(help)
    }
    
    private func bgPresetButton(_ label: String, color: Color) -> some View {
        Button {
            bgColor = color
            let nsColor = NSColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            nsColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
            viewModel.renderer?.splatSettings.bgColorR = Float(r)
            viewModel.renderer?.splatSettings.bgColorG = Float(g)
            viewModel.renderer?.splatSettings.bgColorB = Float(b)
        } label: {
            Text(label)
                .font(.caption2)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }
    
    private func resetAllSettings() {
        scaleMultiplier = 1.0
        opacityMultiplier = 1.0
        gaussianSharpness = 1.0
        saturation = 1.0
        nearClip = 0.01
        farClip = 1000.0
        minOpacityCutoff = 1.0 / 255.0
        shDegreeOverride = -1
        bgColor = Color(red: 0.1, green: 0.1, blue: 0.1)
        covRegularization = -1.0
        covRegEnabled = false
        
        viewModel.renderer?.splatSettings = SplatSettings()
    }
    
    // MARK: - Transform Buttons
    
    @ViewBuilder
    private func transformButton(_ label: String, icon: String, mode: TransformMode, help: String) -> some View {
        let isActive = transformMode == mode
        if isActive {
            Button(action: { toggleTransformMode(mode) }) {
                Label(label, systemImage: icon)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(help)
        } else {
            Button(action: { toggleTransformMode(mode) }) {
                Label(label, systemImage: icon)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(help)
        }
    }
    
    private func toggleTransformMode(_ mode: TransformMode) {
        if transformMode == mode {
            transformMode = .none
        } else {
            transformMode = mode
        }
        viewModel.renderer?.activeTransformMode = transformMode
    }
}

#Preview {
    ContentView()
}
