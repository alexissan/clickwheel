import AppKit
import Observation

/// Owns the playback queue and drives whichever `MusicSource` is active.
///
/// The backend plays one song at a time (see `MusicSource`), so everything the
/// iPod considers "the queue" lives here: order, shuffle, repeat, the position
/// counter, and advancing when a song ends. That keeps queue behaviour
/// identical no matter which backend is underneath.
@MainActor
@Observable
final class Player {
    // MARK: - iPod playback modes

    enum RepeatMode: CaseIterable {
        case off, all, one

        var label: String {
            switch self {
            case .off: String(localized: "repeat.off", defaultValue: "Off", bundle: .module)
            case .all: String(localized: "repeat.all", defaultValue: "All", bundle: .module)
            case .one: String(localized: "repeat.one", defaultValue: "One", bundle: .module)
            }
        }
    }

    enum ShuffleMode: CaseIterable {
        case off, songs

        var label: String {
            switch self {
            case .off: String(localized: "shuffle.off", defaultValue: "Off", bundle: .module)
            case .songs: String(localized: "shuffle.songs", defaultValue: "Songs", bundle: .module)
            }
        }
    }

    // MARK: - Observable state

    private(set) var nowPlaying: NowPlaying = .idle
    private(set) var currentList: SongList?
    /// Artwork for the current song, decoded once and reused across frames.
    private(set) var artwork: NSImage?

    var repeatMode: RepeatMode = .off
    var shuffleMode: ShuffleMode = .off {
        didSet { if shuffleMode != oldValue { reorderPreservingCurrent() } }
    }

    /// True while the user is scrubbing with the wheel, which suspends polling
    /// so the playhead doesn't fight the user's input.
    var isScrubbing = false {
        didSet { if oldValue, !isScrubbing { Task { await commitScrub() } } }
    }
    var scrubTarget: TimeInterval = 0

    // MARK: - Queue

    private let source: MusicSource
    /// The queue in play order. With shuffle on, this is a permutation of the
    /// playlist rather than a separate list, so turning shuffle off restores
    /// the original order without reloading anything.
    private var queue: [Song] = []
    private var cursor: Int = 0

    private var pollTask: Task<Void, Never>?
    /// Guards against firing two advances for the same track ending.
    private var isAdvancing = false
    private var lastPosition: TimeInterval = 0
    /// End-of-track detection stays disarmed until the backend confirms the
    /// new song's playhead is near zero.
    ///
    /// Starting a song takes the backend a few hundred milliseconds, and until
    /// it catches up it keeps reporting the *previous* track's position — which
    /// is, by definition, right at the end. Acting on that would skip a song
    /// every single time the queue rolled over.
    private var endDetectionArmed = false
    /// When the current song was asked for, used to tell a slow backend
    /// handoff apart from the user changing tracks somewhere else.
    private var songStartedAt = Date.distantPast
    /// Bumped every time the current song changes.
    ///
    /// `poll()` reads state, suspends on the backend, then acts. If the user
    /// presses Next during that suspension the result describes a song that is
    /// no longer current, and acting on it skips tracks. Polls carry the
    /// generation they started in and discard themselves if it moved on.
    private var generation = 0
    private static let handoffGrace: TimeInterval = 3
    /// Flip on when queue advancement misbehaves; noisy but decisive.
    static let traceAdvances = ProcessInfo.processInfo.environment["CLICKWHEEL_TRACE"] != nil

    init(source: MusicSource) {
        self.source = source
    }

    // MARK: - Starting playback

    func play(list: SongList, songs: [Song], startingAt index: Int) async {
        currentList = list
        queue = songs
        cursor = max(0, min(index, songs.count - 1))

        if shuffleMode == .songs {
            // Shuffling from a chosen song keeps that song first, which is what
            // the iPod does when you pick a track with shuffle already on.
            let chosen = queue[cursor]
            queue.shuffle()
            if let position = queue.firstIndex(of: chosen) {
                queue.swapAt(0, position)
            }
            cursor = 0
        }
        await startCurrent()
    }

