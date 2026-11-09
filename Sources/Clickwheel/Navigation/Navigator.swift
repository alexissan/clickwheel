import Foundation
import Observation

/// Identifies a menu level. Levels are rebuilt from their identifier rather
/// than stored, so a playlist that finishes loading in the background appears
/// without the navigation stack having to be rewritten.
enum LevelID: Hashable {
    case main
    case music
    case playlists
    case extras
    case settings
    case styles
    case tracks(listID: String)
    /// The browse tree over the starred pool: group, then one group's songs.
    case artists
    case albums
    case songs
    case artistSongs(String)
    case albumSongs(String)
}

/// What is currently on the screen.
enum Screen: Hashable {
    case boot
    case menu(LevelID)
    case nowPlaying
    case clock
    case brick
    case about
    case message(title: String, detail: String)
}

/// One entry in the navigation stack.
///
/// Selection lives with the level, which is why backing out of a playlist
/// returns you to the row you came from instead of the top — a small thing
/// that the real device got right and most recreations don't.
struct StackEntry: Hashable {
    var screen: Screen
    var selection: Int = 0
    /// First visible row, so long lists keep their scroll offset too.
    var window: Int = 0
}

/// A drawable row.
struct Row: Identifiable, Hashable {
    let id: String
    let title: String
    /// Right-aligned value, used by Settings rows.
    var detail: String?
    var showsChevron: Bool = false
}

/// Drives the menu system: what is on screen, where the selection is, and what
/// each button does.
@MainActor
@Observable
final class Navigator {
    private(set) var stack: [StackEntry] = [StackEntry(screen: .boot)]

    private let library: Library
    private let player: Player
    private let device: DeviceState
    private let clicker: Clicker

    /// Number of rows the LCD can show at once.
    ///
    /// Nine over the 218 usable pixels gives ~24px rows, close to the real
    /// device. Eight left the rows tall enough that the type looked oversized
    /// and the list read as a Mac table view rather than an iPod menu.
    static let visibleRows = 9

    init(library: Library, player: Player, device: DeviceState, clicker: Clicker) {
        self.library = library
        self.player = player
        self.device = device
        self.clicker = clicker
    }

    var current: StackEntry { stack[stack.count - 1] }
    var screen: Screen { current.screen }

    // MARK: - Boot

    func finishBoot() {
        stack = [StackEntry(screen: .menu(.main))]
    }

    // MARK: - Rows

    /// Builds the rows for a level on demand.
    func rows(for level: LevelID) -> [Row] {
        switch level {
        case .main:
            var rows = [
                Row(id: "music", title: t("menu.music", "Music"), showsChevron: true),
                Row(id: "extras", title: t("menu.extras", "Extras"), showsChevron: true),
                Row(id: "settings", title: t("menu.settings", "Settings"), showsChevron: true),
                Row(id: "shuffle", title: t("menu.shuffle_songs", "Shuffle Songs")),
            ]
            if player.nowPlaying.song != nil {
                rows.append(
                    Row(id: "nowplaying", title: t("menu.now_playing", "Now Playing"), showsChevron: true)
                )
            }
            return rows

        case .music:
            return [
                Row(id: "playlists", title: t("menu.playlists", "Playlists"), showsChevron: true),
                Row(id: "artists", title: t("menu.artists", "Artists"), showsChevron: true),
                Row(id: "albums", title: t("menu.albums", "Albums"), showsChevron: true),
                Row(id: "songs", title: t("menu.songs", "Songs"), showsChevron: true),
            ]

        case .artists:
            guard let songs = browsePool else { return [loadingRow] }
            return groups(of: songs, by: \.artist).map {
                Row(id: $0, title: $0, showsChevron: true)
            }

        case .albums:
            guard let songs = browsePool else { return [loadingRow] }
            return groups(of: songs, by: \.album).map {
                Row(id: $0, title: $0, showsChevron: true)
            }

        case .songs:
            guard let songs = browsePool else { return [loadingRow] }
            return browseQueue(for: .songs, in: songs).map { Row(id: $0.id, title: $0.title) }

        case .artistSongs, .albumSongs:
            guard let songs = browsePool else { return [loadingRow] }
            return browseQueue(for: level, in: songs).map { Row(id: $0.id, title: $0.title) }

        case .playlists:
            return library.playlists.map {
                Row(id: $0.id, title: $0.name, showsChevron: true)
            }

        case .tracks(let listID):
            guard let list = library.playlists.first(where: { $0.id == listID }),
                  let songs = library.cachedSongs(in: list)
            else {
                return [Row(id: "loading", title: t("menu.loading", "Loading…"))]
            }
            return songs.map { Row(id: $0.id, title: $0.title) }

        case .extras:
            return [
                Row(id: "clock", title: t("menu.clock", "Clock"), showsChevron: true),
                Row(id: "brick", title: t("menu.brick", "Brick"), showsChevron: true),
            ]

        case .styles:
            return DeviceStyle.allCases.map { style in
                Row(id: style.rawValue, title: style.label,
                    detail: device.style == style ? "✓" : nil)
            }

        case .settings:
            return [
                Row(id: "style", title: t("menu.style", "Style"),
                    detail: device.style.label, showsChevron: true),
                // The physical switch lives on the top edge of the real device,
                // which isn't visible face-on, so this is its only home besides
                // the H key.
                Row(id: "hold", title: t("menu.hold", "Hold"),
                    detail: onOff(device.isHeld)),
                Row(id: "shufflemode", title: t("menu.shuffle", "Shuffle"),
                    detail: player.shuffleMode.label),
                Row(id: "repeatmode", title: t("menu.repeat", "Repeat"),
                    detail: player.repeatMode.label),
                Row(id: "clicker", title: t("menu.clicker", "Clicker"),
                    detail: onOff(device.isClickerOn)),
                Row(id: "haptics", title: t("menu.haptics", "Haptics"),
                    detail: onOff(device.isHapticsOn)),
                Row(id: "backlight", title: t("menu.backlight", "Backlight Timer"),
                    detail: backlightLabel),
                Row(id: "actualsize", title: t("menu.actual_size", "Actual Size"),
                    detail: onOff(device.isActualSize)),
                Row(id: "float", title: t("menu.float", "Float on Top"),
                    detail: onOff(device.floatsAboveOtherWindows)),
                Row(id: "about", title: t("menu.about", "About"), showsChevron: true),
            ]
        }
    }

