import SwiftUI
import UIKit

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
    @State private var charts: [(id: String, name: String, img: String)] = []
    @State private var artists: [(id: String, name: String, img: String)] = []
    @State private var chartTitle: String?

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
                                set: { selectedId = $0
                                       if chartTitle != nil { chartTitle = nil; results = [] }
                                       if !searched.isEmpty { runSearch(reset: true) } }
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
            .task(id: selected?.id ?? "") { await loadCharts() }
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
                if !charts.isEmpty {
                    Section {
                        ForEach(charts, id: \.id) { chart in
                            Button {
                                loadChart(chart)
                            } label: {
                                HStack {
                                    ArtworkView(url: chart.img.isEmpty ? nil : chart.img, size: 40)
                                    Text(chart.name).foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("排行榜")
                    }
                }
                if !artists.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(artists, id: \.id) { artist in
                                    Button {
                                        loadArtist(artist)
                                    } label: {
                                        VStack(spacing: 6) {
                                            ArtworkView(url: artist.img.isEmpty ? nil : artist.img, size: 60, corner: 30)
                                            Text(artist.name)
                                                .font(.caption)
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                                .frame(width: 64)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    } header: {
                        Text("歌手榜")
                    }
                }
            } else if results.isEmpty && !loading && error == nil {
                Section { Text("没有找到「\(searched)」相关的歌曲").foregroundColor(.secondary) }
            }

            if !results.isEmpty {
                if let chartTitle {
                    Section {
                        Button {
                            self.chartTitle = nil
                            results = []
                        } label: {
                            Label("返回", systemImage: "chevron.backward")
                                .font(.footnote)
                        }
                    }
                }
                Section {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track)
                            .onTapGesture { player.play(results, startAt: i) }
                    }
                } header: {
                    HStack {
                        Text(chartTitle != nil ? "\(chartTitle!) · \(results.count) 首" : "\(selected?.name ?? "") · \(results.count) 首")
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
                HStack {
                    Spacer()
                    ProgressView()
                    if !results.isEmpty { Text("正在加载全部结果…").font(.footnote).foregroundColor(.secondary) }
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } else if !isEnd && !results.isEmpty {
                Button("加载更多") { runSearch(reset: false) }
                    .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        // 榜单/歌手歌曲列表里支持横滑返回（左上角「返回」按钮保留）：左右滑任意位置起手都行，
        // 但要求横移足够远且方向足够横，避免上下滚动时误触发。
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard chartTitle != nil else { return }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > 100, abs(dx) > 2.5 * abs(dy) else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    chartTitle = nil
                    results = []
                }
        )
    }

    private func runSearch(reset: Bool) {
        let kw = (reset ? keyword : searched).trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, let plugin = selected else { return }
        searchTask?.cancel()
        if reset {
            results = []
            page = 1
            isEnd = true
            chartTitle = nil
        }
        searched = kw
        error = nil
        loading = true
        searchTask = Task { @MainActor in
            var p = page
            // 自动连续加载后续页，直到最后一页为止，全部列出来（上限 100 页防失控，
            // 搜索新关键词或切换音源会取消）
            while p <= 100 {
                do {
                    let res = try await plugin.search(kw, page: p)
                    if Task.isCancelled { return }
                    let existing = Set(results.map(\.id))
                    results += res.tracks.filter { !existing.contains($0.id) }
                    isEnd = res.isEnd || res.tracks.isEmpty
                    page = p + 1
                    if isEnd { break }
                } catch {
                    if Task.isCancelled { return }
                    self.error = error.localizedDescription
                    break
                }
                p += 1
            }
            loading = false
        }
    }

    private func loadCharts() async {
        guard let plugin = selected else {
            charts = []
            artists = []
            return
        }
        let pid = plugin.id
        if plugin.supportsCharts, let list = try? await plugin.charts(), selected?.id == pid {
            charts = list
        } else if !plugin.supportsCharts {
            charts = []
        }
        if plugin.supportsArtists, let list = try? await plugin.artists(), selected?.id == pid {
            artists = list
        } else if !plugin.supportsArtists {
            artists = []
        }
    }

    private func loadChart(_ chart: (id: String, name: String, img: String)) {
        guard let plugin = selected else { return }
        searchTask?.cancel()
        results = []
        searched = ""
        error = nil
        loading = true
        searchTask = Task { @MainActor in
            do {
                let tracks = try await plugin.chartTracks(chart.id)
                if Task.isCancelled { return }
                results = tracks
                isEnd = true
                chartTitle = chart.name
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func loadArtist(_ artist: (id: String, name: String, img: String)) {
        guard let plugin = selected else { return }
        searchTask?.cancel()
        results = []
        searched = ""
        error = nil
        loading = true
        searchTask = Task { @MainActor in
            do {
                let tracks = try await plugin.artistTracks(artist.id)
                if Task.isCancelled { return }
                results = tracks
                isEnd = true
                chartTitle = "\(artist.name) 的热门歌曲"
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
