import SwiftUI
import WebKit
import Combine

@main
struct QuantApp: App {
    @StateObject private var app = AppState.shared
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(app).preferredColorScheme(nil)
        }
    }
}

final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var ready = false
    @Published var failed = false
    @Published var currentModelVer = ""
    @Published var updateAvailable = false
    @Published var latestVer = ""
    @Published var status = ""
    @Published var showUpdatePrompt = false
    private init() { currentModelVer = ModelStore.shared.currentVersion() }
}
struct RootView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var updater = ModelUpdater()

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()
                QWebView()
                if !app.ready && !app.failed {
                    VStack(spacing: 14) {
                        ProgressView().tint(.white)
                        Text("正在装载本地引擎…").font(.footnote).foregroundColor(.white.opacity(0.7))
                    }
                }
                if app.failed {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundColor(.orange)
                        Text("页面加载失败").foregroundColor(.white)
                        Button("重试") { app.failed = false; app.ready = false;
                            NotificationCenter.default.post(name: .qmReload, object: nil) }
                            .buttonStyle(.borderedProminent).tint(.blue)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("量化顾问").font(.system(size: 15, weight: .semibold))
                        Text("模型 \(app.currentModelVer)")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        app.status = "检查中…"
                        updater.check { has in
                            DispatchQueue.main.async {
                                if has { app.latestVer = updater.latestVersion
                                         app.showUpdatePrompt = true; app.updateAvailable = true }
                                else { app.status = "已是最新模型" }
                            }
                        }
                    } label: {
                        Image(systemName: app.updateAvailable ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .symbolVariant(app.updateAvailable ? .fill : .none)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button { NotificationCenter.default.post(name: .qmReload, object: nil) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .confirmationDialog("发现新模型 v\(app.latestVer)", isPresented: $app.showUpdatePrompt, titleVisibility: .visible) {
                Button("立即更新") {
                    app.status = "下载中…"
                    updater.downloadAndApply { ok, msg in
                        DispatchQueue.main.async {
                            app.status = msg
                            if ok {
                                app.currentModelVer = ModelStore.shared.currentVersion()
                                app.updateAvailable = false
                                NotificationCenter.default.post(name: .qmReload, object: nil)
                            }
                        }
                    }
                }
                Button("稍后", role: .cancel) {}
            } message: {
                Text("新模型将从官方仓库下载并校验，约 1.7MB")
            }
        }
        .task { if app.latestVer.isEmpty { startupCheck() } }
    }

    private func startupCheck() {
        updater.check { has in
            DispatchQueue.main.async {
                if has { app.latestVer = updater.latestVersion; app.updateAvailable = true }
            }
        }
    }
}

extension Notification.Name { static let qmReload = Notification.Name("qmReload") }
struct QWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(QMSchemeHandler.shared, forURLScheme: "qm")
        let native = "window.IS_NATIVE_APP=true;"
        cfg.userContentController.addUserScript(
            WKUserScript(source: native, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.add(context.coordinator, name: "native")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        context.coordinator.web = wv
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: URL(string: "qm://app/index.html")!))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        private var reloadObs: NSObjectProtocol?

        override init() {
            super.init()
            reloadObs = NotificationCenter.default.addObserver(
                forName: .qmReload, object: nil, queue: .main) { [weak self] _ in
                self?.web?.reloadFromOrigin()
            }
        }

        func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
            webView.evaluateJavaScript("window.__qmReady && window.__qmReady();")
            DispatchQueue.main.async { AppState.shared.ready = true }
        }

        func webView(_ webView: WKWebView, didFail nav: WKNavigation!, withError err: Error) {
            DispatchQueue.main.async { AppState.shared.failed = true }
        }

        func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard let body = msg.body as? [String: Any],
                  let cmd = body["cmd"] as? String else { return }
            switch cmd {
            case "getState":
                let st = ["modelVer": ModelStore.shared.currentVersion()]
                if let d = try? JSONSerialization.data(withJSONObject: st),
                   let s = String(data: d, encoding: .utf8) {
                    web?.evaluateJavaScript("window.__qmState && window.__qmState(\(s));")
                }
            default: break
            }
        }
    }
}