    var currentRows: [Row] {
        if case .menu(let level) = screen { return rows(for: level) }
        return []
    }

    // MARK: - Browsing

    /// The pool the Artists/Albums/Songs menus browse: the starred playlist.
    private var browseList: SongList? { library.favourites ?? library.playlists.first }
    private var browsePool: [Song]? { browseList.flatMap { library.cachedSongs(in: $0) } }

    private var loadingRow: Row { Row(id: "loading", title: t("menu.loading", "Loading…")) }

    /// Distinct group names (artists or albums), sorted the way the iPod
    /// sorted them. Songs with an empty tag group under "Unknown".
    private func groups(of songs: [Song], by key: KeyPath<Song, String>) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for song in songs {
            let name = displayName(song[keyPath: key])
            if seen.insert(name).inserted { names.append(name) }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The play queue a browse level stands for, in the order its menu shows.
    private func browseQueue(for level: LevelID, in songs: [Song]) -> [Song] {
        switch level {
        case .songs:
            return songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artistSongs(let artist):
            return songs
                .filter { displayName($0.artist) == artist }
                .sorted {
                    if $0.album != $1.album {
                        return $0.album.localizedStandardCompare($1.album) == .orderedAscending
                    }
                    return $0.indexInPlaylist < $1.indexInPlaylist
                }
        case .albumSongs(let album):
            return songs
                .filter { displayName($0.album) == album }
                .sorted { $0.indexInPlaylist < $1.indexInPlaylist }
        default:
            return songs
        }
    }

    private func displayName(_ tag: String) -> String {
        tag.isEmpty ? t("menu.unknown", "Unknown") : tag
    }

    var title: String {
        switch screen {
        case .menu(.main): t("title.ipod", "iPod")
        case .menu(.music): t("menu.music", "Music")
        case .menu(.playlists): t("menu.playlists", "Playlists")
        case .menu(.extras): t("menu.extras", "Extras")
        case .menu(.settings): t("menu.settings", "Settings")
        case .menu(.styles): t("menu.style", "Style")
        case .menu(.tracks(let listID)):
            library.playlists.first(where: { $0.id == listID })?.name ?? t("menu.songs", "Songs")
        case .menu(.artists): t("menu.artists", "Artists")
        case .menu(.albums): t("menu.albums", "Albums")
        case .menu(.songs): t("menu.songs", "Songs")
        case .menu(.artistSongs(let artist)): artist
        case .menu(.albumSongs(let album)): album
        case .nowPlaying: t("title.now_playing", "Now Playing")
        case .clock: t("menu.clock", "Clock")
        case .brick: t("menu.brick", "Brick")
        case .about: t("menu.about", "About")
        case .boot: ""
        case .message(let title, _): title
        }
    }

    // MARK: - Wheel

    /// Moves the selection. `steps` is signed; clockwise is positive.
    func scroll(by steps: Int) {
        guard steps != 0 else { return }
        device.wake()

        if case .nowPlaying = screen {
            // The real device's wheel adjusts *volume* on Now Playing; it only
            // scrubs once Select has armed the scrubber.
            if player.isScrubArmed {
                scrubBy(steps)
                scheduleScrubDisarm()
            } else {
                player.adjustVolume(by: steps)
                feedback()
            }
            return
        }

        let count = currentRows.count
        guard count > 0 else { return }

        var entry = current
        let target = max(0, min(count - 1, entry.selection + steps))
        guard target != entry.selection else { return }
        entry.selection = target

        // Keep the selection inside the visible window, scrolling it only as
        // far as needed — the iPod never re-centres the list.
        if entry.selection < entry.window {
            entry.window = entry.selection
        } else if entry.selection >= entry.window + Self.visibleRows {
            entry.window = entry.selection - Self.visibleRows + 1
        }
        entry.window = max(0, min(entry.window, max(0, count - Self.visibleRows)))

        stack[stack.count - 1] = entry
        feedback()
    }

    /// On Now Playing the wheel scrubs through the track instead of scrolling.
    private func scrubBy(_ steps: Int) {
        guard let duration = player.nowPlaying.song?.duration, duration > 0 else { return }
        if !player.isScrubbing {
            player.scrubTarget = player.nowPlaying.position
            player.isScrubbing = true
        }
        let increment = max(1, duration / 120)
        player.scrubTarget = min(duration, max(0, player.scrubTarget + Double(steps) * increment))
        player.previewScrub(at: player.scrubTarget)
        feedback()
    }

    /// Ends a scrub once the wheel has been still for a moment.
    func endScrubIfNeeded() {
        guard player.isScrubbing else { return }
        player.isScrubbing = false
    }

    /// The wheel has been still for a moment: commit any scrub and put the
    /// volume bar away.
    func wheelIdled() {
        player.wheelIdled()
    }

    /// The armed scrubber reverts to the plain progress bar after a few idle
    /// seconds, the way the real screen does.
    private var scrubDisarmTask: Task<Void, Never>?

    private func scheduleScrubDisarm() {
        scrubDisarmTask?.cancel()
        scrubDisarmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.player.isScrubArmed = false
        }
    }

