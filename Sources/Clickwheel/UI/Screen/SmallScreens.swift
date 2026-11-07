import SwiftUI

/// The Apple logo on black, held for a beat before the menu appears.
struct BootView: View {
    let unit: CGFloat
    @State private var isVisible = false

    var body: some View {
        ZStack {
            Color.black
            Image(systemName: "apple.logo")
                .font(.system(size: 62 * unit))
                .foregroundStyle(.white)
                .opacity(isVisible ? 1 : 0)
                // The real device's logo appeared as the backlight came up
                // rather than snapping on.
                .animation(.easeIn(duration: 0.6), value: isVisible)
        }
        .onAppear { isVisible = true }
        .accessibilityLabel(
            String(localized: "a11y.starting", defaultValue: "iPod starting up", bundle: .module)
        )
    }
}

/// Extras → Clock. Shows the real time, in the iPod's face.
struct ClockView: View {
    let unit: CGFloat
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 6 * unit) {
            Spacer(minLength: 0)
            Text(now, format: .dateTime.hour().minute().second())
                .lcdFont(cap: 32, bold: false, unit: unit)
                .foregroundStyle(Palette.screenInk)
                .monospacedDigit()
            Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                .lcdFont(cap: 9, unit: unit)
                .foregroundStyle(Palette.screenInkDim)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onReceive(tick) { now = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// Settings → About: the counts a real iPod reported about itself.
struct AboutView: View {
    @Environment(Library.self) private var library

    let unit: CGFloat
    let backendName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * unit) {
            row(String(localized: "about.playlists", defaultValue: "Playlists", bundle: .module),
                "\(library.playlists.count)")
            row(String(localized: "about.songs", defaultValue: "Songs", bundle: .module),
                library.totalSongs > 0 ? "\(library.totalSongs)" : "—")
            row(String(localized: "about.source", defaultValue: "Source", bundle: .module), backendName)
            row(String(localized: "about.model", defaultValue: "Model", bundle: .module), "M9829")
            row(String(localized: "about.version", defaultValue: "Version", bundle: .module), "1.1")

            Spacer(minLength: 0)

            Text(String(localized: "about.note", defaultValue: "Clickwheel", bundle: .module))
                .lcdFont(cap: 7, unit: unit)
                .foregroundStyle(Palette.screenInkDim)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 10 * unit)
        .padding(.vertical, 10 * unit)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .lcdFont(cap: 9, unit: unit)
                .foregroundStyle(Palette.screenInkDim)
            Spacer(minLength: 6 * unit)
            Text(value)
                .lcdFont(cap: 9, bold: true, unit: unit)
                .foregroundStyle(Palette.screenInk)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A full-screen message, in the device's own voice rather than a macOS alert
/// — an alert sheet over the iPod would break the illusion completely.
struct MessageView: View {
    let unit: CGFloat
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8 * unit) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30 * unit))
                .foregroundStyle(Palette.screenInkDim)
            Text(title)
                .lcdFont(cap: 11, bold: true, unit: unit)
                .foregroundStyle(Palette.screenInk)
            Text(detail)
                .lcdFont(cap: 8, unit: unit)
                .foregroundStyle(Palette.screenInkDim)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16 * unit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}
