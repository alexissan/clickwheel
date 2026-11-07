import SwiftUI

/// Points per LCD unit.
///
/// The screen is laid out in the panel's native 320×240 grid and multiplied up
/// by this, so every proportion matches the real device at any window size
/// while text still renders as crisp vectors rather than a scaled bitmap.
private struct ScreenUnitKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var lcdUnit: CGFloat {
        get { self[ScreenUnitKey.self] }
        set { self[ScreenUnitKey.self] = newValue }
    }
}

/// Typeface for the LCD.
///
/// The 5G set its interface in Podium Sans, a humanist sans in the Myriad
/// family. Nothing that close ships with macOS, but Helvetica Neue is a far
/// better period stand-in than the system font: SF's single-storey shapes and
/// tall x-height are unmistakably modern, and they were the loudest signal
/// that this was a Mac app wearing an iPod costume.
enum LCDType {
    /// Lucida Grande is the 2005 Apple humanist — contemporaneous with the 5G,
    /// single-storey `g`, and hinted for small sizes. Podium Sans itself is a
    /// Myriad derivative that macOS doesn't ship, and SF is wrong in genre:
    /// closed apertures and a mechanical rhythm that read as a modern Mac app.
    static let regular = "LucidaGrande"
    static let bold = "LucidaGrande-Bold"

    /// Cap height as a fraction of em, for Lucida Grande.
    static let capRatio: CGFloat = 0.723

    /// Sizes type by CAP HEIGHT in LCD pixels, which is the only stable way to
    /// match a bitmap UI: the source measurements are all cap heights, and
    /// point size means nothing across two different typefaces.
    static func font(cap: CGFloat, bold isBold: Bool) -> Font {
        .custom(isBold ? bold : regular, fixedSize: cap / capRatio)
    }
}

extension View {
    /// Sizes text by cap height in LCD pixels.
    func lcdFont(cap: CGFloat, bold: Bool = false, unit: CGFloat) -> some View {
        font(LCDType.font(cap: cap * unit, bold: bold))
    }
}

/// The LCD: status bar plus whatever screen is current.
struct ScreenView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(Player.self) private var player
    @Environment(DeviceState.self) private var device
    @Environment(Library.self) private var library

    let unit: CGFloat

    var body: some View {
        ZStack {
            Palette.screenBacklight

            VStack(spacing: 0) {
                if showsStatusBar {
                    // 23px of gradient plus a 1px rule = 24, leaving exactly
                    // 216 for nine 24px rows.
                    StatusBar(unit: unit)
                    Rectangle()
                        .fill(Palette.dividerLine)
                        .frame(height: unit)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Backlight, drawn as a wash over the panel rather than with
            // `.brightness()`/`.saturation()`. Those are colour filters, which
            // push the whole screen into an offscreen layer — that inverted the
            // apparent contrast when dimmed and left a pale box behind every
            // run of text. A plain overlay leaves text rendering untouched.
            //
            // The wash is grey-green, not black: the 5G panel is transflective,
            // so with the backlight off it reads by ambient light — a pale,
            // low-contrast slate, the way an unlit Game Boy screen looks. Going
            // dark is what a *powered-off* device does, and it read as a crash.
            Rectangle()
                .fill(Palette.unlitWash)
                .opacity(device.isBacklightOn ? 0 : 0.52)
                .allowsHitTesting(false)
        }
        .environment(\.lcdUnit, unit)
        // Fades rather than snapping, the way a CCFL panel does.
        .animation(.easeInOut(duration: 0.55), value: device.isBacklightOn)
    }

    private var showsStatusBar: Bool {
        switch navigator.screen {
        case .boot, .brick: false
        default: true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch navigator.screen {
        case .boot:
            BootView(unit: unit)
        case .menu:
            MenuListView(unit: unit)
        case .nowPlaying:
            NowPlayingView(unit: unit)
        case .clock:
            ClockView(unit: unit)
        case .about:
            AboutView(unit: unit, backendName: library.backendName)
        case .brick:
            BrickView(unit: unit)
        case .message(let title, let detail):
            MessageView(unit: unit, title: title, detail: detail)
        }
    }
}

// MARK: - Status bar

/// Title, playback glyph, hold padlock and battery meter.
struct StatusBar: View {
    @Environment(Navigator.self) private var navigator
    @Environment(Player.self) private var player
    @Environment(DeviceState.self) private var device

    let unit: CGFloat

    var body: some View {
        ZStack {
            // Aqua: a hard gloss step at 43%, not a single linear ramp.
            LinearGradient(
                stops: [
                    .init(color: Palette.chromeTop, location: 0.00),
                    .init(color: Palette.chromeGlossTop, location: 0.43),
                    .init(color: Palette.chromeGlossBottom, location: 0.43),
                    .init(color: Palette.chromeBottom, location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(spacing: 3 * unit) {
                transportGlyph
                if device.isHeld { padlock }
                Spacer(minLength: 0)
                battery
            }
            .padding(.leading, 13 * unit)
            .padding(.trailing, 10 * unit)

            // The title is regular weight, not semibold.
            Text(navigator.title)
                .lcdFont(cap: 11, unit: unit)
                .foregroundStyle(Palette.screenInk)
                .lineLimit(1)
                .padding(.horizontal, 46 * unit)
        }
        .frame(height: 23 * unit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var transportGlyph: some View {
        switch player.nowPlaying.transport {
        case .playing:
            Image(systemName: "play.fill")
                .font(.system(size: 12 * unit))
                .foregroundStyle(Palette.transportGlyph)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 12 * unit))
                .foregroundStyle(Palette.transportGlyph)
        case .stopped:
            Color.clear.frame(width: 8 * unit, height: 12 * unit)
        }
    }

    private var padlock: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 9 * unit))
            .foregroundStyle(Palette.screenInk)
    }

    /// 20 × 12 cell with a 3 × 5 nub, measured off the reference capture.
    private var battery: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5 * unit, style: .circular)
                    .stroke(Palette.batteryOutline, lineWidth: unit)
                    .frame(width: 20 * unit, height: 12 * unit)

                RoundedRectangle(cornerRadius: 0.5 * unit, style: .circular)
                    .fill(fill)
                    .frame(width: max(0, 18 * unit * device.batteryLevel), height: 10 * unit)
                    .padding(.leading, unit)

                // The real device overlays a bolt on the meter while it charges.
                // Only while genuinely charging: desktop Macs report no battery
                // and show a full, boltless meter instead.
                if device.isCharging, device.batteryLevel < 0.97 {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8 * unit, weight: .bold))
                        .foregroundStyle(Palette.batteryOutline)
                        .frame(width: 20 * unit)
                }
            }
            RoundedRectangle(cornerRadius: 0.5 * unit)
                .fill(Palette.batteryOutline)
                .frame(width: 3 * unit, height: 5 * unit)
        }
    }

    /// Green is the *normal* state on the real device, not the charging state.
    private var fill: LinearGradient {
        let colours: [Color] =
            device.batteryLevel < 0.2
                ? [Color(red: 0.95, green: 0.45, blue: 0.35), Color(red: 0.72, green: 0.14, blue: 0.10)]
                : [Palette.batteryFillTop, Palette.batteryFillBottom]
        return LinearGradient(colors: colours, startPoint: .top, endPoint: .bottom)
    }

    private var accessibilitySummary: String {
        var parts = [navigator.title]
        if device.isHeld {
            parts.append(String(localized: "a11y.hold_on", defaultValue: "Hold switch on", bundle: .module))
        }
        if device.isCharging, device.batteryLevel < 0.97 {
            parts.append(String(localized: "a11y.charging", defaultValue: "Charging", bundle: .module))
        }
        parts.append(
            String(
                format: String(localized: "a11y.battery", defaultValue: "Battery %d percent", bundle: .module),
                Int(device.batteryLevel * 100)
            )
        )
        return parts.joined(separator: ", ")
    }
}