    /// Shuffle Songs from the main menu: whole playlist, random order.
    func shuffleAll(list: SongList, songs: [Song]) async {
        shuffleMode = .songs
        currentList = list
        queue = songs.shuffled()
        cursor = 0
        await startCurrent()
    }

    /// Fills in Now Playing state without starting audio. Only for `Snapshot`.
    func stageForPreview(list: SongList, songs: [Song], index: Int) {
        currentList = list
        queue = songs
        cursor = max(0, min(index, songs.count - 1))
        nowPlaying.song = queue[cursor]
        nowPlaying.queueIndex = cursor + 1
        nowPlaying.queueCount = queue.count
        nowPlaying.transport = .playing
        nowPlaying.position = (nowPlaying.song?.duration ?? 200) * 0.38
    }

    /// Loads artwork for the staged song so previews show a real cover rather
    /// than the empty-sleeve placeholder.
    func loadPreviewArtwork() async {
        guard let list = currentList, let song = nowPlaying.song else { return }
        try? await source.play(song: song, in: list)
        try? await Task.sleep(for: .milliseconds(1200))
        await source.pause()
        if let data = await source.currentArtwork() {
            artwork = NSImage(data: data)
        }
    }

    private func startCurrent() async {
        guard let list = currentList, queue.indices.contains(cursor) else { return }
        let song = queue[cursor]

        // Paint the new song immediately rather than waiting for the next poll:
        // a 250ms lag between pressing Select and the screen changing is very
        // visible on a device this responsive.
        nowPlaying.song = song
        nowPlaying.position = 0
        nowPlaying.transport = .playing
        nowPlaying.queueIndex = cursor + 1
        nowPlaying.queueCount = queue.count
        artwork = nil
        lastPosition = 0
        endDetectionArmed = false
        songStartedAt = Date()
        generation += 1

        try? await source.play(song: song, in: list)
        startPolling()
    }

    // MARK: - Transport

    func togglePlayPause() async {
        switch nowPlaying.transport {
        case .playing:
            await source.pause()
            nowPlaying.transport = .paused
        case .paused:
            await source.resume()
            nowPlaying.transport = .playing
        case .stopped:
            await startCurrent()
        }
    }

    func next() async {
        guard !queue.isEmpty else { return }
        if repeatMode == .one {
            await startCurrent()
            return
        }
        if cursor + 1 < queue.count {
            cursor += 1
        } else if repeatMode == .all {
            cursor = 0
        } else {
            await stop()
            return
        }
        await startCurrent()
    }

    /// Previous behaves like the real iPod: restart the song unless you press
    /// it within the first few seconds, in which case step back a track.
    func previous() async {
        guard !queue.isEmpty else { return }
        if nowPlaying.position > 3 {
            await seek(to: 0)
            return
        }
        if cursor > 0 {
            cursor -= 1
        } else if repeatMode == .all {
            cursor = queue.count - 1
        } else {
            await seek(to: 0)
            return
        }
        await startCurrent()
    }

    /// Moves the displayed playhead without touching the backend, so the
    /// progress bar tracks the wheel while scrubbing and only commits on release.
    func previewScrub(at position: TimeInterval) {
        nowPlaying.position = position
    }

    func seek(to position: TimeInterval) async {
        nowPlaying.position = max(0, position)
        lastPosition = nowPlaying.position
        await source.seek(to: nowPlaying.position)
    }

    private func commitScrub() async {
        await seek(to: scrubTarget)
    }

    func stop() async {
        await source.pause()
        nowPlaying.transport = .stopped
        pollTask?.cancel()
        pollTask = nil
    }

