import SwiftUI
import MetalKit
import Combine

/// SwiftUI wrapper for the Metal viewport
struct ViewportView: NSViewRepresentable {
    @ObservedObject var viewModel: ViewModel
    
    func makeNSView(context: Context) -> MTKView {
        let mtkView = InteractiveMTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.inputHandler = context.coordinator
        
        // Create renderer
        if let renderer = Renderer(metalKitView: mtkView) {
            context.coordinator.renderer = renderer
            viewModel.renderer = renderer
        }

        mtkView.window?.makeFirstResponder(mtkView)
        
        return mtkView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
        if let interactiveView = nsView as? InteractiveMTKView {
            interactiveView.inputHandler = context.coordinator
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, ViewportInputHandling {
        var parent: ViewportView
        var renderer: Renderer?
        var currentButton: MouseButton = .left
        
        init(_ parent: ViewportView) {
            self.parent = parent
            super.init()
        }
        
        func mouseDown(with event: NSEvent) {
            guard let renderer = renderer else { return }
            
            let point = event.locationInWindow
            currentButton = event.buttonNumber == 0 ? .left : (event.buttonNumber == 2 ? .right : .middle)
            renderer.handleMouseDown(at: point, button: currentButton)
        }
        
        func mouseDragged(with event: NSEvent) {
            guard let renderer = renderer else { return }
            
            let point = event.locationInWindow
            renderer.handleMouseDrag(to: point, button: currentButton)
        }
        
        func mouseUp(with event: NSEvent) {
            renderer?.handleMouseUp()
        }
        
        func rightMouseDown(with event: NSEvent) {
            guard let renderer = renderer else { return }
            
            let point = event.locationInWindow
            currentButton = .right
            renderer.handleMouseDown(at: point, button: .right)
        }
        
        func rightMouseDragged(with event: NSEvent) {
            guard let renderer = renderer else { return }
            
            let point = event.locationInWindow
            renderer.handleMouseDrag(to: point, button: .right)
        }
        
        func rightMouseUp(with event: NSEvent) {
            renderer?.handleMouseUp()
        }
        
        func scrollWheel(with event: NSEvent) {
            renderer?.handleScroll(deltaY: event.scrollingDeltaY)
        }
    }
}

protocol ViewportInputHandling: AnyObject {
    func mouseDown(with event: NSEvent)
    func mouseDragged(with event: NSEvent)
    func mouseUp(with event: NSEvent)
    func rightMouseDown(with event: NSEvent)
    func rightMouseDragged(with event: NSEvent)
    func rightMouseUp(with event: NSEvent)
    func scrollWheel(with event: NSEvent)
}

final class InteractiveMTKView: MTKView {
    weak var inputHandler: ViewportInputHandling?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        inputHandler?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        inputHandler?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        inputHandler?.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        inputHandler?.rightMouseDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        inputHandler?.rightMouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        inputHandler?.rightMouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        inputHandler?.scrollWheel(with: event)
    }
}

/// View model to coordinate between UI and renderer
class ViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var splatCount: Int = 0
    @Published var fps: Double = 0
    @Published var fileName: String = "No file loaded"
    
    var renderer: Renderer?
    
    func loadFile(from url: URL) {
        isLoading = true
        fileName = url.lastPathComponent
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.renderer?.loadScene(from: url)
            
            DispatchQueue.main.async {
                self?.isLoading = false
                self?.splatCount = self?.renderer?.scene?.splatCount ?? 0
            }
        }
    }
}
