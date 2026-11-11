import SwiftUI
import WebKit

/// Mounts the engine's headless web view in the hierarchy. WebKit needs the
/// view to be attached and non-zero sized, but it is visually inert at 1x1.
#if canImport(UIKit)
struct PyodideHostView: UIViewRepresentable {
    let engine: PyodideEngine

    func makeUIView(context: Context) -> WKWebView {
        engine.makeWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#elseif canImport(AppKit)
struct PyodideHostView: NSViewRepresentable {
    let engine: PyodideEngine

    func makeNSView(context: Context) -> WKWebView {
        engine.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
