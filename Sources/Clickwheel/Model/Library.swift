import Observation

/// Playlists and their contents, loaded once and cached.
///
/// The iPod's menus have to appear instantly when you press Select, so track
/// lists are fetched on first visit and kept. A playlist of a few hundred songs
/// costs well under a hundred kilobytes, and the batched reads in
/// `MusicAppSource` make the first fetch fast enough to be invisible.
@MainActor
@Observable
final class Library {
    private(set) var playlists: [SongList] = []
    private(set) var loadFailure: MusicSourceError?
    private(set) var isLoading = true

    private var songsByList: [String: [Song]] = [:]
    private let source: MusicSource

    init(source: MusicSource) {
        self.source = source
    }

    var favourites: SongList? {
        playlists.first(where: \.isFavourites)
    }

    /// Which backend is driving playback, shown on the About screen.
    var backendName: String { source.backendName }

    /// Brings the backend up, then loads the playlists.
    ///
    /// These have to happen in this order and in one place: when preparation
    /// and loading were kicked off separately they raced, and a load that won
    /// the race reported the library as unauthorised.
    func start() async {
        do {
            try await source.prepare()
        } catch let error as MusicSourceError {
            loadFailure = error
            isLoading = false
            return
        } catch {
            loadFailure = .backendUnavailable(error.localizedDescription)
            isLoading = false
            return
        }
        await load()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await source.playlists()
            guard !loaded.isEmpty else {
                loadFailure = .noFavourites
                return
            }
            playlists = loaded
            loadFailure = nil
        } catch let error as MusicSourceError {
            loadFailure = error
        } catch {
            loadFailure = .backendUnavailable(error.localizedDescription)
        }
    }

    /// Songs for a playlist, fetched on first request.
    func songs(in list: SongList) async -> [Song] {
        if let cached = songsByList[list.id] { return cached }
        let loaded = (try? await source.songs(in: list)) ?? []
        songsByList[list.id] = loaded
        return loaded
    }

    /// Songs already in the cache, for synchronous use while drawing a menu.
    func cachedSongs(in list: SongList) -> [Song]? {
        songsByList[list.id]
    }

    /// Total song count across every playlist, shown on the About screen.
    var totalSongs: Int {
        songsByList.values.reduce(0) { $0 + $1.count }
    }
}
