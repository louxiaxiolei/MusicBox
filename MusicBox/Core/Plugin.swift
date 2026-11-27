import Foundation
import JavaScriptCore
import CryptoKit
import Compression

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

/// 洛雪脚本头部注释里的元信息
struct LXHeader {
    var name = ""
    var version = ""
    var author = ""
    var description = ""
    var homepage = ""
}

/// 一个音源插件。每个插件有独立的 JSContext 和串行队列，所有 JS 调用都在该队列上执行。
/// 洛雪（LX）脚本没有搜索能力，加载后会按其声明的平台展开成多个实例：
/// 每个实例负责一个平台（内置搜索 + 调脚本取址），id 形如 "文件id#kw"。
final class Plugin: Identifiable {
    let id: String          // 实例 id（洛雪为 "文件id#平台"，其余等于文件 id）
    let fileId: String      // 对应的插件文件名（不含扩展名）
    let info: PluginInfo
    let script: String
    let lxSource: String?   // 洛雪平台 key（kw/kg/tx/wy/mg）；nil 表示普通 MusicFree 插件
    private let lxQualitys: [String]
    private let headerName: String?
    private let context: JSContext
    private let queue: DispatchQueue

    var name: String { info.name.isEmpty ? id : info.name }
    /// 文件命名依据的名字（洛雪取脚本头 @name，普通插件取插件名）
    var baseName: String { headerName ?? name }

    private init(id: String, fileId: String, info: PluginInfo, script: String,
                 lxSource: String?, lxQualitys: [String], headerName: String?,
                 context: JSContext, queue: DispatchQueue) {
        self.id = id
        self.fileId = fileId
        self.info = info
        self.script = script
        self.lxSource = lxSource
        self.lxQualitys = lxQualitys
        self.headerName = headerName
        self.context = context
        self.queue = queue
    }

    var isLX: Bool { lxSource != nil }

    // MARK: - 加载

    static let lxPlatformOrder = ["kw", "kg", "tx", "wy", "mg"]
    static let lxPlatformLabels = ["kw": "酷我音乐", "kg": "酷狗音乐", "tx": "QQ音乐", "wy": "网易云音乐", "mg": "咪咕音乐"]

