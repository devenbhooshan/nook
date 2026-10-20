import AppKit
import NookCore
import SwiftUI
import WebKit

/// Renders one message body. JavaScript in the message is disabled, links open in your browser,
/// and the view sizes itself to its content so a thread scrolls as one page.
struct EmailWebView: NSViewRepresentable {
    typealias InlineImageLoader = @MainActor (String) async -> (data: Data, mimeType: String)?

    let html: String
    @Binding var height: CGFloat
    /// Supplies images the body links with `cid:`. They're part of the message, not remote content.
    var inlineImage: InlineImageLoader?

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        context.coordinator.inlineImages.load = inlineImage
        if !WKWebView.handlesURLScheme("cid") {
            configuration.setURLSchemeHandler(context.coordinator.inlineImages, forURLScheme: "cid")
        }

        // Measuring runs in Nook's own script world, which works even with the page's JavaScript disabled.
        let controller = configuration.userContentController
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "height")
        controller.addUserScript(WKUserScript(
            source: """
            // The content's own height. scrollHeight, and the root element in quirks mode (most HTML mail has no
            // doctype), never drop below the view's height, so a message that got shorter (quotes folded away)
            // would keep its old, taller view. A range over the body measures only what's actually drawn.
            const report = () => {
              const body = document.body;
              if (!body) return;
              const range = document.createRange();
              range.selectNodeContents(body);
              const style = getComputedStyle(body);
              const bottom = range.getBoundingClientRect().bottom + window.scrollY
                + parseFloat(style.paddingBottom || 0) + parseFloat(style.marginBottom || 0);
              window.webkit.messageHandlers.height.postMessage(Math.ceil(bottom));
            };
            window.nookReportHeight = report;
            const observer = new ResizeObserver(report);
            observer.observe(document.documentElement);
            if (document.body) observer.observe(document.body);
            report();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        controller.addUserScript(WKUserScript(source: Self.foldQuotes, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))

        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        context.coordinator.load(html, in: webView)
        return webView
    }

    /// Folds the earlier messages a reply quotes (Gmail, Apple Mail, Outlook, Yahoo and plain-text quoting) behind
    /// a "•••" button, the way Gmail does, so a long thread doesn't repeat itself in every message. A message that's
    /// nothing but a quote, or a forward, is left alone.
    static let foldQuotes = """
    (() => {
      const sel = 'div.gmail_quote:has(> blockquote), blockquote.gmail_quote, blockquote[type="cite"], .yahoo_quoted, .nook-quote';
      let nodes = [...document.querySelectorAll(sel)].filter(q => !q.parentElement || !q.parentElement.closest(sel));
      // Outlook puts the quote after a marker, as siblings rather than inside one element.
      for (const marker of document.querySelectorAll('#appendonsend, #divRplyFwdMsg')) {
        let start = marker;
        if (marker.id === 'divRplyFwdMsg' && marker.previousElementSibling && marker.previousElementSibling.tagName === 'HR') start = marker.previousElementSibling;
        for (let n = start; n; n = n.nextElementSibling) nodes.push(n);
      }
      nodes = [...new Set(nodes)].filter(n => !nodes.some(o => o !== n && o.contains(n)));
      if (!nodes.length || !document.body) return;
      const copy = document.body.cloneNode(true);
      const all = [...document.body.querySelectorAll('*')];
      const copies = [...copy.querySelectorAll('*')];
      for (const n of nodes) { const i = all.indexOf(n); if (i >= 0) copies[i].remove(); }
      const own = copy.textContent.replace(/\\s+/g, ' ').trim();
      if (!own || /forwarded message/i.test(own)) return;
      for (const n of nodes) n.style.setProperty('display', 'none', 'important');
      const more = document.createElement('div');
      more.textContent = '•••';
      more.title = 'Show quoted text';
      more.setAttribute('style', 'all: initial; display: inline-block; margin: 10px 0 4px; padding: 0 9px; height: 16px; line-height: 13px; border-radius: 8px; background: rgba(128,128,128,.18); color: rgba(90,90,90,.95); font: 700 11px -apple-system; letter-spacing: 1px; cursor: pointer;');
      let open = false;
      more.addEventListener('click', () => {
        open = !open;
        for (const n of nodes) open ? n.style.removeProperty('display') : n.style.setProperty('display', 'none', 'important');
        more.title = open ? 'Hide quoted text' : 'Show quoted text';
        if (window.nookReportHeight) window.nookReportHeight();
      });
      nodes[0].parentNode.insertBefore(more, nodes[0]);
      // In quirks mode the page doesn't resize when content shrinks, so nothing else would notice.
      if (window.nookReportHeight) window.nookReportHeight();
    })();
    """

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.inlineImages.load = inlineImage
        context.coordinator.load(html, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "height", contentWorld: .defaultClient)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var height: CGFloat
        let inlineImages = InlineImageHandler()
        private var loadedHTML: String?
        private var measured = ContentHeight()
        /// Set just before Nook loads a message, so that load is the one navigation the view allows.
        private var allowsNextLoad = false

        init(height: Binding<CGFloat>) {
            _height = height
        }

        func load(_ html: String, in webView: WKWebView) {
            guard html != loadedHTML else { return }
            loadedHTML = html
            measured = ContentHeight()
            allowsNextLoad = true
            webView.loadHTMLString(html, baseURL: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double, let newHeight = measured.report(value) else { return }
            height = newHeight
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

/// Answers `cid:` requests from a message body with the message's own attachments.
final class InlineImageHandler: NSObject, WKURLSchemeHandler {
    var load: EmailWebView.InlineImageLoader?
    private var stopped: Set<ObjectIdentifier> = []

    @MainActor
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let load else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
        let contentId = String(url.absoluteString.dropFirst("cid:".count))
        let key = ObjectIdentifier(task)
        Task { @MainActor in
            let result = await load(contentId.removingPercentEncoding ?? contentId)
            // WebKit throws if a stopped task is answered.
            guard stopped.remove(key) == nil else { return }
            guard let result else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
            task.didReceive(URLResponse(url: url, mimeType: result.mimeType, expectedContentLength: result.data.count, textEncodingName: nil))
            task.didReceive(result.data)
            task.didFinish()
        }
    }

    @MainActor
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}