    private func feedback() {
        if device.isClickerOn { clicker.tick() }
        if device.isHapticsOn { Haptics.detent() }
    }

    // MARK: - Buttons

    func pressSelect() {
        device.wake()
        if device.isHapticsOn { Haptics.press() }

        switch screen {
        case .boot:
            finishBoot()
        case .nowPlaying:
            // Select toggles the scrubber, as on the real device. Arming it is
            // what hands the wheel over from volume to seeking.
            endScrubIfNeeded()
            player.isScrubArmed.toggle()
            if player.isScrubArmed { scheduleScrubDisarm() }
        case .menu(let level):
            activate(row: current.selection, in: level)
        case .brick, .clock, .about, .message:
            break
        }
    }

    func pressMenu() {
        device.wake()
        if device.isHapticsOn { Haptics.press() }
        endScrubIfNeeded()
        player.isScrubArmed = false

        if stack.count > 1 {
            stack.removeLast()
        }
    }

    func pressPlayPause() {
        device.wake()
        Task { await player.togglePlayPause() }
    }

    func pressNext() {
        device.wake()
        Task { await player.next() }
    }

    func pressPrevious() {
        device.wake()
        Task { await player.previous() }
    }

    // MARK: - Activation

    private func activate(row index: Int, in level: LevelID) {
        let rows = self.rows(for: level)
        guard rows.indices.contains(index) else { return }
        let row = rows[index]

        switch level {
        case .main:
            switch row.id {
            case "music": push(.menu(.music))
            case "extras": push(.menu(.extras))
            case "settings": push(.menu(.settings))
            case "shuffle": shuffleEverything()
            case "nowplaying": push(.nowPlaying)
            default: break
            }

        case .music:
            switch row.id {
            case "playlists": push(.menu(.playlists))
            case "artists": openBrowse(.artists)
            case "albums": openBrowse(.albums)
            case "songs": openBrowse(.songs)
            default: break
            }

        case .playlists:
            guard let list = library.playlists.first(where: { $0.id == row.id }) else { return }
            openTracks(in: list)

        case .tracks(let listID):
            guard let list = library.playlists.first(where: { $0.id == listID }),
                  let songs = library.cachedSongs(in: list),
                  songs.indices.contains(index)
            else { return }
            Task {
                await player.play(list: list, songs: songs, startingAt: index)
                push(.nowPlaying)
            }

        case .artists:
            guard row.id != "loading" else { return }
            push(.menu(.artistSongs(row.title)))

        case .albums:
            guard row.id != "loading" else { return }
            push(.menu(.albumSongs(row.title)))

        case .songs, .artistSongs, .albumSongs:
            guard let list = browseList, let pool = browsePool else { return }
            let queue = browseQueue(for: level, in: pool)
            guard queue.indices.contains(index) else { return }
            Task {
                await player.play(list: list, songs: queue, startingAt: index)
                push(.nowPlaying)
            }

        case .extras:
            switch row.id {
            case "clock": push(.clock)
            case "brick": push(.brick)
            default: break
            }

        case .styles:
            if let style = DeviceStyle(rawValue: row.id) { device.style = style }

        case .settings:
            applySetting(row.id)
        }
    }

