import Foundation
import CryptoKit

/// 听歌缓存：播过的歌顺手下载到本地，重播直接放本地文件（断网也能播）；
/// 超过上限时按「最久未播」顺序清理。索引存同目录 index.json。
final class AudioCache {
    static let shared = AudioCache()

    private let dir: URL
    private let indexURL: URL
    private var index: [String: [String: Any]] = [:]
    private var downloading: Set<String> = []
    private let lock = NSLock()

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("MusicBoxAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = dir.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: indexURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            index = obj
        }
    }

    private func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

    private func fileName(for track: Track, ext: String) -> String {
        let digest = SHA256.hash(data: Data(track.id.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex + "." + (ext.isEmpty ? "mp3" : ext)
    }

    /// 已缓存则返回本地文件地址（并刷新最近播放时间）
    func cachedURL(for track: Track) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = index[track.id], let name = entry["file"] as? String else { return nil }
        let url = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            index.removeValue(forKey: track.id)
            saveLocked()
            return nil
        }
        index[track.id]?["lastAccess"] = Date().timeIntervalSince1970
        saveLocked()
        return url
    }

    /// 后台把这首歌的音频存进缓存（已缓存/正在下载则跳过）
    func store(source: MediaSource, for track: Track) {
        lock.lock()
        if index[track.id] != nil || downloading.contains(track.id) {
            lock.unlock()
            return
        }
        downloading.insert(track.id)
        lock.unlock()

        var req = URLRequest(url: source.url)
        for (k, v) in source.headers { req.setValue(v, forHTTPHeaderField: k) }
        URLSession.shared.downloadTask(with: req) { [weak self] tmp, _, _ in
            guard let self else { return }
            self.lock.lock()
            self.downloading.remove(track.id)
            guard let tmp else {
                self.lock.unlock()
                return
            }
            let name = self.fileName(for: track, ext: source.url.pathExtension)
            let dest = self.dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else {
                self.lock.unlock()
                return
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            self.index[track.id] = [
                "file": name,
                "size": size,
                "lastAccess": Date().timeIntervalSince1970
            ]
            self.saveLocked()
            self.evictLocked(except: track.id)
            self.lock.unlock()
        }.resume()
    }

    var totalBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return index.values.reduce(0) { $0 + Int64(num($1["size"])) }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        for entry in index.values {
            if let name = entry["file"] as? String {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        index = [:]
        saveLocked()
    }

    private func evictLocked(except keepId: String) {
        let limitMB = (UserDefaults.standard.object(forKey: "cacheLimitMB") as? Int) ?? 500
        let limit = Int64(limitMB) * 1024 * 1024
        var total = index.values.reduce(Int64(0)) { $0 + Int64(num($1["size"])) }
        guard total > limit else { return }
        let sorted = index.sorted { num($0.value["lastAccess"]) < num($1.value["lastAccess"]) }
        for (id, entry) in sorted {
            if total <= limit { break }
            if id == keepId { continue }
            if let name = entry["file"] as? String {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            total -= Int64(num(entry["size"]))
            index.removeValue(forKey: id)
        }
        saveLocked()
    }

    private func saveLocked() {
        if let data = try? JSONSerialization.data(withJSONObject: index) {
            try? data.write(to: indexURL)
        }
    }
}
