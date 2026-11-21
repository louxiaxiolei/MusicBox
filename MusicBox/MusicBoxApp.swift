import SwiftUI

@main
struct MusicBoxApp: App {
    @StateObject private var store = PluginStore()
    @StateObject private var library = Library()
    @StateObject private var player = Player()
    @StateObject private var ui = UIState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(ui)
                .onAppear {
                    player.store = store
                    player.library = library
                }
        }
    }
}

@MainActor
final class UIState: ObservableObject {
    @Published var showNowPlaying = false
    @Published var tab = 0
}

struct ContentView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var ui: UIState

    var body: some View {
        TabView(selection: $ui.tab) {
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(0)
            LibraryView()
                .tabItem { Label("我的", systemImage: "heart") }
                .tag(1)
            SourcesView()
                .tabItem { Label("音源", systemImage: "puzzlepiece.extension") }
                .tag(2)
        }
        .sheet(isPresented: $ui.showNowPlaying) {
            NowPlayingView()
        }
        .overlay(alignment: .top) {
            if let msg = player.errorMessage {
                Text(msg)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.red.opacity(0.9)))
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { player.errorMessage = nil }
                    .task(id: msg) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if player.errorMessage == msg {
                            withAnimation { player.errorMessage = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut, value: player.errorMessage)
    }
}
