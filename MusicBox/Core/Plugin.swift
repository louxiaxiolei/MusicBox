import Foundation
import JavaScriptCore
import CryptoKit

final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

enum PluginError: LocalizedError {
    case load(String)
    case call(String)
    case timeout
    case badResult(String)

    var errorDescription: String? {
        switch self {
        case .load(let m): return "加载音源失败：\(m)"
        case .call(let m): return m
        case .timeout: return "音源响应超时"
        case .badResult(let m): return "音源返回格式不对：\(m)"
        }
    }
}

struct PluginInfo: Decodable {
    let name: String
    let version: String
    let author: String
    let srcUrl: String
    let hasSearch: Bool
    let hasLyric: Bool
}

/// 一个音源插件。每个插件有独立的 JSContext 和串行队列，所有 JS 调用都在该队列上执行。
final class Plugin: Identifiable {
    let id: String          // 文件名
    let info: PluginInfo
    let script: String
    private let context: JSContext
    private let queue: DispatchQueue

    var name: String { info.name.isEmpty ? id : info.name }

    private init(id: String, info: PluginInfo, script: String, context: JSContext, queue: DispatchQueue) {
        self.id = id
        self.info = info
        self.script = script
        self.context = context
        self.queue = queue
    }

    // MARK: - 加载

