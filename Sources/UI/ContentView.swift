import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ViewModel()
    @State private var isFilePickerPresented = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button("Open PLY File...") {
                    isFilePickerPresented = true
                }
                .buttonStyle(.borderedProminent)
                
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
        }
        .frame(minWidth: 800, minHeight: 600)
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // Start accessing security-scoped resource
                    if url.startAccessingSecurityScopedResource() {
                        viewModel.loadFile(from: url)
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            case .failure(let error):
                print("File picker error: \(error)")
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
