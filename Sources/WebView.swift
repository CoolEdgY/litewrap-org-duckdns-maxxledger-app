import SwiftUI
import WebKit
import UIKit
import SafariServices
import AuthenticationServices

/// Owns the WKWebView, the `litewrap` bridge and the offline state.
final class WebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
                           ASWebAuthenticationPresentationContextProviding {
    @Published var offline = false
    @Published var showStatus = false

    let webView: WKWebView
    private var authSession: ASWebAuthenticationSession?
    private var allowGoogleInWebViewOnce = false
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
        for script in WebController.userScripts() { content.addUserScript(script) }
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
        // The page handles the notch and home bar itself with env(safe-area-inset-*).
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        load()
    }

    /// window.LiteWrap (rebuilt after pairing, so a reload shows the new state) and the double-tap zoom block.
    static func userScripts() -> [WKUserScript] {
        let cfg = AppConfig.shared
        let paired = HealthSync.shared.isPaired ? "true" : "false"
        let health = cfg.health.enabled ? "true" : "false"
        let types = (try? String(data: JSONEncoder().encode(cfg.health.types), encoding: .utf8)) ?? "[]"
        let features = (try? String(data: JSONEncoder().encode(cfg.features), encoding: .utf8)) ?? "[]"
        let js = "window.LiteWrap = {version: 1, health: \(health), paired: \(paired), healthTypes: \(types), features: \(features)};"
        let noDoubleTap = "var s=document.createElement('style');s.textContent='html{touch-action:manipulation}';document.head&&document.head.appendChild(s);"
        // navigator.share through the native share sheet, only if the web view lacks it.
        let sharePolyfill = """
        if (!navigator.share && window.webkit && window.webkit.messageHandlers.litewrap) {
          navigator.share = function (d) {
            d = d || {};
            return new Promise(function (resolve, reject) {
              var id = 'share-' + Date.now();
              function onReply(e) {
                if (!e.detail || e.detail.type !== 'shared' || e.detail.id !== id) return;
                window.removeEventListener('litewrap', onReply);
                e.detail.done ? resolve() : reject(new DOMException('Share canceled', 'AbortError'));
              }
              window.addEventListener('litewrap', onReply);
              window.webkit.messageHandlers.litewrap.postMessage({type: 'share', id: id, title: d.title || '', text: d.text || '', url: d.url || ''});
            });
          };
        }
        """
        return [WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true),
                WKUserScript(source: noDoubleTap, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
                WKUserScript(source: sharePolyfill, injectionTime: .atDocumentStart, forMainFrameOnly: true)]
    }

    private func refreshUserScripts() {
        let c = webView.configuration.userContentController
        c.removeAllUserScripts()
        for script in WebController.userScripts() { c.addUserScript(script) }
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
                self?.refreshUserScripts()
                self?.notifyPage(["type": "paired"])
            }
        case "unpair":
            HealthSync.shared.unpair()
            refreshUserScripts()
            notifyPage(["type": "unpaired"])
        case "status":
            showStatus = true
        case "sync":
            HealthSync.shared.syncRecent(days: 7)
        case "scanBarcode":
            let id = body["id"]
            let tint = UIColor(hex: config.themeColor ?? "") ?? .systemGreen
            BarcodeScanner.start(tint: tint) { [weak self] result in
                switch result {
                case .code(let code, let format):
                    self?.notifyPage(["type": "barcode", "code": code, "format": format], id: id)
                case .cancelled:
                    self?.notifyPage(["type": "barcodeCancelled"], id: id)
                case .error(let reason):
                    self?.notifyPage(["type": "barcodeError", "reason": reason], id: id)
                }
            }
        case "share":
            let id = body["id"]
            let title = body["title"] as? String ?? ""
            let text = [body["text"] as? String, body["url"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            let sheet = UIActivityViewController(activityItems: [text.isEmpty ? title : text], applicationActivities: nil)
            if !title.isEmpty { sheet.setValue(title, forKey: "subject") }
            sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in
                self?.notifyPage(["type": "shared", "done": completed], id: id)
            }
            UIHelpers.topViewController()?.present(sheet, animated: true)
        case "haptic":
            Haptics.play(body["style"] as? String ?? "light")
        case "keepAwake":
            UIApplication.shared.isIdleTimerDisabled = (body["on"] as? Bool) ?? false
        case "notify":
            guard let nid = body["id"].map({ "\($0)" }), let at = (body["at"] as? NSNumber)?.doubleValue else { return }
            Notifier.schedule(id: nid, at: Date(timeIntervalSince1970: at / 1000),
                              title: body["title"] as? String ?? config.name,
                              body: body["body"] as? String ?? "",
                              sound: (body["sound"] as? Bool) ?? true)
        case "notifyCancel":
            if let nid = body["id"].map({ "\($0)" }) { Notifier.cancel(nid) }
        case "notifyPermission":
            let id = body["id"]
            Notifier.requestPermission { [weak self] granted in
                self?.notifyPage(["type": "notifyPermission", "granted": granted], id: id)
            }
        default:
            break
        }
    }

    private func notifyPage(_ detail: [String: Any], id: Any? = nil) {
        var detail = detail
        if let id, !(id is NSNull) { detail["id"] = id }
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
        // Google sign-in runs in Apple's secure sign-in window, never inside the web view.
        if config.googleSignIn == true, url.host?.lowercased() == "accounts.google.com",
           navigationAction.targetFrame?.isMainFrame ?? true {
            if allowGoogleInWebViewOnce {
                allowGoogleInWebViewOnce = false
            } else if startGoogleSignIn(url) {
                return decisionHandler(.cancel)
            }
        }
        if ["tel", "mailto", "sms", "facetime", "itms-apps", "maps"].contains(scheme) {
            UIApplication.shared.open(url)
            return decisionHandler(.cancel)
        }
        // Links to other sites open in Safari. Redirects (like sign-in) stay in the app.
        if (scheme == "http" || scheme == "https"),
           navigationAction.navigationType == .linkActivated,
           !isInternal(url) {
            UIHelpers.openInSafari(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target="_blank" and window.open: same site loads here, other sites open in Safari.
        if let url = navigationAction.request.url {
            if isInternal(url) { webView.load(navigationAction.request) } else { UIHelpers.openInSafari(url) }
        }
        return nil
    }

    // MARK: Google sign-in

    /// Opens Google in ASWebAuthenticationSession. When Google sends the browser back to the site's own
    /// callback (redirect_uri), that final URL is loaded in the web view, so the session cookie lands there.
    private func startGoogleSignIn(_ url: URL) -> Bool {
        guard #available(iOS 17.4, *) else { return false }
        guard let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let callback = URL(string: redirect), let host = callback.host else { return false }
        let session = ASWebAuthenticationSession(url: url, callback: .https(host: host, path: callback.path)) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authSession = nil
                if let result {
                    self.webView.load(URLRequest(url: result))
                    return
                }
                if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { return }
                // The secure window could not be used (for example the site's association file is missing):
                // sign in inside the app instead, like before.
                self.allowGoogleInWebViewOnce = true
                self.webView.load(URLRequest(url: url))
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        return session.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIHelpers.keyWindow ?? ASPresentationAnchor()
    }

    /// Camera for the app's own pages: allowed once by iOS, not asked again on every page load.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host.lowercased()
        decisionHandler(host == config.host || host.hasSuffix("." + config.host) ? .grant : .prompt)
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
