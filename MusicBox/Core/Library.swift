import Foundation
import SwiftUI

/// 收藏 & 最近播放，存成 JSON
@MainActor
final class Library: ObservableObject {
    @Published private(set) var favorites: [Track] = [] { didSet { save() } }
    @Published private(set) var recent: [Track] = [] { didSet { save() } }

    private struct Stored: Codable {
        var favorites: [Track]
        var recent: [Track]
    }

    private let file: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library.json")
    private var loading = false

    init() {
        loading = true
        if let data = try? Data(contentsOf: file),
           let s = try? JSONDecoder().decode(Stored.self, from: data) {
            favorites = s.favorites
            recent = s.recent
        }
        loading = false
    }

    func isFavorite(_ t: Track) -> Bool { favorites.contains(t) }

    func toggleFavorite(_ t: Track) {
        if let i = favorites.firstIndex(of: t) {
            favorites.remove(at: i)
        } else {
            favorites.insert(t, at: 0)
        }
    }

    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
    }

    func moveFavorites(from: IndexSet, to: Int) {
        favorites.move(fromOffsets: from, toOffset: to)
    }

    func addRecent(_ t: Track) {
        var r = recent.filter { $0 != t }
        r.insert(t, at: 0)
        recent = Array(r.prefix(100))
    }

    func clearRecent() { recent = [] }

    private func save() {
        guard !loading else { return }
        let s = Stored(favorites: favorites, recent: recent)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
