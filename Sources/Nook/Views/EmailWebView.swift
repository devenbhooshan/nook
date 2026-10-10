import AppKit
import SwiftUI
import WebKit

/// Renders one message body. JavaScript in the message is disabled, links open in your browser,
/// and the view sizes itself to its content so a thread scrolls as one page.
struct EmailWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true

        // Measuring runs in Nook's own script world, which works even with the page's JavaScript disabled.
        let controller = configuration.userContentController
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "height")
        controller.addUserScript(WKUserScript(
            source: """
            const report = () => window.webkit.messageHandlers.height.postMessage(
              Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight));
            new ResizeObserver(report).observe(document.documentElement);
            report();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))

        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        context.coordinator.load(html, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(html, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "height", contentWorld: .defaultClient)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var height: CGFloat
        private var loadedHTML: String?
        /// Set just before Nook loads a message, so that load is the one navigation the view allows.
        private var allowsNextLoad = false

        init(height: Binding<CGFloat>) {
            _height = height
        }

        func load(_ html: String, in webView: WKWebView) {
            guard html != loadedHTML else { return }
            loadedHTML = html
            allowsNextLoad = true
            webView.loadHTMLString(html, baseURL: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double, value > 0 else { return }
            let newHeight = ceil(value)
            if abs(newHeight - height) > 1 { height = newHeight }
        }

        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Nook's own load of the message is the only navigation allowed inside the view. Everything else
            // (meta refresh, frames, forms, file: or data: URLs) is cancelled.
            if allowsNextLoad, action.targetFrame?.isMainFrame == true, action.request.url?.absoluteString == "about:blank" {
                allowsNextLoad = false
                return .allow
            }
            // Clicked links open in the browser, but only ordinary web and mail links.
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
    }
}

/// Hands scroll events to the enclosing SwiftUI scroll view, so wheel scrolling over a message scrolls the thread.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
