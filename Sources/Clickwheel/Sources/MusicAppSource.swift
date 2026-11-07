import AppKit
import Foundation
import MusicBridge
import ScriptingBridge
import os

/// Playback backend that drives Music.app over ScriptingBridge.
///
/// This is the backend that always works: it needs no developer-portal setup,
/// and because Music.app owns the audio it plays full-length Apple Music
/// subscription tracks with the user's own account. The trade-off is that
/// Music.app runs hidden in the background as the audio engine.
///
/// ## Threading
/// Every Apple event is synchronous and can take tens of milliseconds, so all
/// ScriptingBridge access is confined to `queue`. No `SB*` object ever escapes
/// that queue — the public API deals only in `Sendable` value types, which is
/// what makes the `@unchecked Sendable` conformance honest.
final class MusicAppSource: MusicSource, @unchecked Sendable {
    let backendName = "Music.app bridge"

    private let queue = DispatchQueue(label: "com.clickwheel.musicapp", qos: .userInitiated)
    private let log = Logger(subsystem: "com.clickwheel", category: "MusicAppSource")

    /// Touched only on `queue`.
    private var app: MusicApplication?

    /// Cached favourites playlist name once resolved, so the Playlists menu and
    /// the boot destination agree even if the user renames things mid-session.
    private var favouritesID: String?

    /// The user's own shuffle/repeat settings, borrowed for the session and
    /// handed back in `relinquish()`.
    private var hostState: (shuffle: Bool, repeatMode: MusicERpt)?

    // MARK: - Lifecycle

    func prepare() async throws {
        // Launching hidden keeps the illusion intact: the user should never see
        // Music.app's window appear behind their iPod.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty {
            try await launchHidden()
        }