    func relinquish() async {
        pollTask?.cancel()
        pollTask = nil
        await source.relinquish()
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                await self.poll()
            }
        }
    }

    private func poll() async {
        guard !isScrubbing, !isAdvancing, let ours = nowPlaying.song else { return }
        let startedIn = generation
        let snapshot = await source.snapshot()
        // The song changed while we were waiting on the backend; this snapshot
        // describes the past.
        guard startedIn == generation else { return }

        // Until the backend reports *our* song, everything it says describes
        // the previous track — including a playhead sitting at the very end.
        // Song identity is the only reliable handoff signal; position-based
        // heuristics misread the transition as a track ending and skip a song.
        guard let playing = snapshot.song, playing.id == ours.id else {
            if Date().timeIntervalSince(songStartedAt) > Self.handoffGrace {
                await adoptExternalChange(snapshot)
            }
            return
        }
        if !endDetectionArmed {
            endDetectionArmed = true
            // The backend has caught up, so its playhead now belongs to our
            // song; anything carried over from the previous track is stale.
            lastPosition = snapshot.position
            loadArtwork()
        }

        nowPlaying.transport = snapshot.transport
        nowPlaying.position = snapshot.position
        if ours.duration > 0 {
            await checkForTrackEnd(position: snapshot.position, duration: ours.duration)
        }
        lastPosition = snapshot.position
    }

    /// Follows the user when they drive playback from somewhere else.
    ///
    /// Media keys, the Now Playing widget and Music.app's own window all still
    /// work while Clickwheel is open; the iPod should show what is actually
    /// coming out of the speakers rather than insist on its own idea of it.
    private func adoptExternalChange(_ snapshot: NowPlaying) async {
        guard let playing = snapshot.song else { return }
        if let position = queue.firstIndex(where: { $0.id == playing.id }) {
            cursor = position
            nowPlaying.queueIndex = position + 1
        } else {
            nowPlaying.queueIndex = 0
            nowPlaying.queueCount = 0
        }
        nowPlaying.song = playing
        nowPlaying.transport = snapshot.transport
        nowPlaying.position = snapshot.position
        songStartedAt = Date()
        endDetectionArmed = false
        lastPosition = snapshot.position
        generation += 1
        loadArtwork()
    }

    /// Fetches cover art off the polling path — it is megabytes per track and
    /// would otherwise stall every poll for as long as the transfer takes.
    private func loadArtwork() {
        artwork = nil
        let expected = nowPlaying.song?.id
        Task { [weak self] in
            guard let data = await self?.source.currentArtwork() else { return }
            guard let self, self.nowPlaying.song?.id == expected else { return }
            self.artwork = NSImage(data: data)
        }
    }

    /// Advances when the current song is about to finish.
    ///
    /// Two triggers, because neither alone is reliable: the primary one fires
    /// just before the end, and the fallback catches the case where we were
    /// late and Music.app's repeat-one already looped the track back to zero.
    private func checkForTrackEnd(position: TimeInterval, duration: TimeInterval) async {
        guard nowPlaying.transport == .playing else { return }

        let nearEnd = position >= duration - 0.3
        let loopedBack = lastPosition > 1.0 && position < lastPosition - 1.0

        guard nearEnd || loopedBack else { return }
        if Self.traceAdvances {
            let reason = nearEnd ? "nearEnd" : "loopedBack"
            print("[advance] \(reason) pos=\(String(format: "%.2f", position)) "
                + "dur=\(String(format: "%.2f", duration)) last=\(String(format: "%.2f", lastPosition))")
        }
        isAdvancing = true
        defer { isAdvancing = false }
        await next()
    }

    // MARK: - Reordering

    /// Applies a shuffle-mode change without interrupting the current song.
    private func reorderPreservingCurrent() {
        guard !queue.isEmpty, queue.indices.contains(cursor) else { return }
        let playing = queue[cursor]

        switch shuffleMode {
        case .songs:
            queue.shuffle()
        case .off:
            // Playlist order is recoverable from the songs themselves, so no
            // separate pristine copy has to be kept around.
            queue.sort { $0.indexInPlaylist < $1.indexInPlaylist }
        }

        cursor = queue.firstIndex(of: playing) ?? 0
        nowPlaying.queueIndex = cursor + 1
        nowPlaying.queueCount = queue.count
    }
}
