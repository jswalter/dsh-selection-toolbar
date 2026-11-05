import AppKit
import WebKit

// Web content is a read-only projection. Copy/replacement always use AppDelegate.result.
final class MarkdownView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var ready = false
    private var pending: DispatchWorkItem?
    private var turns: [[String: String]] = []
    private var scrollToEnd = false
    private var revision = 0
    private var rendering = false
    var contentHeight: CGFloat = 24
    var onHeightChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        // A weak proxy avoids a cycle through WKUserContentController.
        configuration.userContentController.add(WeakMarkdownHandler(self), name: "markdownHeight")
        if let directory = Bundle.main.resourceURL?.appendingPathComponent("Markdown") {
            webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { pending?.cancel() }

    func render(_ turns: [[String: String]], scrollToEnd: Bool) {
        self.turns = turns; self.scrollToEnd = self.scrollToEnd || scrollToEnd; revision += 1
        scheduleRender()
    }
    private func scheduleRender() {
        guard ready, pending == nil, !rendering else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil; self.rendering = true
            let renderedRevision = self.revision
            let scroll = self.scrollToEnd; self.scrollToEnd = false
            self.webView.callAsyncJavaScript("window.renderTurns(turns, scroll)",
                arguments: ["turns": self.turns, "scroll": scroll], in: nil, in: .page) { [weak self] _ in
                guard let self else { return }
                self.rendering = false
                if self.revision != renderedRevision { self.scheduleRender() }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
    func scrollToBeginning() { webView.evaluateJavaScript("window.scrollTo(0, 0)") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTheme() }
    private func updateTheme() {
        guard ready else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        webView.callAsyncJavaScript("window.setTheme(dark)", arguments: ["dark": dark], in: nil, in: .page)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true; updateTheme(); scheduleRender()
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let height = message.body as? Double, height.isFinite else { return }
        let next = CGFloat(max(24, min(height, 10_000_000)))
        if abs(next - contentHeight) > 0.5 { contentHeight = next; onHeightChange?() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel); return
        }
        // Only the initial bundled page may navigate within the panel.
        decisionHandler(!ready && navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

private final class WeakMarkdownHandler: NSObject, WKScriptMessageHandler {
    weak var owner: MarkdownView?
    init(_ owner: MarkdownView) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}