    /// 加载一个脚本文件，返回一个或多个插件实例（洛雪脚本按声明的平台展开）。
    static func loadAll(id: String, script: String) async throws -> [Plugin] {
        let queue = DispatchQueue(label: "musicbox.plugin.\(id)")
        let (ctx, lastError) = try await buildContext(id: id, script: script, queue: queue)

        // 首次读取也在插件队列上做，避免与 JS 定时器并发访问 JSContext
        let (mfInfo, firstInited) = await withCheckedContinuation { (cont: CheckedContinuation<(PluginInfo?, [(String, [String], String)]?), Never>) in
            queue.async { cont.resume(returning: (readInfo(ctx), readLXInited(ctx))) }
        }
        if let info = mfInfo, info.hasSearch {
            return [Plugin(id: id, fileId: id, info: info, script: script,
                           lxSource: nil, lxQualitys: [], headerName: nil,
                           context: ctx, queue: queue)]
        }

        // 洛雪脚本可能异步发送 inited（等最多约 3 秒）
        var inited = firstInited
        if inited == nil {
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                // 在插件队列上重新读一次，保证 JS 已执行完挂起的回调
                inited = await readLXInitedAsync(ctx, queue: queue)
                if inited != nil { break }
            }
        }
        guard let decl = inited else {
            throw PluginError.load(lastError.value ?? "插件没有实现 search 方法，也不是洛雪音源")
        }
        let header = parseLXHeader(script)
        var plugins: [Plugin] = []
        for (source, qualitys, displayName) in decl {
            let subQueue = DispatchQueue(label: "musicbox.plugin.\(id).\(source)")
            let (subCtx, _) = try await buildContext(id: "\(id)#\(source)", script: script, queue: subQueue)
            let base = header.name.isEmpty ? "洛雪音源" : header.name
            let info = PluginInfo(name: "\(base) · \(displayName)",
                                  version: header.version, author: header.author,
                                  srcUrl: "", hasSearch: true, hasLyric: true)
            plugins.append(Plugin(id: "\(id)#\(source)", fileId: id, info: info, script: script,
                                  lxSource: source, lxQualitys: qualitys,
                                  headerName: header.name.isEmpty ? nil : header.name,
                                  context: subCtx, queue: subQueue))
        }
        if plugins.isEmpty {
            throw PluginError.load("洛雪音源没有声明可用的音乐平台（需要 musicUrl）")
        }
        return plugins
    }

    /// 兼容旧调用：返回第一个实例
    static func load(id: String, script: String) async throws -> Plugin {
        guard let first = try await loadAll(id: id, script: script).first else {
            throw PluginError.load("空脚本")
        }
        return first
    }

    private static func readInfo(_ ctx: JSContext) -> PluginInfo? {
        guard let infoStr = ctx.objectForKeyedSubscript("__info")?.call(withArguments: [])?.toString(),
              let info = try? JSONDecoder().decode(PluginInfo.self, from: Data(infoStr.utf8)) else {
            return nil
        }
        return info
    }

    /// 读取洛雪 inited 声明，返回 [(平台, 音质列表, 显示名)]（按平台固定顺序）
    private static func readLXInited(_ ctx: JSContext) -> [(String, [String], String)]? {
        guard let json = ctx.objectForKeyedSubscript("__lxInitedJSON")?.call(withArguments: [])?.toString(),
              json != "null",
              let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let sources = obj["sources"] as? [String: Any] else {
            return nil
        }
        var out: [(String, [String], String)] = []
        for key in lxPlatformOrder {
            guard let d = sources[key] as? [String: Any] else { continue }
            let type = d["type"] as? String ?? "music"
            let actions = (d["actions"] as? [Any])?.compactMap { $0 as? String } ?? []
            guard type == "music", actions.contains("musicUrl") else { continue }
            let qualitys = (d["qualitys"] as? [Any])?.compactMap { $0 as? String } ?? []
            let declaredName = d["name"] as? String ?? ""
            let display = (declaredName.isEmpty || declaredName == key) ? (lxPlatformLabels[key] ?? key) : declaredName
            out.append((key, qualitys, display))
        }
        return out.isEmpty ? nil : out
    }

    private static func readLXInitedAsync(_ ctx: JSContext, queue: DispatchQueue) async -> [(String, [String], String)]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[(String, [String], String)]?, Never>) in
            queue.async { cont.resume(returning: readLXInited(ctx)) }
        }
    }

    static func parseLXHeader(_ script: String) -> LXHeader {
        var h = LXHeader()
        let head = String(script.prefix(6000))
        guard let re = try? NSRegularExpression(pattern: "@(name|description|version|author|homepage)\\s+([^\\n\\r]+)") else { return h }
        for m in re.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
            guard let kr = Range(m.range(at: 1), in: head), let vr = Range(m.range(at: 2), in: head) else { continue }
            var value = String(head[vr]).trimmingCharacters(in: .whitespaces)
            if value.hasSuffix("*/") { value = String(value.dropLast(2)).trimmingCharacters(in: .whitespaces) }
            switch String(head[kr]) {
            case "name": if h.name.isEmpty { h.name = value }
            case "version": if h.version.isEmpty { h.version = value }
            case "author": if h.author.isEmpty { h.author = value }
            case "description": if h.description.isEmpty { h.description = value }
            case "homepage": if h.homepage.isEmpty { h.homepage = value }
            default: break
            }
        }
        return h
    }

    private static func buildContext(id: String, script: String, queue: DispatchQueue) async throws -> (JSContext, Box<String?>) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(JSContext, Box<String?>), Error>) in
            queue.async {
                do {
                    cont.resume(returning: try buildContextSync(id: id, script: script, queue: queue))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func buildContextSync(id: String, script: String, queue: DispatchQueue) throws -> (JSContext, Box<String?>) {
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

        // 洛雪兼容层：注入 lx 全局、脚本头信息与内置平台搜索
        lastError.value = nil
        ctx.evaluateScript(lxRuntimeJS)
        if let e = lastError.value { throw PluginError.load("洛雪兼容层初始化失败 \(e)") }
        let header = parseLXHeader(script)
        let infoObj: [String: Any] = ["name": header.name, "version": header.version,
                                      "author": header.author, "description": header.description,
                                      "homepage": header.homepage, "rawScript": script]
        if let d = try? JSONSerialization.data(withJSONObject: infoObj),
           let s = String(data: d, encoding: .utf8) {
            _ = ctx.objectForKeyedSubscript("__lxSetScriptInfo")?.call(withArguments: [s])
        }
        ctx.evaluateScript(lxSearchJS)
        if let e = lastError.value { throw PluginError.load("洛雪兼容层初始化失败 \(e)") }

        // 包一层函数作用域，避免插件里的 const/let 与运行时全局变量冲突
        lastError.value = nil
        let wrapped = "(function(module, exports, require){\n" + script + "\n})(module, module.exports, require);"
        ctx.evaluateScript(wrapped, withSourceURL: URL(string: "plugin://\(id)"))
        if let e = lastError.value { throw PluginError.load(e) }
        return (ctx, lastError)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// zlib 压缩/解压（RFC1950，与 Node zlib 的 deflate/inflate 对应）
    private static func zlibData(_ data: Data, inflate: Bool) -> Data? {
        if data.isEmpty { return Data() }
        var capacity = inflate ? max(data.count * 8, 4096) : data.count + 4096
        for _ in 0..<8 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                data.withUnsafeBytes { src -> Int in
                    guard let d = dst.baseAddress, let s = src.baseAddress else { return 0 }
                    if inflate {
                        return compression_decode_buffer(d.assumingMemoryBound(to: UInt8.self), capacity,
                                                         s.assumingMemoryBound(to: UInt8.self), data.count, nil, COMPRESSION_ZLIB)
                    } else {
                        return compression_encode_buffer(d.assumingMemoryBound(to: UInt8.self), capacity,
                                                         s.assumingMemoryBound(to: UInt8.self), data.count, nil, COMPRESSION_ZLIB)
                    }
                }
            }
            if written > 0 {
                out.count = written
                return out
            }
            if !inflate { return nil }
            capacity *= 4
        }
        return nil
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

        let randomB64: @convention(block) (Int) -> String = { n in
            guard n > 0 else { return "" }
            let bytes = (0..<n).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
            return Data(bytes).base64EncodedString()
        }
        ctx.setObject(unsafeBitCast(randomB64, to: AnyObject.self), forKeyedSubscript: "__randomB64" as NSString)

        let zlibInflate: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s), let out = Plugin.zlibData(d, inflate: true) else { return "" }
            return out.base64EncodedString()
        }
        ctx.setObject(unsafeBitCast(zlibInflate, to: AnyObject.self), forKeyedSubscript: "__zlibInflateB64" as NSString)

        let zlibDeflate: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s), let out = Plugin.zlibData(d, inflate: false) else { return "" }
            return out.base64EncodedString()
        }
        ctx.setObject(unsafeBitCast(zlibDeflate, to: AnyObject.self), forKeyedSubscript: "__zlibDeflateB64" as NSString)

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

    /// 调用兼容层桥函数（__lxSearchBridge / __lxCallRequest），参数直接传递、结果走 JSON 字符串回调。
    private func callBridge(_ name: String, _ args: [Any], timeout: Double = 60) async throws -> Any {
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
                guard let fn = context.objectForKeyedSubscript(name) else {
                    finish(.failure(PluginError.call("洛雪兼容层丢失")))
                    return
                }
                _ = fn.call(withArguments: args + [unsafeBitCast(ok, to: AnyObject.self), unsafeBitCast(fail, to: AnyObject.self)])
                queue.asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(PluginError.timeout))
                }
            }
        }
    }

    func search(_ keyword: String, page: Int) async throws -> SearchPage {
        if let source = lxSource {
            let r = try await callBridge("__lxSearchBridge", [source, keyword, page], timeout: 60)
            guard let d = r as? [String: Any] else {
                throw PluginError.badResult("搜索返回格式不对")
            }
            let items = (d["list"] as? [Any]) ?? []
            let isEnd = (d["isEnd"] as? Bool) ?? items.isEmpty
            let tracks = items.compactMap { item -> Track? in
                guard let dict = item as? [String: Any] else { return nil }
                return Track(pluginId: id, dict: dict)
            }
            return SearchPage(tracks: tracks, isEnd: isEnd)
        }
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
        if let source = lxSource {
            // 按用户首选音质取址：先试首选，失败自动降档（无损→320→128），
            // 首选该源不支持时用它能提供的最接近的音质
            let pref = UserDefaults.standard.string(forKey: "preferredQuality") ?? "320k"
            let rank = ["128k", "320k", "flac"]
            let declared = rank.filter { lxQualitys.contains($0) }
            var candidates: [String] = []
            if declared.isEmpty {
                candidates = lxQualitys.isEmpty ? ["128k"] : lxQualitys
            } else if let pi = rank.firstIndex(of: pref) {
                if declared.contains(pref) { candidates.append(pref) }
                candidates += declared.filter { (rank.firstIndex(of: $0) ?? 0) < pi }
                    .sorted { (rank.firstIndex(of: $0) ?? 0) > (rank.firstIndex(of: $1) ?? 0) }
                candidates += declared.filter { (rank.firstIndex(of: $0) ?? 0) > pi }
                    .sorted { (rank.firstIndex(of: $0) ?? 0) < (rank.firstIndex(of: $1) ?? 0) }
            } else {
                candidates = declared
            }
            var lastError: Error = PluginError.badResult("没有拿到播放地址")
            for q in candidates {
                do {
                    return try await lxMediaSource(source: source, quality: q, track: track)
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
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

    /// 洛雪源按指定音质取址（mediaSource 的降级循环调用）
    private func lxMediaSource(source: String, quality q: String, track: Track) async throws -> MediaSource {
        let infoObj: [String: Any] = ["musicInfo": track.rawObject, "type": q, "quality": q]
        let infoData = try JSONSerialization.data(withJSONObject: infoObj)
        let infoJSON = String(data: infoData, encoding: .utf8) ?? "{}"
        let r = try await callBridge("__lxCallRequest", [source, "musicUrl", infoJSON], timeout: 45)
        var urlStr: String?
        var headers: [String: String] = [:]
        if let s = r as? String {
            urlStr = s
        } else if let d = r as? [String: Any] {
            urlStr = d["url"] as? String
            headers = (d["headers"] as? [String: String]) ?? [:]
        }
        guard let s = urlStr, let url = URL(string: s) else {
            throw PluginError.badResult("没有拿到播放地址")
        }
        return MediaSource(url: url, headers: headers)
    }

    func lyric(for track: Track) async throws -> String? {
        guard info.hasLyric else { return nil }
        if let source = lxSource {
            // 洛雪平台源本身不提供歌词，走兼容层内置的平台歌词
            let data = try JSONSerialization.data(withJSONObject: track.rawObject)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            let r = try await callBridge("__lxLyricBridge", [source, json], timeout: 30)
            if let s = r as? String, !s.isEmpty { return s }
            return nil
        }
        let r = try await invoke("getLyric", [track.rawObject])
        if let s = r as? String { return s }
        if let d = r as? [String: Any] {
            return (d["rawLrc"] as? String) ?? (d["lrc"] as? String) ?? (d["lyric"] as? String)
        }
        return nil
    }

    /// 是否支持排行榜：洛雪平台源由兼容层内置榜单（咪咕暂无可用榜单接口）
    var supportsCharts: Bool {
        guard let source = lxSource else { return false }
        return source != "mg"
    }

    /// 当前平台的榜单列表 [(id, name, img)]
    func charts() async throws -> [(id: String, name: String, img: String)] {
        guard let source = lxSource else { return [] }
        let r = try await callBridge("__lxChartsBridge", [source], timeout: 45)
        guard let arr = r as? [Any] else { return [] }
        return arr.compactMap { item in
            guard let d = item as? [String: Any],
                  let cid = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return (id: cid, name: name, img: (d["img"] as? String) ?? "")
        }
    }

    /// 平台的全部榜单（「全部榜单」页用，酷狗 56 个、网易云 65 个、QQ 30 个）
    func allCharts() async throws -> [(id: String, name: String, img: String)] {
        guard let source = lxSource else { return [] }
        let r = try await callBridge("__lxAllChartsBridge", [source], timeout: 45)
        guard let arr = r as? [Any] else { return [] }
        return arr.compactMap { item in
            guard let d = item as? [String: Any],
                  let cid = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return (id: cid, name: name, img: (d["img"] as? String) ?? "")
        }
    }

    /// 某个榜单的歌曲（洛雪格式 → Track，取址/歌词走既有流程）
    func chartTracks(_ chartId: String) async throws -> [Track] {
        guard let source = lxSource else { return [] }
        let r = try await callBridge("__lxChartSongsBridge", [source, chartId], timeout: 60)
        guard let arr = r as? [Any] else { return [] }
        return arr.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return Track(pluginId: id, dict: dict)
        }
    }

    /// 是否支持歌手榜（酷狗/网易云/QQ 有平台歌手榜接口，酷我/咪咕暂无）
    var supportsArtists: Bool {
        guard let source = lxSource else { return false }
        return source == "kg" || source == "wy" || source == "tx"
    }

    /// 热门歌手列表 [(id, name, img)]
    func artists() async throws -> [(id: String, name: String, img: String)] {
        guard let source = lxSource else { return [] }
        let r = try await callBridge("__lxArtistsBridge", [source], timeout: 30)
        guard let arr = r as? [Any] else { return [] }
        return arr.compactMap { item in
            guard let d = item as? [String: Any],
                  let aid = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return (id: aid, name: name, img: (d["img"] as? String) ?? "")
        }
    }

    /// 某位歌手的热门歌曲
    func artistTracks(_ artistId: String) async throws -> [Track] {
        guard let source = lxSource else { return [] }
        let r = try await callBridge("__lxArtistSongsBridge", [source, artistId], timeout: 60)
        guard let arr = r as? [Any] else { return [] }
        return arr.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return Track(pluginId: id, dict: dict)
        }
    }
}