    private func openTracks(in list: SongList) {
        // Push straight away and let the rows fill in: waiting for the fetch
        // before showing anything would make Select feel unresponsive.
        push(.menu(.tracks(listID: list.id)))
        if library.cachedSongs(in: list) == nil {
            Task { _ = await library.songs(in: list) }
        }
    }

    /// Same immediate-push pattern for the browse levels, which all read from
    /// the starred pool.
    private func openBrowse(_ level: LevelID) {
        push(.menu(level))
        if let list = browseList, library.cachedSongs(in: list) == nil {
            Task { _ = await library.songs(in: list) }
        }
    }

    private func shuffleEverything() {
        guard let list = library.favourites ?? library.playlists.first else { return }
        Task {
            let songs = await library.songs(in: list)
            guard !songs.isEmpty else { return }
            await player.shuffleAll(list: list, songs: songs)
            push(.nowPlaying)
        }
    }

    private func applySetting(_ id: String) {
        switch id {
        case "style":
            push(.menu(.styles))
            if let index = DeviceStyle.allCases.firstIndex(of: device.style) {
                scroll(by: index)
            }
        case "hold":
            device.isHeld.toggle()
        case "shufflemode":
            player.shuffleMode = player.shuffleMode == .off ? .songs : .off
        case "repeatmode":
            player.repeatMode =
                switch player.repeatMode {
                case .off: .all
                case .all: .one
                case .one: .off
                }
        case "clicker":
            device.isClickerOn.toggle()
        case "haptics":
            device.isHapticsOn.toggle()
        case "backlight":
            device.backlightTimeout = Self.nextBacklightTimeout(after: device.backlightTimeout)
        case "actualsize":
            device.isActualSize.toggle()
        case "float":
            device.floatsAboveOtherWindows.toggle()
        case "about":
            push(.about)
        default:
            break
        }
    }

    private func push(_ screen: Screen) {
        stack.append(StackEntry(screen: screen))
    }

    /// Pushes a screen directly. Only for `Snapshot`, which needs to pose the
    /// UI on a given screen without simulating the button presses to get there.
    func previewPush(_ screen: Screen) {
        push(screen)
    }

    /// Replaces the whole stack, used when the library fails to load.
    func showMessage(title: String, detail: String) {
        stack = [StackEntry(screen: .message(title: title, detail: detail))]
    }

    // MARK: - Labels

    private static let backlightOptions: [TimeInterval] = [0, 5, 10, 20, 60]

    private static func nextBacklightTimeout(after current: TimeInterval) -> TimeInterval {
        let index = backlightOptions.firstIndex(of: current) ?? 3
        return backlightOptions[(index + 1) % backlightOptions.count]
    }

    private var backlightLabel: String {
        device.backlightTimeout == 0
            ? t("backlight.always", "Always On")
            : String(
                format: t("backlight.seconds", "%d Seconds"),
                Int(device.backlightTimeout)
            )
    }

    private func onOff(_ value: Bool) -> String {
        value ? t("common.on", "On") : t("common.off", "Off")
    }

    /// Menu keys are built at runtime, so the `String(localized:)` overloads —
    /// which need a compile-time key — don't apply here.
    private func t(_ key: String, _ fallback: String) -> String {
        Bundle.module.localizedString(forKey: key, value: fallback, table: nil)
    }
}
