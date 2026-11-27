import SwiftUI

struct ArtworkView: View {
    let url: String?
    var size: CGFloat = 44
    var corner: CGFloat = 6

    var body: some View {
        Group {
            if let s = url, let u = URL(string: s) {
                AsyncImage(url: u) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.pink.opacity(0.6), .purple.opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

struct TrackRow: View {
    let track: Track
    var showSource = false
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: PluginStore

    var isCurrent: Bool { player.current == track }
    var isFailed: Bool { player.failedTrackIDs.contains(track.id) }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.artwork)
                .opacity(isFailed ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body)
                    .foregroundColor(isCurrent ? .accentColor : (isFailed ? .secondary : .primary))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if isFailed {
                    Text("播放失败，已自动跳过")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
            Spacer(minLength: 4)
            if isCurrent && player.isPlaying {
                Image(systemName: "waveform")
                    .foregroundColor(.accentColor)
            }
            if let d = track.duration, d > 0 {
                Text(formatTime(d))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { player.playNext(track) } label: {
                Label("下一首播放", systemImage: "text.insert")
            }
            Button { library.toggleFavorite(track) } label: {
                if library.isFavorite(track) {
                    Label("取消收藏", systemImage: "heart.slash")
                } else {
                    Label("收藏", systemImage: "heart")
                }
            }
            Button { UIPasteboard.general.string = "\(track.title) - \(track.artist)" } label: {
                Label("复制歌名", systemImage: "doc.on.doc")
            }
        }
    }

    private var subtitle: String {
        var parts = [track.artist]
        if !track.album.isEmpty { parts.append(track.album) }
        if showSource { parts.append(store.plugin(id: track.pluginId)?.name ?? track.pluginId) }
        return parts.joined(separator: " · ")
    }
}

struct EmptyHint: View {
    let icon: String
    let title: String
    var message: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 迷你播放条

struct MiniPlayer: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var ui: UIState

    var body: some View {
        if let t = player.current {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: player.duration > 0
                               ? geo.size.width * min(1, player.currentTime / player.duration) : 0)
                }
                .frame(height: 2)

                HStack(spacing: 12) {
                    ArtworkView(url: t.artwork, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(t.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if player.isLoading {
                        ProgressView().frame(width: 36, height: 36)
                    } else {
                        Button { player.togglePlay() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .frame(width: 36, height: 36)
                        }
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                    }
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .background(.regularMaterial)
            .contentShape(Rectangle())
            .onTapGesture { ui.showNowPlaying = true }
        }
    }
}

struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject var player: Player

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                MiniPlayer()
            }
        }
    }
}

extension View {
    func miniPlayerInset() -> some View { modifier(MiniPlayerInset()) }
}
