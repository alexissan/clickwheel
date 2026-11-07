import Foundation

/// A single playable song, flattened out of whatever backend produced it.
///
/// Deliberately value-typed and backend-agnostic: the UI never touches
/// ScriptingBridge or MusicKit objects directly, which keeps the screen code
/// testable and lets the two backends stay interchangeable.
struct Song: Identifiable, Hashable, Sendable {
    /// Stable identity within a backend. For Music.app this is the persistent
    /// ID, which survives library re-indexing; for MusicKit it is the item ID.
    let id: String
    let title: String
    let artist: String
    let album: String
    /// Track length in seconds. Zero when the backend has not reported one yet.
    let duration: TimeInterval

    /// Position of this song inside its parent playlist, 1-based, the way the
    /// iPod displays it ("3 of 182").
    var indexInPlaylist: Int = 0
}

/// A playlist as shown in the Playlists menu.
struct SongList: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let count: Int

    /// True for the account's starred/loved playlist. Apple Music localises the
    /// name, so this flag is resolved once at load time and carried along
    /// rather than re-derived from the string later.
    var isFavourites: Bool = false
}

/// Transport state, mirrored from whichever backend owns the audio.
enum Transport: Sendable {
    case stopped
    case playing
    case paused
}

/// Everything the Now Playing screen needs, refreshed on a timer. Artwork is
/// deliberately not part of it — it is megabytes per track, and travels through
/// `MusicSource.currentArtwork()` once per song change instead.
struct NowPlaying: Sendable {
    var song: Song?
    var transport: Transport = .stopped
    /// Playhead in seconds.
    var position: TimeInterval = 0
    /// Index within the queue the iPod is showing, 1-based.
    var queueIndex: Int = 0
    var queueCount: Int = 0

    static let idle = NowPlaying()
}

/// Errors surfaced to the screen. The iPod shows these as a full-screen
/// message in its own voice rather than as a macOS alert, which would shatter
/// the illusion instantly.
enum MusicSourceError: LocalizedError, Sendable {
    case notAuthorised
    case backendUnavailable(String)
    case noFavourites

    var errorDescription: String? {
        switch self {
        case .notAuthorised:
            String(localized: "error.not_authorised", defaultValue: "No Access")
        case .backendUnavailable:
            String(localized: "error.unavailable", defaultValue: "No Music")
        case .noFavourites:
            String(localized: "error.no_favourites", defaultValue: "No Favourites")
        }
    }

    /// Second line, shown smaller under the title on the iPod screen.
    var recoveryHint: String {
        switch self {
        case .notAuthorised:
            String(
                localized: "error.not_authorised.hint",
                defaultValue: "Allow access in System Settings › Privacy & Security › Automation."
            )
        case .backendUnavailable(let detail):
            detail
        case .noFavourites:
            String(
                localized: "error.no_favourites.hint",
                defaultValue: "Star some songs in Apple Music and they'll show up here."
            )
        }
    }
}

/// The contract every playback backend implements.
///
/// One ships today: `MusicAppSource`, ScriptingBridge onto Music.app, which
/// works with no developer-portal setup. A MusicKit implementation (native
/// in-process streaming) can be slotted in behind this protocol without the
/// rest of the app noticing.
///
/// ## Why the backend plays one song at a time
/// Modern Music.app drops the playlist context when asked to play a specific
/// track inside a playlist — playback continues into the whole library instead
/// of the playlist, which breaks Next, Previous, and the iPod's "3 of 182"
/// counter. Rather than work around that in one backend, `Player` owns the
/// queue for every backend and asks the source for a single song at a time.
/// That also puts shuffle and repeat semantics under our control, where the
/// iPod's behaviour is defined, instead of inheriting whatever the host app
/// happens to do.
protocol MusicSource: AnyObject, Sendable {
    /// Human-readable backend name, shown on the About screen.
    var backendName: String { get }

    /// Prepare the backend. Throws if it cannot be used at all, which is the
    /// signal for the app to try the next one down the ladder.
    func prepare() async throws

    /// All playlists worth showing, favourites first.
    func playlists() async throws -> [SongList]

    /// Songs inside a playlist, in playlist order.
    func songs(in list: SongList) async throws -> [Song]

    /// Play exactly this song, and only this song.
    ///
    /// Implementations must not advance past it on their own — `Player`
    /// decides what comes next. `list` is passed because some backends can
    /// only address a song via its containing playlist.
    func play(song: Song, in list: SongList) async throws

    func resume() async
    func pause() async
    /// Seek within the current song.
    func seek(to position: TimeInterval) async

    /// Output volume, 0...1.
    func volume() async -> Double
    func setVolume(_ level: Double) async

    /// Current transport snapshot.
    ///
    /// Polled several times a second, so it must stay cheap — in particular it
    /// must not carry artwork, which is megabytes per track.
    func snapshot() async -> NowPlaying

    /// Cover art for the song the backend is currently playing.
    ///
    /// Fetched once per song change rather than per poll.
    func currentArtwork() async -> Data?

    /// Restore any host-app state the backend changed. Called on quit.
    func relinquish() async
}