// MARK: - Menu list

/// The scrolling list of rows, with the iPod's blue selection bar.
struct MenuListView: View {
    @Environment(Navigator.self) private var navigator

    let unit: CGFloat

    var body: some View {
        let entry = navigator.current
        let rows = navigator.currentRows
        let visible = Navigator.visibleRows
        // Exactly 24, not a division of the available space: 24 status + 9×24
        // rows = 240, which is the whole panel and how the real grid resolves.
        let rowHeight = 24.0

        VStack(spacing: 0) {
            // Identified by position, not by row id: the same track can appear
            // twice in a playlist and would then share an id, which makes
            // ForEach mis-associate rows and breaks the selection highlight.
            ForEach(Array(rows.dropFirst(entry.window).prefix(visible).enumerated()), id: \.offset) {
                offset, row in
                MenuRow(
                    row: row,
                    isSelected: entry.window + offset == entry.selection,
                    height: rowHeight * unit,
                    unit: unit
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(navigator.title)
    }
}

private struct MenuRow: View {
    let row: Row
    let isSelected: Bool
    let height: CGFloat
    let unit: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // Selection does not change the weight on the real device: the
            // selected and unselected rows have identical stems. Every row is
            // semibold, and there is no grey text anywhere in the menu UI.
            Text(row.title)
                .lcdFont(cap: 12, bold: true, unit: unit)
                .foregroundStyle(isSelected ? Color.white : Palette.screenInk)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4 * unit)

            if let detail = row.detail {
                Text(detail)
                    .lcdFont(cap: 11, bold: true, unit: unit)
                    .foregroundStyle(isSelected ? Color.white : Palette.screenInk)
                    .lineLimit(1)
            }
            if row.showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16 * unit, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Palette.screenInk)
                    .padding(.leading, 4 * unit)
            }
        }
        .padding(.leading, 11 * unit)
        .padding(.trailing, 8 * unit)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background {
            if isSelected {
                ZStack {
                    LinearGradient(
                        colors: [Palette.selectionTop, Palette.selectionBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // A darker rule top and bottom, which is what stops the
                    // bar reading as a flat block of colour.
                    VStack(spacing: 0) {
                        Palette.selectionEdge.frame(height: unit)
                        Spacer(minLength: 0)
                        Palette.selectionEdge.frame(height: unit)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.detail.map { "\(row.title), \($0)" } ?? row.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isStaticText] : .isStaticText)
    }
}
