import WebKit
import Foundation

/// qm:// scheme: 页面与模型分离 —— 更新模型只替换 Documents 文件，无需重打包
final class QMSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = QMSchemeHandler()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL)); return
        }
        var fname = url.path
        if fname.isEmpty || fname == "/" { fname = "/index.html" }
        fname = String(fname.dropFirst())

        if fname == "index.html" {
            guard let u = Bundle.main.url(forResource: "index", withExtension: "html"),
                  let data = try? Data(contentsOf: u) else {
                task.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            respond(task, url: url, data: data, mime: "text/html; charset=utf-8")
            return
        }
        if let data = ModelStore.shared.data(named: fname) {
            respond(task, url: url, data: data, mime: "application/json; charset=utf-8")
            return
        }
        task.didFailWithError(URLError(.fileDoesNotExist))
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Cache-Control": "no-store"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class ModelStore {
    static let shared = ModelStore()
    private let fm = FileManager.default

    /// 用户更新后的模型优先, 否则回退 App 内置
    func data(named: String) -> Data? {
        let u = currentDir.appendingPathComponent(named)
        if fm.fileExists(atPath: u.path), let d = try? Data(contentsOf: u) { return d }
        let ext = (named as NSString).pathExtension
        let base = (named as NSString).deletingPathExtension
        if let bu = Bundle.main.url(forResource: base, withExtension: ext),
           let d = try? Data(contentsOf: bu) { return d }
        return nil
    }

    var currentDir: URL {
        let d = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("quant/current", isDirectory: true)
        if !fm.fileExists(atPath: d.path) {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    func saveModel(_ data: Data, named: String) throws {
        try data.write(to: currentDir.appendingPathComponent(named), options: .atomic)
    }

    func currentVersion() -> String {
        if let d = try? Data(contentsOf: currentDir.appendingPathComponent("version.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let v = j["version"] as? String { return v }
        return "内置"
    }

    func saveVersion(_ v: String, md5: String) {
        let j: [String: Any] = ["version": v, "md5": md5,
                                "at": ISO8601DateFormatter().string(from: Date())]
        if let d = try? JSONSerialization.data(withJSONObject: j) {
            try? d.write(to: currentDir.appendingPathComponent("version.json"))
        }
    }
}
