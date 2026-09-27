import SwiftUI
import WebKit
import UIKit

/// Owns the WKWebView, the `litewrap` bridge and the offline state.
final class WebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var offline = false
    @Published var showStatus = false

    let webView: WKWebView
    private let config = AppConfig.shared

    /// Sign-in pages that must stay inside the app, or sign-in would break.
    private let authHosts = ["accounts.google.com", "appleid.apple.com", "login.microsoftonline.com",
                             "www.facebook.com", "m.facebook.com", "github.com"]

    override init() {
        let cfg = AppConfig.shared
        let wk = WKWebViewConfiguration()
        wk.websiteDataStore = .default()
        wk.allowsInlineMediaPlayback = true
        // Looks like Safari to the website, plus "LiteWrap/1" so the page knows it runs in LiteWrap.
        wk.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1 LiteWrap/1"

        let content = WKUserContentController()
        let paired = HealthSync.shared.isPaired ? "true" : "false"
        let health = cfg.health.enabled ? "true" : "false"
        let types = (try? String(data: JSONEncoder().encode(cfg.health.types), encoding: .utf8)) ?? "[]"
        let js = "window.LiteWrap = {version: 1, health: \(health), paired: \(paired), healthTypes: \(types)};"
        content.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        wk.userContentController = content

        webView = WKWebView(frame: .zero, configuration: wk)
        super.init()

        content.add(WeakMessageHandler(self), name: "litewrap")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(hex: config.backgroundColor ?? config.themeColor ?? "") ?? .systemBackground
        webView.scrollView.backgroundColor = webView.backgroundColor
        load()
    }

    func load() {
        webView.load(URLRequest(url: config.startURL))
    }

    func retry() {
        offline = false
        if webView.url == nil { load() } else { webView.reload() }
    }

    private func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        if host == config.host || host.hasSuffix("." + config.host) { return true }
        return authHosts.contains(host)
    }

    // MARK: Bridge

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "pair":
            guard let token = body["token"] as? String, let url = body["url"] as? String else { return }
            HealthSync.shared.pair(token: token, url: url) { [weak self] in
                self?.notifyPage(["type": "paired"])
            }
        case "unpair":
            HealthSync.shared.unpair()
            notifyPage(["type": "unpaired"])
        case "status":
            showStatus = true
        case "sync":
            HealthSync.shared.syncRecent(days: 7)
        default:
            break
        }
    }

    private func notifyPage(_ detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }
        let paired = HealthSync.shared.isPaired ? "true" : "false"
        let js = "if (window.LiteWrap) { window.LiteWrap.paired = \(paired); } window.dispatchEvent(new CustomEvent('litewrap', {detail: \(json)}));"
        DispatchQueue.main.async { self.webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["tel", "mailto", "sms", "facetime", "itms-apps", "maps"].contains(scheme) {
            UIApplication.shared.open(url)
            return decisionHandler(.cancel)
        }
        // Links to other sites open in Safari. Redirects (like sign-in) stay in the app.
        if (scheme == "http" || scheme == "https"),
           navigationAction.navigationType == .linkActivated,
           !isInternal(url) {
            UIApplication.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target="_blank" and window.open: same site loads here, other sites open in Safari.
        if let url = navigationAction.request.url {
            if isInternal(url) { webView.load(navigationAction.request) } else { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        offline = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func handle(_ error: Error) {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return }
        let offlineCodes = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                            NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff]
        if offlineCodes.contains(ns.code) { offline = true }
    }
}

/// Avoids a retain cycle between WKUserContentController and the controller.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

struct WebViewContainer: UIViewRepresentable {
    let controller: WebController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
