import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: PluginStore
    @EnvironmentObject var player: Player
    @EnvironmentObject var ui: UIState

    @State private var keyword = ""
    @State private var selectedId = ""
    @State private var results: [Track] = []
    @State private var page = 1
    @State private var isEnd = true
    @State private var loading = false
    @State private var error: String?
    @State private var searched = ""
    @State private var searchTask: Task<Void, Never>?

    private var selected: Plugin? {
        store.plugin(id: selectedId) ?? store.plugins.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.plugins.isEmpty {
                    VStack {
                        EmptyHint(icon: "puzzlepiece.extension",
                                  title: "还没有音源",
                                  message: "先去「音源」页导入一个音源插件，才能搜索和播放。")
                        Button("去添加音源") { ui.tab = 2 }
                            .buttonStyle(.borderedProminent)
                            .padding(.bottom, 80)
                    }
                } else {
                    resultList
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $keyword, placement: .navigationBarDrawer(displayMode: .always), prompt: "歌曲、歌手、专辑")
            .onSubmit(of: .search) { runSearch(reset: true) }
            .toolbar {
                if store.plugins.count > 0 {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Picker("音源", selection: Binding(
                                get: { selected?.id ?? "" },
                                set: { selectedId = $0; if !searched.isEmpty { runSearch(reset: true) } }
                            )) {
                                ForEach(store.plugins) { p in
                                    Text(p.name).tag(p.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selected?.name ?? "音源").lineLimit(1)
                                Image(systemName: "chevron.down").font(.caption)
                            }
                        }
                    }
                }
            }
            .miniPlayerInset()
        }
    }

    private var resultList: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
            if results.isEmpty && !loading && searched.isEmpty {
                Section {
                    Text("在上方输入关键词，回车搜索。当前音源：\(selected?.name ?? "-")")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if results.isEmpty && !loading && error == nil {
                Section { Text("没有找到「\(searched)」相关的歌曲").foregroundColor(.secondary) }
            }

            if !results.isEmpty {
                Section {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track)
                            .onTapGesture { player.play(results, startAt: i) }
                    }
                } header: {
                    HStack {
                        Text("\(selected?.name ?? "") · \(results.count) 首")
                        Spacer()
                        Button {
                            player.play(results, startAt: 0)
                        } label: {
                            Label("全部播放", systemImage: "play.circle.fill")
                                .font(.caption)
                        }
                    }
                }
            }

            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            } else if !isEnd && !results.isEmpty {
                Button("加载更多") { runSearch(reset: false) }
                    .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
    }

    private func runSearch(reset: Bool) {
        let kw = (reset ? keyword : searched).trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, let plugin = selected else { return }
        searchTask?.cancel()
        if reset {
            results = []
            page = 1
            isEnd = true
        }
        searched = kw
        error = nil
        loading = true
        let p = page
        searchTask = Task { @MainActor in
            do {
                let res = try await plugin.search(kw, page: p)
                if Task.isCancelled { return }
                let existing = Set(results.map(\.id))
                results += res.tracks.filter { !existing.contains($0.id) }
                isEnd = res.isEnd || res.tracks.isEmpty
                page = p + 1
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
