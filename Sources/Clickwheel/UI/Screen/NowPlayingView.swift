import SwiftUI

/// The Now Playing screen.
///
/// Laid out by absolute position in the LCD's 320×240 grid, measured off the
/// framebuffer captures in Apple's *Fifth Gen iPod Features Guide*. Positions
/// below are local to the content area, i.e. 24px less than the figures in
/// that document, because the status bar is a sibling view.
struct NowPlayingView: View {
    @Environment(Player.self) private var player

    let unit: CGFloat

    var body: some View {
        let state = player.nowPlaying

        ZStack(alignment: .topLeading) {
            Color.clear

            queuePosition(for: state)
            artwork
                .frame(width: 96 * unit, height: 96 * unit)
                .offset(x: 14 * unit, y: 36 * unit)

            songInfo(for: state)
            progress(for: state)
            times(for: state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary(for: state))
        .accessibilityValue(timeSummary(for: state))
    }

    // MARK: - Queue position

    /// "3 of 182" sits at the top-left of the whole screen, above the artwork —
    /// not tucked under the album name.
    @ViewBuilder
    private func queuePosition(for state: NowPlaying) -> some View {
        if state.queueCount > 0 {
            Text(
                String(
                    format: String(localized: "now.of", defaultValue: "%1$d of %2$d", bundle: .module),
                    state.queueIndex,
                    state.queueCount
                )
            )
            .lcdFont(cap: 11, bold: true, unit: unit)
            .foregroundStyle(Palette.screenInk)
            .offset(x: 14 * unit, y: 6 * unit)
        }
    }

    // MARK: - Artwork

    /// A bare bitmap: no border, no shadow, no rounded corners. The frame and
    /// drop shadow were pure 2024 app styling.
    private var artwork: some View {
        Group {
            if let image = player.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(Palette.progressTrack)
                    Image(systemName: "music.note")
                        .font(.system(size: 26 * unit))
                        .foregroundStyle(Palette.screenInkDim)
                }
            }
        }
        .clipped()
    }

    // MARK: - Song info

    /// Three lines at identical size and weight, on a 29px baseline pitch.
    ///
    /// There is deliberately no visual hierarchy here — the real device sets
    /// title, artist and album all at cap 12 semibold in pure black.
    private func songInfo(for state: NowPlaying) -> some View {
        let lines = [
            state.song?.title
                ?? String(localized: "now.nothing", defaultValue: "Not Playing", bundle: .module),
            state.song?.artist ?? "",
            state.song?.album ?? "",
        ]

        return ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            Text(line)
                .lcdFont(cap: 12, bold: true, unit: unit)
                .foregroundStyle(Palette.screenInk)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 190 * unit, alignment: .leading)
                .offset(x: 119 * unit, y: (46 + CGFloat(index) * 29) * unit)
        }
    }

    // MARK: - Progress

    private func progress(for state: NowPlaying) -> some View {
        let duration = state.song?.duration ?? 0
        let fraction = duration > 0 ? min(1, max(0, state.position / duration)) : 0

        return ZStack(alignment: .leading) {
            Capsule().fill(Self.trackGradient)
            Capsule()
                .fill(Self.fillGradient)
                .frame(width: 282 * unit * fraction)
        }
        .frame(width: 282 * unit, height: 14 * unit)
        .overlay {
            Capsule().strokeBorder(Color(white: 0.718), lineWidth: max(0.5, unit))
        }
        .offset(x: 19 * unit, y: 158 * unit)
    }

    /// Glossy Aqua capsule — a bright band across the upper half, not a flat fill.
    private static let trackGradient = LinearGradient(
        stops: [
            .init(color: Color(white: 0.898), location: 0.00),
            .init(color: Color(white: 0.816), location: 0.45),
            .init(color: Color(white: 0.976), location: 1.00),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    private static let fillGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.533, green: 0.776, blue: 0.996), location: 0.00),
            .init(color: Color(red: 0.208, green: 0.592, blue: 0.894), location: 0.45),
            .init(color: Color(red: 0.663, green: 0.890, blue: 0.988), location: 1.00),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Times

    private func times(for state: NowPlaying) -> some View {
        let duration = state.song?.duration ?? 0

        return HStack(spacing: 0) {
            Text(Self.time(state.position))
            Spacer(minLength: 0)
            Text("-" + Self.time(max(0, duration - state.position)))
        }
        .lcdFont(cap: 11, bold: true, unit: unit)
        .foregroundStyle(Palette.screenInk)
        .frame(width: 282 * unit)
        .offset(x: 19 * unit, y: 180 * unit)
    }

    // MARK: - Formatting

    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func summary(for state: NowPlaying) -> String {
        guard let song = state.song else {
            return String(localized: "now.nothing", defaultValue: "Not Playing", bundle: .module)
        }
        return "\(song.title), \(song.artist), \(song.album)"
    }

    private func timeSummary(for state: NowPlaying) -> String {
        let elapsed = Self.time(state.position)
        let total = Self.time(state.song?.duration ?? 0)
        return String(
            format: String(localized: "a11y.elapsed", defaultValue: "%1$@ of %2$@", bundle: .module),
            elapsed,
            total
        )
    }
}
