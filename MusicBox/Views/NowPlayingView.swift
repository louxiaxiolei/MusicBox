import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: PluginStore
    @Environment(\.dismiss) private var dismiss

    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var dragging = false
    @State private var dragValue: Double = 0
    @State private var showTimerOptions = false
    @State private var showCustomTimer = false
    @State private var customMinutes = ""

    var body: some View {
        ZStack {
            background
            if let t = player.current {
                VStack(spacing: 18) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 40, height: 5)
                        .padding(.top, 8)

                    Group {
                        if showLyrics {
                            LyricsView()
                        } else {
                            cover(t)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut) { showLyrics.toggle() } }
                    .simultaneousGesture(
                        // 播放页横滑切歌：左滑下一首、右滑上一首（点按仍是开关歌词）
                        DragGesture(minimumDistance: 24)
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                guard abs(dx) > 60, abs(dx) > 2 * abs(dy) else { return }
                                if dx < 0 { player.next() } else { player.previous() }
                            }
                    )

                    info(t)
                    progress
                    controls
                    bottomBar
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            } else {
                EmptyHint(icon: "music.note", title: "没有在播放")
            }
        }
        .sheet(isPresented: $showQueue) { QueueView() }
    }

    private var background: some View {
        // 背景图必须钉死在屏幕尺寸内：scaledToFill 不加 frame 会把整个布局撑得比屏幕宽，
        // 导致标题、时间、边缘按钮被挤出屏幕（封面/进度条看起来满幅、两侧按钮消失）。
        GeometryReader { geo in
            ZStack {
                Color(.systemBackground)
                if let img = player.artworkImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 60)
                        .opacity(0.45)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func cover(_ t: Track) -> some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Group {
                if let img = player.artworkImage {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    ArtworkView(url: t.artwork, size: side, corner: 16)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
            .scaleEffect(player.isPlaying ? 1 : 0.88)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func info(_ t: Track) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.title).font(.title2.weight(.bold)).lineLimit(1)
                Text(t.artist).font(.body).foregroundColor(.secondary).lineLimit(1)
                Text(store.plugin(id: t.pluginId)?.name ?? t.pluginId)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().stroke(Color.secondary.opacity(0.5)))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button { library.toggleFavorite(t) } label: {
                Image(systemName: library.isFavorite(t) ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundColor(library.isFavorite(t) ? .pink : .primary)
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { dragging ? dragValue : player.currentTime },
                    set: { dragValue = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        dragValue = player.currentTime
                        dragging = true
                    } else {
                        player.seek(to: dragValue)
                        dragging = false
                    }
                }
            )
            HStack {
                Text(formatTime(dragging ? dragValue : player.currentTime))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
        }
    }

    private var controls: some View {
        HStack {
            Button { player.mode = player.mode.next } label: {
                Image(systemName: player.mode.icon).font(.title3)
            }
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            Spacer()
            Button { player.seekBackward() } label: {
                Image(systemName: "gobackward.15").font(.title2)
            }
            Spacer()
            Button { player.togglePlay() } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView().scaleEffect(1.4)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                }
                .frame(width: 70, height: 70)
            }
            Spacer()
            Button { player.seekForward() } label: {
                Image(systemName: "goforward.15").font(.title2)
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet").font(.title3)
            }
        }
        .foregroundColor(.primary)
    }

    private var bottomBar: some View {
        HStack {
            Button { withAnimation { showLyrics.toggle() } } label: {
                Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
            }
            Spacer()
            Button { showTimerOptions = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: player.sleepDeadline != nil ? "moon.zzz.fill" : "moon.zzz")
                    if player.sleepDeadline != nil {
                        TimelineView(.periodic(from: .now, by: 20)) { _ in
                            Text(sleepRemainingText)
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .foregroundColor(player.sleepDeadline != nil ? .accentColor : .secondary)
            Spacer()
            Text(modeName).font(.caption).foregroundColor(.secondary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
            }
        }
        .font(.title3)
        .foregroundColor(.secondary)
        .confirmationDialog("定时关闭", isPresented: $showTimerOptions, titleVisibility: .visible) {
            ForEach([10, 15, 30, 45, 60, 90], id: \.self) { m in
                Button("\(m) 分钟后关闭") { player.setSleepTimer(minutes: m) }
            }
            Button("自定义…") { showCustomTimer = true }
            if player.sleepDeadline != nil {
                Button("取消定时关闭", role: .destructive) { player.cancelSleepTimer() }
            }
        }
        .alert("自定义定时关闭", isPresented: $showCustomTimer) {
            TextField("分钟", text: $customMinutes)
                .keyboardType(.numberPad)
            Button("设定") {
                if let m = Int(customMinutes.trimmingCharacters(in: .whitespaces)), m > 0 {
                    player.setSleepTimer(minutes: m)
                }
                customMinutes = ""
            }
            Button("取消", role: .cancel) { customMinutes = "" }
        } message: {
            Text("输入多少分钟后自动停止播放")
        }
    }

    private var sleepRemainingText: String {
        guard let d = player.sleepDeadline else { return "" }
        let remain = max(0, Int(d.timeIntervalSinceNow))
        if remain >= 3600 { return "\(remain / 3600)小时\((remain % 3600) / 60)分" }
        if remain >= 60 { return "\(remain / 60)分钟" }
        return "\(remain)秒"
    }

    private var modeName: String {
        switch player.mode {
        case .sequence: return "列表循环"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }
}

struct LyricsView: View {
    @EnvironmentObject var player: Player

    private var currentIndex: Int {
        let t = player.currentTime + 0.3
        var idx = -1
        for (i, line) in player.lyrics.enumerated() {
            if line.time <= t { idx = i } else { break }
        }
        return idx
    }

    var body: some View {
        if player.lyrics.isEmpty {
            VStack {
                Spacer()
                Text("暂无歌词").foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        Color.clear.frame(height: 120)
                        ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { i, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(i == currentIndex ? .title3.weight(.bold) : .body)
                                .foregroundColor(i == currentIndex ? .primary : .secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .id(i)
                                .onTapGesture { player.seek(to: line.time) }
                        }
                        Color.clear.frame(height: 160)
                    }
                }
                .onChange(of: currentIndex) { idx in
                    guard idx >= 0 else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
                .onAppear {
                    if currentIndex >= 0 { proxy.scrollTo(currentIndex, anchor: .center) }
                }
            }
            .mask(LinearGradient(colors: [.clear, .black, .black, .clear],
                                 startPoint: .top, endPoint: .bottom))
        }
    }
}

struct QueueView: View {
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, t in
                        HStack {
                            Text("\(i + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 28)
                            TrackRow(track: t)
                        }
                        .id(i)
                        .onTapGesture { player.play(player.queue, startAt: i) }
                    }
                    .onDelete { player.removeFromQueue(at: $0) }
                }
                .listStyle(.plain)
                .onAppear {
                    if player.index >= 0 { proxy.scrollTo(player.index, anchor: .center) }
                }
            }
            .navigationTitle("播放队列 (\(player.queue.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清空") {
                        player.stop()
                        dismiss()
                    }
                    .foregroundColor(.red)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
