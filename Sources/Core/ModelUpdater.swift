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
                  let urlStr = j["url"] as? String, let url = URL(string: urlStr),
                  let file = j["file"] as? String else {
                DispatchQueue.main.async { completion(false, "清单解析失败") }; return
            }
            URLSession.shared.dataTask(with: url) { mdata, _, merr in
                DispatchQueue.main.async {
                    guard let mdata = mdata, merr == nil else {
                        completion(false, "模型下载失败"); return
                    }
                    if let expect = j["md5"] as? String {
                        let actual = ModelUpdater.md5(mdata)
                        if expect.lowercased() != actual.lowercased() {
                            completion(false, "校验失败（md5 不匹配）"); return
                        }
                    }
                    do {
                        try ModelStore.shared.saveModel(mdata, named: file)
                        let ver = j["version"] as? String ?? "-"
                        ModelStore.shared.saveVersion(ver, md5: j["md5"] as? String ?? "")
                        self.currentVersion = ver
                        self.updateAvailable = false
                        self.status = "已更新到模型 v\(ver)"
                        completion(true, self.status)
                    } catch {
                        completion(false, "保存失败: \(error.localizedDescription)")
                    }
                }
            }.resume()
        }.resume()
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
