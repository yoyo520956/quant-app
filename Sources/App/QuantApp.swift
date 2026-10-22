import SwiftUI
import WebKit

@main
struct QuantApp: App {
    @StateObject private var updater = ModelUpdater.shared

    init() {
        Notifier.requestAuth()
    }

    var body: some Scene {
        WindowGroup {
            WebHostView()
                .ignoresSafeArea()
                .onAppear {
                    updater.currentVersion = ModelStore.shared.currentVersion()
                    updater.check(thenAuto: true)
                }
        }
    }
}

struct WebHostView: UIViewRepresentable {
    @ObservedObject var updater = ModelUpdater.shared

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(QMSchemeHandler.shared, forURLScheme: "qm")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1.0"
        let src = WKUserScript(source: "window.APP_VERSION='\(version)';window.APP_BUILD='\(build)';window.IS_NATIVE_APP=true;",
                               injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(src)
        config.userContentController.add(context.coordinator, name: "native")

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = URL(string: "qm://app/index.html") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.web = uiView
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
            switch cmd {
            case "checkUpdate":
                ModelUpdater.shared.check(thenAuto: true) { has in
                    let js = "window.onNativeUpdateCheck && window.onNativeUpdateCheck(\(has ? "true" : "false"));"
                    self.web?.evaluateJavaScript(js)
                }
            case "applyUpdate":
                ModelUpdater.shared.downloadAndApply { ok, msg in
                    let safe = msg.replacingOccurrences(of: "'", with: "")
                    let js = "window.onNativeUpdateApplied && window.onNativeUpdateApplied(\(ok ? "true" : "false"),'\(safe)');"
                    self.web?.evaluateJavaScript(js)
                    if ok {
                        self.web?.evaluateJavaScript("location.reload();")
                    }
                }
            case "getState":
                let js = "window.onNativeState && window.onNativeState('\(ModelUpdater.shared.status)');"
                self.web?.evaluateJavaScript(js)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
            ModelUpdater.shared.currentVersion = ModelStore.shared.currentVersion()
            let js = "window.onNativeState && window.onNativeState('\(ModelUpdater.shared.status)');"
            webView.evaluateJavaScript(js)
        }
    }
}