        try await onQueue {
            guard let app = MBMusicApplication(Self.bundleID) else {
                throw MusicSourceError.backendUnavailable(
                    String(
                        localized: "error.music_missing",
                        defaultValue: "Music.app could not be reached."
                    )
                )
            }
            self.app = app

            // First real event doubles as the Automation permission probe. A
            // denial throws here rather than failing silently later on.
            guard app.isRunning else {
                throw MusicSourceError.backendUnavailable(
                    String(
                        localized: "error.music_not_running",
                        defaultValue: "Music.app isn't running."
                    )
                )
            }
            _ = app.playlists()?.count
        }
    }

    private func launchHidden() async throws {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID)
        else {
            throw MusicSourceError.backendUnavailable(
                String(localized: "error.music_missing", defaultValue: "Music.app could not be reached.")
            )
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)

        // Music.app accepts events before it has finished opening its library;
        // asking too early returns an empty playlist set.
        try? await Task.sleep(for: .milliseconds(600))
    }

    // MARK: - Library

    func playlists() async throws -> [SongList] {
        try await onQueue {
            guard let app = self.app, let all = app.playlists() else {
                throw MusicSourceError.notAuthorised
            }

            // One Apple event per property instead of one per playlist. On a
            // library this size that is the difference between 30ms and 3s.
            let names = all.strings(for: "name")
            let kinds = all.fourCharCodes(for: "specialKind")
            let ids = all.strings(for: "persistentID")
            let durations = all.integers(for: "duration")

            var lists: [SongList] = []
            for index in 0..<min(names.count, min(kinds.count, ids.count)) {
                // `specialKind == none` keeps user playlists and Favourite
                // Songs while dropping the Library and Music roots, matching
                // what Music.app itself shows in the sidebar.
                guard kinds[index] == Self.specialKindNone else { continue }
                // A zero total duration means an empty list; an iPod would show
                // it, but it is dead weight in a menu.
                guard durations.indices.contains(index), durations[index] > 0 else { continue }

                lists.append(
                    SongList(
                        id: ids[index],
                        name: names[index],
                        count: 0,
                        isFavourites: Self.isFavouritesName(names[index])
                    )
                )
            }

            // Favourites first, then alphabetical — the iPod sorted playlists
            // alphabetically, and pinning favourites matches the app's purpose.
            if let favourite = lists.first(where: \.isFavourites) {
                self.favouritesID = favourite.id
            }
            lists.sort { lhs, rhs in
                if lhs.isFavourites != rhs.isFavourites { return lhs.isFavourites }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lists
        }
    }

    func songs(in list: SongList) async throws -> [Song] {
        try await onQueue {
            guard let playlist = try self.resolvePlaylist(list),
                  let tracks = playlist.tracks()
            else { return [] }

            let names = tracks.strings(for: "name")
            let artists = tracks.strings(for: "artist")
            let albums = tracks.strings(for: "album")
            // `databaseID`, not `persistentID`: a track inside a playlist has a
            // different persistent ID from the same track in the library, so
            // persistent IDs would never match what `currentTrack` reports.
            // Database IDs are shared by every copy of the same underlying
            // track, which is exactly the identity the player needs.
            let ids = tracks.integers(for: "databaseID")
            let durations = tracks.doubles(for: "duration")

            return (0..<names.count).map { index in
                Song(
                    id: ids.indices.contains(index) ? String(ids[index]) : "\(list.id).\(index)",
                    title: names[index],
                    artist: artists.indices.contains(index) ? artists[index] : "",
                    album: albums.indices.contains(index) ? albums[index] : "",
                    duration: durations.indices.contains(index) ? durations[index] : 0,
                    indexInPlaylist: index + 1
                )
            }
        }
    }

    // MARK: - Transport

    func play(song: Song, in list: SongList) async throws {
        try await onQueue {
            guard let app = self.app, let playlist = try self.resolvePlaylist(list),
                  let tracks = playlist.tracks()
            else { return }

            self.captureHostState(app)
            // Music.app is now a dumb one-song player: shuffle off so it can't
            // reorder anything, repeat-one so that if `Player` is a beat late
            // issuing the next song the worst case is a moment of the same
            // track replaying rather than an unrelated library track barging
            // in. `Player` is what actually advances the queue.
            app.shuffleEnabled = false
            app.songRepeat = MusicERptOne

            // `indexInPlaylist` is 1-based, matching the iPod's display.
            guard let track = MBTrackAt(tracks, song.indexInPlaylist - 1) else { return }
            track.playOnce(false)
        }
    }

    func resume() async {
        try? await onQueue {
            guard let app = self.app else { return }
            if app.playerState != MusicEPlSPlaying { app.playpause() }
        }
    }

    func pause() async {
        try? await onQueue {
            guard let app = self.app else { return }
            if app.playerState == MusicEPlSPlaying { app.pause() }
        }
    }

    func seek(to position: TimeInterval) async {
        try? await onQueue { self.app?.playerPosition = position }
    }

    func volume() async -> Double {
        (try? await onQueue {
            Double(self.app?.soundVolume ?? 50) / 100
        }) ?? 0.5
    }

    func setVolume(_ level: Double) async {
        try? await onQueue {
            self.app?.soundVolume = Int((min(1, max(0, level)) * 100).rounded())
        }
    }

    /// Puts back the shuffle and repeat settings we borrowed.
    ///
    /// Leaving someone's library on repeat-one after quitting would be a
    /// genuinely annoying thing to do to them.
    func relinquish() async {
        try? await onQueue {
            guard let app = self.app, let saved = self.hostState else { return }
            app.shuffleEnabled = saved.shuffle
            app.songRepeat = saved.repeatMode
            self.hostState = nil
        }
    }

    private func captureHostState(_ app: MusicApplication) {
        guard hostState == nil else { return }
        hostState = (shuffle: app.shuffleEnabled, repeatMode: app.songRepeat)
    }

    // MARK: - State

    func snapshot() async -> NowPlaying {
        (try? await onQueue { () -> NowPlaying in
            guard let app = self.app, app.isRunning else { return .idle }

            var state = NowPlaying()
            state.transport =
                switch app.playerState {
                case MusicEPlSPlaying, MusicEPlSFastForwarding, MusicEPlSRewinding: .playing
                case MusicEPlSPaused: .paused
                default: .stopped
                }
            state.position = app.playerPosition

            guard let track = app.currentTrack, let name = track.name, !name.isEmpty else {
                return state
            }
            state.song = Song(
                id: String(track.databaseID),
                title: name,
                artist: track.artist ?? "",
                album: track.album ?? "",
                duration: track.duration
            )
            // Queue position is deliberately not read from Music.app: it
            // reports an index into whatever context it thinks it is playing,
            // which is the whole library. `Player` fills these in from the
            // queue it owns. Artwork is likewise left out — see
            // `currentArtwork()`.
            return state
        }) ?? .idle
    }

    func currentArtwork() async -> Data? {
        try? await onQueue {
            guard let track = self.app?.currentTrack else { return nil }
            return self.artworkData(for: track)
        }
    }

    /// Pulls the first artwork off a track and normalises it to PNG bytes.
    ///
    /// `rawData` avoids an `NSImage` round-trip when the artwork is already
    /// compressed, which is the common case for streamed Apple Music tracks.
    private func artworkData(for track: MusicTrack) -> Data? {
        guard let artworks = track.artworks(), let artwork = MBArtworkAt(artworks, 0) else {
            return nil
        }

        if let raw = artwork.rawData as? Data, !raw.isEmpty { return raw }
        guard let image = artwork.data,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
    }

    // MARK: - Helpers

    /// Looks a playlist back up by persistent ID.
    ///
    /// Holding onto the `SBObject` between calls is tempting but unsafe: the
    /// proxy goes stale when Music.app re-indexes, and stale proxies throw on
    /// use rather than returning nil.
    private func resolvePlaylist(_ list: SongList) throws -> MusicPlaylist? {
        guard let app, let all = app.playlists() else { throw MusicSourceError.notAuthorised }
        let ids = all.strings(for: "persistentID")
        guard let index = ids.firstIndex(of: list.id) else { return nil }
        return MBPlaylistAt(all, index)
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    // MARK: - Constants

    private static let bundleID = "com.apple.Music"
    /// `MusicESpKNone` — 'kNon'.
    private static let specialKindNone: FourCharCode = 0x6B4E_6F6E

    /// Apple localises the starred playlist's name, and ScriptingBridge exposes
    /// no flag for it, so match the known translations.
    private static let favouriteNames: Set<String> = [
        "favourite songs", "favorite songs",       // en-GB / en-US
        "canciones favoritas",                     // es
        "morceaux préférés", "titres préférés",    // fr
        "lieblingssongs",                          // de
        "brani preferiti",                         // it
        "músicas favoritas",                       // pt
        "favoriete nummers",                       // nl
        "favoritlåtar",                            // sv
        "suosikkikappaleet",                       // fi
        "ulubione utwory",                         // pl
        "любимые песни",                           // ru
        "お気に入りの曲",                             // ja
        "즐겨찾는 노래",                              // ko
        "喜爱的歌曲", "喜愛的歌曲",                    // zh-Hans / zh-Hant
    ]

    static func isFavouritesName(_ name: String) -> Bool {
        favouriteNames.contains(name.lowercased())
    }
}

// MARK: - Batched property reads

private extension SBElementArray {
    /// Fetches one property across every element in a single Apple event.
    ///
    /// `array(byApplying:)` is the whole reason browsing a 182-track playlist
    /// feels instant instead of taking seconds; the per-element alternative
    /// issues one round-trip per property per track.
    func values(for property: String) -> [Any] {
        // The ObjC return is annotated non-null but can be nil in practice when
        // Music.app is quitting; the optional coercion keeps that from trapping.
        (array(byApplying: NSSelectorFromString(property)) as [Any]?) ?? []
    }

    func strings(for property: String) -> [String] {
        values(for: property).map { $0 as? String ?? "" }
    }

    func integers(for property: String) -> [Int] {
        values(for: property).map { ($0 as? NSNumber)?.intValue ?? 0 }
    }

    /// Reads an enum-typed property as its four-char code.
    ///
    /// Batched reads of enum properties come back as `NSAppleEventDescriptor`
    /// rather than `NSNumber` — `specialKind` arrives as `'kSpL'`, not `4` —
    /// so they need unwrapping to an `OSType` before they can be compared to
    /// the constants in `Music.h`.
    func fourCharCodes(for property: String) -> [FourCharCode] {
        values(for: property).map { value in
            if let descriptor = value as? NSAppleEventDescriptor {
                let enumerated = descriptor.enumCodeValue
                return enumerated != 0 ? enumerated : descriptor.typeCodeValue
            }
            if let number = value as? NSNumber {
                return FourCharCode(bitPattern: Int32(truncatingIfNeeded: number.intValue))
            }
            return 0
        }
    }

    func doubles(for property: String) -> [Double] {
        values(for: property).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
    }
}
