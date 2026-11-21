import Foundation

/// 一首歌。`raw` 保存插件返回的原始 JSON，回传给插件取播放地址/歌词时原样带上。
struct Track: Codable, Identifiable, Hashable {
    let pluginId: String
    let rawId: String
    let title: String
    let artist: String
    let album: String
    let artwork: String?
    let duration: Double?
    let raw: String

    var id: String { "\(pluginId)::\(rawId)" }

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// 从插件返回的字典构造
    init?(pluginId: String, dict: [String: Any]) {
        guard let title = Track.string(dict["title"] ?? dict["name"]), !title.isEmpty else { return nil }
        self.pluginId = pluginId
        self.title = title
        self.rawId = Track.string(dict["id"] ?? dict["songmid"] ?? dict["hash"]) ?? title
        self.artist = Track.string(dict["artist"] ?? dict["singer"]) ?? "未知歌手"
        self.album = Track.string(dict["album"] ?? dict["albumName"]) ?? ""
        self.artwork = Track.string(dict["artwork"] ?? dict["img"] ?? dict["cover"])
        if let d = dict["duration"] as? Double {
            self.duration = d > 10_000 ? d / 1000 : d   // 兼容毫秒
        } else if let s = dict["duration"] as? String, let d = Double(s) {
            self.duration = d
        } else {
            self.duration = nil
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let s = String(data: data, encoding: .utf8) {
            self.raw = s
        } else {
            self.raw = "{}"
        }
    }

    var rawObject: Any {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? [String: Any]()
    }

    private static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let arr as [Any]:
            // 歌手可能是数组 [{name:..}] 或 ["a","b"]
            let names = arr.compactMap { item -> String? in
                if let s = item as? String { return s }
                if let d = item as? [String: Any] { return d["name"] as? String }
                return nil
            }
            return names.isEmpty ? nil : names.joined(separator: " / ")
        default: return nil
        }
    }
}

struct SearchPage {
    let tracks: [Track]
    let isEnd: Bool
}

struct MediaSource {
    let url: URL
    let headers: [String: String]
}

struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    let time: Double
    let text: String

    /// 解析 LRC 歌词
    static func parse(_ lrc: String) -> [LyricLine] {
        var result: [LyricLine] = []
        let pattern = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        for line in lrc.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = pattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                result.append(LyricLine(time: min * 60 + sec + frac, text: text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}

enum PlayMode: String, CaseIterable, Codable {
    case sequence, repeatOne, shuffle

    var icon: String {
        switch self {
        case .sequence: return "repeat"
        case .repeatOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }

    var next: PlayMode {
        let all = PlayMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
}
