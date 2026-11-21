import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject var store: PluginStore

    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var showPaste = false
    @State private var showImporter = false
    @State private var busy = false
    @State private var message: String?
    @State private var showFormat = false

    var body: some View {
        NavigationStack {
            List {
                if store.plugins.isEmpty && store.loadErrors.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没有音源").font(.headline)
                            Text("点右上角 + 从链接、剪贴板或文件导入音源插件（.js）。也可以先装一个内置示例试试。")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button("安装示例音源（Internet Archive）") { run { try await store.installBundledExample(); return "已安装示例音源" } }
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 6)
                    }
                }

                if !store.plugins.isEmpty {
                    Section("已安装") {
                        ForEach(store.plugins) { p in
                            PluginRow(plugin: p)
                                .contextMenu {
                                    if !p.info.srcUrl.isEmpty {
                                        Button { run { try await store.update(p); return "「\(p.name)」已更新" } } label: {
                                            Label("在线更新", systemImage: "arrow.triangle.2.circlepath")
                                        }
                                        Button { UIPasteboard.general.string = p.info.srcUrl } label: {
                                            Label("复制订阅地址", systemImage: "link")
                                        }
                                    }
                                    Button(role: .destructive) { store.remove(p) } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                        .onDelete { offsets in
                            for p in offsets.map({ store.plugins[$0] }) { store.remove(p) }
                        }
                    }
                }

                if !store.loadErrors.isEmpty {
                    Section("加载失败") {
                        ForEach(store.loadErrors.keys.sorted(), id: \.self) { name in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name).font(.subheadline.weight(.semibold))
                                Text(store.loadErrors[name] ?? "").font(.caption).foregroundColor(.red)
                            }
                            .swipeActions {
                                Button(role: .destructive) { store.removeBroken(name) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section {
                    Button { showFormat = true } label: {
                        Label("音源插件格式说明", systemImage: "doc.text")
                    }
                } footer: {
                    Text("音乐盒本身不提供任何音乐内容，所有内容来自你自行导入的音源插件。请只使用你有权访问的内容来源。")
                }
            }
            .navigationTitle("音源")
            .refreshable { await store.reloadAll() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if busy {
                        ProgressView()
                    } else {
                        Menu {
                            Button { urlText = ""; showURLPrompt = true } label: {
                                Label("从链接导入", systemImage: "link")
                            }
                            Button { showPaste = true } label: {
                                Label("粘贴脚本", systemImage: "doc.on.clipboard")
                            }
                            Button { showImporter = true } label: {
                                Label("从文件导入", systemImage: "folder")
                            }
                            Divider()
                            Button { run { try await store.installBundledExample(); return "已安装示例音源" } } label: {
                                Label("安装示例音源", systemImage: "sparkles")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .alert("从链接导入", isPresented: $showURLPrompt) {
                TextField("https://.../plugin.js", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("取消", role: .cancel) {}
                Button("导入") {
                    guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        message = "链接格式不对"
                        return
                    }
                    run { let n = try await store.install(from: url); return "已导入「\(n)」" }
                }
            } message: {
                Text("输入音源插件 .js 的下载地址")
            }
            .sheet(isPresented: $showPaste) {
                PasteScriptView { script in
                    run { let n = try await store.install(script: script); return "已导入「\(n)」" }
                }
            }
            .sheet(isPresented: $showFormat) {
                FormatHelpView()
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.javaScript, .plainText, .data],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                run {
                    var names: [String] = []
                    for url in urls {
                        let ok = url.startAccessingSecurityScopedResource()
                        defer { if ok { url.stopAccessingSecurityScopedResource() } }
                        let script = try String(contentsOf: url, encoding: .utf8)
                        names.append(try await store.install(script: script))
                    }
                    return "已导入：\(names.joined(separator: "、"))"
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            }
            .miniPlayerInset()
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> String?) {
        busy = true
        Task { @MainActor in
            do {
                message = try await action()
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

}

struct PluginRow: View {
    let plugin: Plugin

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.title3)
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if !plugin.info.version.isEmpty { Text("v\(plugin.info.version)") }
                    if !plugin.info.author.isEmpty { Text(plugin.info.author) }
                    if plugin.info.hasLyric { Text("歌词") }
                    if !plugin.info.srcUrl.isEmpty { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct PasteScriptView: View {
    let onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 8)
                .navigationTitle("粘贴脚本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .principal) {
                        Button("从剪贴板粘贴") { text = UIPasteboard.general.string ?? "" }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入") {
                            onImport(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

struct FormatHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let sample = """
    module.exports = {
      platform: "我的音源",     // 名称（必填）
      version: "1.0.0",
      author: "me",
      srcUrl: "https://.../me.js", // 可选，用于在线更新

      // 必填：返回 { isEnd, data: [歌曲] }
      async search(keyword, page, type) {
        const res = await axios.get("https://api.example.com/search",
          { params: { q: keyword, page } });
        return {
          isEnd: res.data.end,
          data: res.data.list.map(s => ({
            id: s.id, title: s.name, artist: s.singer,
            album: s.album, artwork: s.cover, duration: s.seconds
          }))
        };
      },

      // 必填：返回播放地址 { url, headers? } 或字符串
      async getMediaSource(musicItem, quality) {
        return { url: "https://.../" + musicItem.id + ".mp3" };
      },

      // 可选：返回 { rawLrc: "[00:01.00]..." }
      async getLyric(musicItem) {
        return { rawLrc: "" };
      }
    };
    """

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("音源插件是一个 JavaScript 文件，接口与 MusicFree 插件基本一致（search / getMediaSource / getLyric）。")
                    Text("也支持洛雪（LX Music）自定义源脚本：导入后会按脚本声明的平台展开成多个音源（酷我/酷狗/QQ/网易云/咪咕），搜索由应用内置实现，播放地址由脚本解析。")
                    Text("可用的内置对象").font(.headline)
                    Text("""
                    • axios（get/post/request，常用子集）
                    • fetch(url, opts)、http.get / http.post
                    • require('axios' | 'qs' | 'crypto-js')
                    • crypto-js 仅支持 MD5/SHA1/SHA256 和 Base64/Utf8
                    • utils.md5 / sha1 / sha256 / base64Encode / base64Decode
                    • console.log、setTimeout、btoa、atob
                    """)
                    .font(.subheadline)
                    Text("示例").font(.headline)
                    Text(sample)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
                        .textSelection(.enabled)
                }
                .padding()
            }
            .navigationTitle("插件格式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
