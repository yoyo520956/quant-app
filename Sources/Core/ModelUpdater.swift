import Foundation
import Combine
import CryptoKit

/// 模型更新: 从 GitHub 公开仓库检查 latest.json → 下载模型 → md5 校验 → 落盘 → 通知页面重载
/// 仓库公开 → 任何人都能提 PR 更新模型 → 合并后所有 App 下次检查即可收到提醒
final class ModelUpdater: NSObject, ObservableObject {
    static let shared = ModelUpdater()

    @Published var currentVersion = "内置"
    @Published var latestVersion = "-"
    @Published var updateAvailable = false
    @Published var status = ""

    private let latestURL = URL(string: "https://raw.githubusercontent.com/yoyo520956/quant-models/main/latest.json")!

    func check(thenAuto: Bool = false, completion: ((Bool) -> Void)? = nil) {
        URLSession.shared.dataTask(with: latestURL) { data, _, err in
            DispatchQueue.main.async {
                if let err = err {
                    self.status = "检查失败: " + err.localizedDescription
                    completion?(false); return
                }
                guard let data = data,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let v = j["version"] as? String else {
                    self.status = "检查失败: 响应异常"; completion?(false); return
                }
                self.latestVersion = v
                self.currentVersion = ModelStore.shared.currentVersion()
                if v != self.currentVersion {
                    self.updateAvailable = true
                    self.status = "发现新模型 v\(v)（当前 \(self.currentVersion)）"
                    Notifier.notify(title: "量化顾问有新模型", body: "模型 v\(v) 已发布，打开应用可一键更新")
                    completion?(true)
                } else {
                    self.updateAvailable = false
                    self.status = "模型已是最新 v\(v)"
                    completion?(false)
                }
            }
        }.resume()
    }

    func downloadAndApply(completion: @escaping (Bool, String) -> Void) {
        URLSession.shared.dataTask(with: latestURL) { data, _, err in
            guard let data = data, err == nil,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ver = j["version"] as? String else {
                DispatchQueue.main.async { completion(false, "清单解析失败") }; return
            }
            var items: [[String: Any]] = []
            if let arr = j["files"] as? [[String: Any]] { items = arr }
            else if let u = j["url"] as? String, let f = j["file"] as? String {
                items = [["name": f, "url": u, "md5": j["md5"] ?? ""]]
            }
            self.apply(items, ver: ver, done: completion)
        }.resume()
    }

    private func apply(_ items: [[String: Any]], ver: String, done: @escaping (Bool, String) -> Void) {
        guard let it = items.first else {
            ModelStore.shared.saveVersion(ver, md5: "")
            self.currentVersion = ver
            self.updateAvailable = false
            DispatchQueue.main.async { done(true, "已更新到模型 v\(ver)") }
            return
        }
        let rest = Array(items.dropFirst())
        guard let u = it["url"] as? String, let url = URL(string: u) else {
            done(false, "地址无效"); return
        }
        URLSession.shared.dataTask(with: url) { md, _, me in
            guard let md = md, me == nil else { done(false, "下载失败 \(it["name"] ?? "")"); return }
            if let expect = it["md5"] as? String, !expect.isEmpty, expect as? String != "" {
                if ModelUpdater.md5(md) != expect.lowercased() { done(false, "校验失败 \(it["name"] ?? "")"); return }
            }
            do {
                try ModelStore.shared.saveModel(md, named: (it["name"] as? String) ?? "model.json")
                self.apply(rest, ver: ver, done: done)
            } catch { done(false, "保存失败: \(error.localizedDescription)") }
        }.resume()
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