    static func load(id: String, script: String) async throws -> Plugin {
        let queue = DispatchQueue(label: "musicbox.plugin.\(id)")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Plugin, Error>) in
            queue.async {
                do {
                    cont.resume(returning: try Plugin.make(id: id, script: script, queue: queue))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func make(id: String, script: String, queue: DispatchQueue) throws -> Plugin {
        guard let ctx = JSContext() else { throw PluginError.load("无法创建 JS 环境") }
        ctx.name = id
        let lastError = Box<String?>(nil)
        ctx.exceptionHandler = { _, exc in
            let msg = exc?.toString() ?? "未知错误"
            let line = exc?.objectForKeyedSubscript("line")?.toString() ?? ""
            lastError.value = (line.isEmpty || line == "undefined") ? msg : "\(msg)（第 \(line) 行）"
            print("[Plugin \(id)] JS 异常: \(lastError.value ?? "")")
        }

        installNatives(ctx, id: id, queue: queue)
        ctx.evaluateScript(pluginRuntimeJS)
        if let e = lastError.value { throw PluginError.load("运行时初始化失败 \(e)") }

        // 包一层函数作用域，避免插件里的 const/let 与运行时全局变量冲突
        let wrapped = "(function(module, exports, require){\n" + script + "\n})(module, module.exports, require);"
        ctx.evaluateScript(wrapped, withSourceURL: URL(string: "plugin://\(id)"))
        if let e = lastError.value { throw PluginError.load(e) }

        guard let infoStr = ctx.objectForKeyedSubscript("__info")?.call(withArguments: [])?.toString(),
              let info = try? JSONDecoder().decode(PluginInfo.self, from: Data(infoStr.utf8)) else {
            throw PluginError.load("读取插件信息失败 \(lastError.value ?? "")")
        }
        guard info.hasSearch else { throw PluginError.load("插件没有实现 search 方法") }
        return Plugin(id: id, info: info, script: script, context: ctx, queue: queue)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func installNatives(_ ctx: JSContext, id: String, queue: DispatchQueue) {
        let log: @convention(block) (String) -> Void = { print("[Plugin \(id)] \($0)") }
        ctx.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "__log" as NSString)

        let hash: @convention(block) (String, String) -> String = { algo, s in
            let d = Data(s.utf8)
            switch algo {
            case "md5": return Plugin.hex(Insecure.MD5.hash(data: d))
            case "sha1": return Plugin.hex(Insecure.SHA1.hash(data: d))
            default: return Plugin.hex(SHA256.hash(data: d))
            }
        }
        ctx.setObject(unsafeBitCast(hash, to: AnyObject.self), forKeyedSubscript: "__hash" as NSString)

        let b64e: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        ctx.setObject(unsafeBitCast(b64e, to: AnyObject.self), forKeyedSubscript: "__b64encode" as NSString)

        let b64d: @convention(block) (String) -> String = { s in
            var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while str.count % 4 != 0 { str += "=" }
            guard let d = Data(base64Encoded: str) else { return "" }
            return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        }
        ctx.setObject(unsafeBitCast(b64d, to: AnyObject.self), forKeyedSubscript: "__b64decode" as NSString)

        let timeout: @convention(block) (JSValue, Double) -> Void = { fn, ms in
            queue.asyncAfter(deadline: .now() + max(0, ms) / 1000) { _ = fn.call(withArguments: []) }
        }
        ctx.setObject(unsafeBitCast(timeout, to: AnyObject.self), forKeyedSubscript: "__setTimeout" as NSString)

        let request: @convention(block) (String, JSValue) -> Void = { json, callback in
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                  let urlStr = obj["url"] as? String,
                  let url = URL(string: urlStr)
                    ?? URL(string: urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "%#"))) ?? "")
            else {
                _ = callback.call(withArguments: ["无效的请求地址", NSNull()])
                return
            }
            var req = URLRequest(url: url)
            req.httpMethod = (obj["method"] as? String) ?? "GET"
            req.timeoutInterval = (obj["timeout"] as? Double) ?? 20
            if let headers = obj["headers"] as? [String: String] {
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            }
            if let body = obj["body"] as? String { req.httpBody = Data(body.utf8) }

            URLSession.shared.dataTask(with: req) { data, resp, err in
                var payload: String?
                var errMsg: String?
                if let err = err {
                    errMsg = err.localizedDescription
                } else {
                    let http = resp as? HTTPURLResponse
                    var headers: [String: String] = [:]
                    http?.allHeaderFields.forEach { headers["\($0.key)".lowercased()] = "\($0.value)" }
                    let body = data.flatMap {
                        String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1)
                    } ?? ""
                    let result: [String: Any] = ["status": http?.statusCode ?? 0, "headers": headers, "body": body]
                    if let d = try? JSONSerialization.data(withJSONObject: result) {
                        payload = String(data: d, encoding: .utf8)
                    } else {
                        errMsg = "响应解析失败"
                    }
                }
                queue.async {
                    if let payload = payload {
                        _ = callback.call(withArguments: [NSNull(), payload])
                    } else {
                        _ = callback.call(withArguments: [errMsg ?? "请求失败", NSNull()])
                    }
                }
            }.resume()
        }
        ctx.setObject(unsafeBitCast(request, to: AnyObject.self), forKeyedSubscript: "__request" as NSString)
    }

    // MARK: - 调用

    /// 调用插件导出的方法，参数和返回值都走 JSON。
    func invoke(_ method: String, _ args: [Any], timeout: Double = 30) async throws -> Any {
        let argsData = try JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed])
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
        let context = self.context
        let queue = self.queue
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            queue.async {
                let done = Box(false)
                let finish: (Result<Any, Error>) -> Void = { r in
                    if done.value { return }
                    done.value = true
                    cont.resume(with: r)
                }
                let ok: @convention(block) (String) -> Void = { s in
                    let v = (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) ?? NSNull()
                    finish(.success(v))
                }
                let fail: @convention(block) (String) -> Void = { m in
                    finish(.failure(PluginError.call(m)))
                }
                guard let invoker = context.objectForKeyedSubscript("__invoke") else {
                    finish(.failure(PluginError.call("插件运行时丢失")))
                    return
                }
                _ = invoker.call(withArguments: [method, argsJSON, unsafeBitCast(ok, to: AnyObject.self), unsafeBitCast(fail, to: AnyObject.self)])
                queue.asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(PluginError.timeout))
                }
            }
        }
    }

    func search(_ keyword: String, page: Int) async throws -> SearchPage {
        let r = try await invoke("search", [keyword, page, "music"])
        var items: [Any] = []
        var isEnd = true
        if let arr = r as? [Any] {
            items = arr
            isEnd = arr.isEmpty
        } else if let d = r as? [String: Any] {
            items = (d["data"] as? [Any]) ?? (d["list"] as? [Any]) ?? []
            isEnd = (d["isEnd"] as? Bool) ?? items.isEmpty
        } else {
            throw PluginError.badResult("search 应返回 {isEnd, data} 或数组")
        }
        let tracks = items.compactMap { item -> Track? in
            guard let dict = item as? [String: Any] else { return nil }
            return Track(pluginId: id, dict: dict)
        }
        return SearchPage(tracks: tracks, isEnd: isEnd)
    }

    func mediaSource(for track: Track, quality: String = "standard") async throws -> MediaSource {
        let r = try await invoke("getMediaSource", [track.rawObject, quality])
        var urlStr: String?
        var headers: [String: String] = [:]
        if let s = r as? String {
            urlStr = s
        } else if let d = r as? [String: Any] {
            urlStr = d["url"] as? String
            headers = (d["headers"] as? [String: String]) ?? [:]
            if let ua = d["userAgent"] as? String { headers["User-Agent"] = ua }
        }
        guard let s = urlStr, let url = URL(string: s) else {
            throw PluginError.badResult("没有拿到播放地址")
        }
        return MediaSource(url: url, headers: headers)
    }

    func lyric(for track: Track) async throws -> String? {
        guard info.hasLyric else { return nil }
        let r = try await invoke("getLyric", [track.rawObject])
        if let s = r as? String { return s }
        if let d = r as? [String: Any] {
            return (d["rawLrc"] as? String) ?? (d["lrc"] as? String) ?? (d["lyric"] as? String)
        }
        return nil
    }
}
