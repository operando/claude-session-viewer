// Claude Session Viewer (ネイティブ版)
// Node不要。データ読み取りはSwift(Engine.swift)、UIはバンドル内のindex.htmlを
// WKWebViewで表示し、JSブリッジ(webkit.messageHandlers.api)でAPIを提供する。
import SwiftUI
import WebKit

@main
struct NativeApp: App {
    var body: some Scene {
        WindowGroup("Claude Session Viewer") {
            WebView()
                .frame(minWidth: 1000, minHeight: 640)
        }
    }
}

final class ApiBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private let queue = DispatchQueue(label: "api", qos: .userInitiated)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? Int,
              let path = body["path"] as? String else { return }
        queue.async { [weak self] in
            let result = Engine.handle(path: path)
            let json = (try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{\"error\":\"serialize failed\"}"
            DispatchQueue.main.async {
                // JSONリテラルはそのままJS式として妥当なので直接埋め込む
                self?.webView?.evaluateJavaScript("window.__apiResolve(\(id), \(json))")
            }
        }
    }
}

struct WebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let bridge = ApiBridge()
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "api")
        let webView = WKWebView(frame: .zero, configuration: config)
        bridge.webView = webView
        context.coordinator.bridge = bridge

        if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var bridge: ApiBridge? // WKWebViewより長く生かすための保持
    }
}
