import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import SwiftUI

@MainActor
final class Player: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int = -1
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var lyrics: [LyricLine] = []
    @Published private(set) var artworkImage: UIImage?
    @Published var errorMessage: String?
    /// 取址/播放失败过的歌曲 id（列表里会置灰并标「播放失败」）
    @Published private(set) var failedTrackIDs: Set<String> = []
    @Published var mode: PlayMode = PlayMode(rawValue: UserDefaults.standard.string(forKey: "playMode") ?? "") ?? .sequence {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "playMode") }
    }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    weak var store: PluginStore?
    weak var library: Library?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    /// 下一首的预解析地址（切歌时直接用，不用再等取址）
    private var prefetchedSource: [String: MediaSource] = [:]
    private var prefetchTask: Task<Void, Never>?

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            Task { @MainActor in self?.tick(t) }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as AnyObject?
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                if self.sleepAfterCurrentTrack {
                    self.sleepAfterCurrentTrack = false
                    self.pause()
                    self.seek(to: 0)
                    return
                }
                self.next(auto: true)
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began {
                    self.isPlaying = false
                    self.updateNowPlaying()
                } else if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                    self.resume()
                }
            }
        }

        setupRemoteCommands()
    }

    // MARK: - 播放控制

    func play(_ tracks: [Track], startAt i: Int) {
        guard tracks.indices.contains(i) else { return }
        queue = tracks
        index = i
        failedTrackIDs = []
        prefetchedSource = [:]
        loadCurrent()
    }

    func play(_ track: Track) {
        if let i = queue.firstIndex(of: track) {
            index = i
        } else {
            queue.insert(track, at: max(index + 1, 0))
            index = max(index + 1, 0)
        }
        loadCurrent()
    }

    func playNext(_ track: Track) {
        if queue.isEmpty { play(track); return }
        if let i = queue.firstIndex(of: track) {
            if i == index { return }
            queue.remove(at: i)
            if i < index { index -= 1 }
        }
        queue.insert(track, at: index + 1)
    }

    func removeFromQueue(at offsets: IndexSet) {
        let removingCurrent = offsets.contains(index)
        let before = offsets.filter { $0 < index }.count
        queue.remove(atOffsets: offsets)
        if queue.isEmpty {
            stop()
            return
        }
        index -= before
        if removingCurrent {
            index = min(index, queue.count - 1)
            loadCurrent()
        }
    }

    func togglePlay() {
        if isPlaying { pause() } else { resume() }
    }

    // MARK: - 定时关闭

    /// 定时关闭的截止时间（nil = 未设定）
    @Published private(set) var sleepDeadline: Date?
    /// 「播完这首后关闭」是否已设定
    @Published private(set) var sleepAfterCurrentTrack = false
    private var sleepTask: Task<Void, Never>?

    /// 设定定时关闭：minutes 分钟后自动暂停播放
    func setSleepTimer(minutes: Int) {
        guard minutes > 0 else { return }
        sleepTask?.cancel()
        sleepAfterCurrentTrack = false
        let deadline = Date().addingTimeInterval(Double(minutes) * 60)
        sleepDeadline = deadline
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.sleepDeadline == deadline else { return }
                self.pause()
                self.sleepDeadline = nil
                self.sleepTask = nil
            }
        }
    }

    /// 设定「播完这首后关闭」：当前歌曲放完就停，不切下一首
    func setSleepAfterCurrentTrack() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
        sleepAfterCurrentTrack = true
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
        sleepAfterCurrentTrack = false
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard current != nil else { return }
        if player.currentItem == nil {
            loadCurrent()
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func stop() {
        loadTask?.cancel()
        prefetchTask?.cancel()
        prefetchedSource = [:]
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        index = -1
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        lyrics = []
        artworkImage = nil
        updateNowPlaying()
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if auto && mode == .repeatOne {
            seek(to: 0)
            player.play()
            return
        }
        if mode == .shuffle && queue.count > 1 {
            var i = index
            while i == index { i = Int.random(in: 0..<queue.count) }
            index = i
        } else {
            index = (index + 1) % queue.count
        }
        loadCurrent()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 5 {
            seek(to: 0)
            return
        }
        index = (index - 1 + queue.count) % queue.count
        loadCurrent()
    }

    func seek(to t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        currentTime = t
        updateNowPlaying()
    }

    func seekForward(_ seconds: Double = 15) {
        let target = duration > 0 ? min(currentTime + seconds, duration) : currentTime + seconds
        seek(to: target)
    }

    func seekBackward(_ seconds: Double = 15) {
        seek(to: max(currentTime - seconds, 0))
    }

    // MARK: - 加载

    private func loadCurrent() {
        loadTask?.cancel()
        guard let track = current else { return }
        isLoading = true
        isPlaying = false
        currentTime = 0
        duration = track.duration ?? 0
        lyrics = []
        artworkImage = nil
        errorMessage = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        updateNowPlaying()
        library?.addRecent(track)

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let plugin = self.store?.plugin(id: track.pluginId) else {
                    throw PluginError.call("找不到音源「\(track.pluginId)」，可能已被删除")
                }
                self.loadExtras(track, plugin: plugin)
                let src: MediaSource
                if let cached = self.prefetchedSource.removeValue(forKey: track.id) {
                    src = cached
                } else {
                    src = try await plugin.mediaSource(for: track)
                }
                if Task.isCancelled { return }
                var options: [String: Any] = [:]
                if !src.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = src.headers }
                let item = AVPlayerItem(asset: AVURLAsset(url: src.url, options: options))
                self.observe(item)
                self.player.replaceCurrentItem(with: item)
                try? AVAudioSession.sharedInstance().setActive(true)
                self.player.play()
                self.isPlaying = true
                self.updateNowPlaying()
            } catch {
                if Task.isCancelled { return }
                self.handleFailure(track, error)
            }
        }
    }

    private func handleFailure(_ track: Track, _ error: Error) {
        isLoading = false
        isPlaying = false
        failedTrackIDs.insert(track.id)
        errorMessage = "《\(track.title)》播放失败：\(error.localizedDescription)"
        updateNowPlaying()
        // 队列里还有没失败过的歌就自动跳过去，全都失败了才停下来
        guard queue.count > 1, failedTrackIDs.count < queue.count else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.current == track else { return }
            for step in 1...self.queue.count {
                let i = (self.index + step) % self.queue.count
                if !self.failedTrackIDs.contains(self.queue[i].id) {
                    self.index = i
                    self.loadCurrent()
                    return
                }
            }
        }
    }

    /// 当前歌曲开始播后，提前把下一首的地址解析好，切歌时不用等
    private func prefetchNext() {
        guard mode != .shuffle, queue.count > 1 else { return }
        let nextIdx = (index + 1) % queue.count
        guard nextIdx != index else { return }
        let next = queue[nextIdx]
        guard !failedTrackIDs.contains(next.id), prefetchedSource[next.id] == nil,
              let plugin = store?.plugin(id: next.pluginId) else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let src = try? await plugin.mediaSource(for: next) else { return }
            guard let self, !Task.isCancelled else { return }
            self.prefetchedSource[next.id] = src
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let err = item.error
            let dur = item.duration.seconds
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                switch status {
                case .readyToPlay:
                    self.isLoading = false
                    if let t = self.current { self.failedTrackIDs.remove(t.id) }
                    if dur.isFinite && dur > 0 { self.duration = dur }
                    self.updateNowPlaying()
                    self.prefetchNext()
                case .failed:
                    if let t = self.current {
                        self.handleFailure(t, err ?? (PluginError.call("无法播放该地址") as Error))
                    }
                default: break
                }
            }
        }
    }

    private func loadExtras(_ track: Track, plugin: Plugin) {
        Task { [weak self] in
            guard let lrc = try? await plugin.lyric(for: track) else { return }
            guard let self, self.current == track else { return }
            self.lyrics = LyricLine.parse(lrc)
        }
        if let s = track.artwork, let url = URL(string: s) {
            Task { [weak self] in
                guard let result = try? await URLSession.shared.data(from: url),
                      let img = UIImage(data: result.0) else { return }
                guard let self, self.current == track else { return }
                self.artworkImage = img
                self.updateNowPlaying()
            }
        }
    }

    private func tick(_ t: CMTime) {
        let s = t.seconds
        if s.isFinite { currentTime = s }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 {
            duration = d
        }
        if player.timeControlStatus == .playing {
            if isLoading { isLoading = false }
        }
    }

    // MARK: - 锁屏 / 控制中心

    private func updateNowPlaying() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let img = artworkImage {
            info[MPMediaItemPropertyArtwork] = Player.makeArtwork(img)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    nonisolated private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let pos = e.positionTime
            Task { @MainActor in self?.seek(to: pos) }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seekForward() }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seekBackward() }
            return .success
        }
    }
}
