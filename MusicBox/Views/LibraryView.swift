import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @State private var segment = 0
    @State private var showSettings = false
    @State private var cacheBytes: Int64 = 0
    @AppStorage("preferredQuality") private var preferredQuality = "320k"
    @AppStorage("cacheLimitMB") private var cacheLimitMB = 500

    private var cacheSizeText: String {
        ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    private var tracks: [Track] { segment == 0 ? library.favorites : library.recent }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text("收藏 \(library.favorites.count)").tag(0)
                    Text("最近播放").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if tracks.isEmpty {
                    EmptyHint(icon: segment == 0 ? "heart" : "clock",
                              title: segment == 0 ? "还没有收藏" : "还没有播放记录",
                              message: segment == 0 ? "在歌曲上长按，或在播放页点 ♥ 收藏" : "")
                } else {
                    List {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                            TrackRow(track: track, showSource: true)
                                .onTapGesture { player.play(tracks, startAt: i) }
                        }
                        .onDelete(perform: segment == 0 ? { library.removeFavorites(at: $0) } : nil)
                        .onMove(perform: segment == 0 ? { library.moveFavorites(from: $0, to: $1) } : nil)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("我的")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !tracks.isEmpty {
                        Button {
                            player.play(tracks, startAt: 0)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                    }
                    if segment == 0 && !library.favorites.isEmpty {
                        EditButton()
                    }
                    if segment == 1 && !library.recent.isEmpty {
                        Button("清空") { library.clearRecent() }
                    }
                }
            }
            .miniPlayerInset()
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    Form {
                        Section {
                            Picker("默认音质", selection: $preferredQuality) {
                                Text("标准 · 128k").tag("128k")
                                Text("高品质 · 320k").tag("320k")
                                Text("无损 · flac").tag("flac")
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } header: {
                            Text("播放音质")
                        } footer: {
                            Text("所选音质取址失败时会自动降一档重试；音源不支持所选音质时，用它能提供的最接近的音质。")
                        }
                        Section {
                            Picker("缓存上限", selection: $cacheLimitMB) {
                                Text("200 MB").tag(200)
                                Text("500 MB").tag(500)
                                Text("1 GB").tag(1024)
                                Text("2 GB").tag(2048)
                            }
                            HStack {
                                Text("当前占用")
                                Spacer()
                                Text(cacheSizeText).foregroundColor(.secondary)
                            }
                            Button("清除缓存", role: .destructive) {
                                AudioCache.shared.clear()
                                cacheBytes = 0
                            }
                        } header: {
                            Text("听歌缓存")
                        } footer: {
                            Text("播过的歌会自动存到本地，重播直接放本地文件、断网也能听；超上限时先清最久没听的。")
                        }
                    }
                    .onAppear { cacheBytes = AudioCache.shared.totalBytes }
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showSettings = false }
                        }
                    }
                }
            }
        }
    }
}
