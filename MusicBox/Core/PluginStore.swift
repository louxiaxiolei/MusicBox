import Foundation

/// 管理已安装的音源插件（保存在 Documents/plugins/*.js）
@MainActor
final class PluginStore: ObservableObject {
    @Published private(set) var plugins: [Plugin] = []
    @Published private(set) var loadErrors: [String: String] = [:]   // 文件名 -> 错误

    private let dir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() {
        Task { await reloadAll() }
    }

    func plugin(id: String) -> Plugin? { plugins.first { $0.id == id } }

    func reloadAll() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Plugin] = []
        var errors: [String: String] = [:]
        for file in files where file.pathExtension == "js" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let script = try? String(contentsOf: file, encoding: .utf8) else { continue }
            do {
                loaded.append(contentsOf: try await Plugin.loadAll(id: id, script: script))
            } catch {
                errors[file.lastPathComponent] = error.localizedDescription
            }
        }
        plugins = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        loadErrors = errors
    }

    /// 安装（或覆盖同名）插件，返回插件名。洛雪脚本会展开成多个平台实例、共用一个文件。
    @discardableResult
    func install(script: String) async throws -> String {
        // 先用临时 id 校验，拿到插件名
        let probe = try await Plugin.loadAll(id: "probe", script: script)
        guard let first = probe.first else { throw PluginError.load("空脚本") }
        let id = Self.fileId(for: first.baseName)
        let plugins = try await Plugin.loadAll(id: id, script: script)
        try script.write(to: dir.appendingPathComponent("\(id).js"), atomically: true, encoding: .utf8)
        self.plugins.removeAll { $0.fileId == id }
        self.plugins.append(contentsOf: plugins)
        self.plugins.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return first.name
    }

    @discardableResult
    func install(from url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PluginError.load("下载失败，HTTP \(http.statusCode)")
        }
        guard let script = String(data: data, encoding: .utf8), !script.isEmpty else {
            throw PluginError.load("文件不是文本")
        }
        return try await install(script: script)
    }

    func update(_ plugin: Plugin) async throws {
        guard let url = URL(string: plugin.info.srcUrl), !plugin.info.srcUrl.isEmpty else {
            throw PluginError.load("该插件没有提供 srcUrl，无法在线更新")
        }
        try await install(from: url)
    }

    func remove(_ plugin: Plugin) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(plugin.fileId).js"))
        plugins.removeAll { $0.fileId == plugin.fileId }
    }

    func removeBroken(_ fileName: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
        loadErrors[fileName] = nil
    }

    func installBundledExample() async throws {
        guard let url = Bundle.main.url(forResource: "example-archive", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            throw PluginError.load("找不到内置示例")
        }
        try await install(script: script)
    }

    private static func fileId(for name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.newlines)
        let cleaned = name.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }
}
