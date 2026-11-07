import SwiftUI

/// Colours sampled from the 5th-generation iPod and its UI.
///
/// The body is not white — it is a very slightly cool off-white under a clear
/// polycarbonate coat, and reading it as pure white is the single fastest way
/// to make a render look fake.
enum Palette {
    // MARK: - Hardware

    static let shellBase = Color(red: 0.957, green: 0.961, blue: 0.965)
    static let shellShadow = Color(red: 0.741, green: 0.753, blue: 0.773)
    static let shellHighlight = Color.white

    /// Classic-style wheel: a flat matte white disc, a half-step below the
    /// shell's clearcoat white.
    static let wheelBase = Color(red: 0.948, green: 0.950, blue: 0.954)
    static let wheelRim = Color(red: 0.850, green: 0.854, blue: 0.862)

    /// Grey glyphs printed on the white wheel — the Classic treatment, where
    /// MENU and the transport marks sit a few steps down from the disc.
    static let wheelLabel = Color(red: 0.564, green: 0.572, blue: 0.588)

    /// Bare-metal silver, clearly darker than the wheel around it.
    static let centreButton = Color(red: 0.784, green: 0.792, blue: 0.808)
    static let bezel = Color(red: 0.086, green: 0.086, blue: 0.094)

    // MARK: - Screen

    /// The 5G framebuffer is pure white, flat to within a level or two across
    /// the whole panel. The warm-green cast belongs to the *monochrome* iPods
    /// with EL backlights; this one is a neutral transflective panel. The
    /// panel's own response — lifted blacks, not-quite-paper white, the pixel
    /// grid — is applied by the `screenGlass` shader, so screen content keeps
    /// drawing against the ideal framebuffer values.
    static let screenBacklight = Color.white

    /// What the transflective panel looks like running on ambient light alone:
    /// a pale grey-green slate. Overlaid on the screen when the backlight
    /// times out.
    static let unlitWash = Color(red: 0.55, green: 0.57, blue: 0.53)
    static let screenInk = Color.black
    /// Kept only for the empty-artwork placeholder. The real menu UI has no
    /// grey text anywhere — every glyph is pure black.
    static let screenInkDim = Color(red: 0.443, green: 0.451, blue: 0.463)

    /// Selection bar: a blue vertical gradient with a darker rule top and
    /// bottom, measured off Apple's own 320×240 captures.
    static let selectionTop = Color(red: 0.373, green: 0.635, blue: 0.933)
    static let selectionBottom = Color(red: 0.141, green: 0.392, blue: 0.824)
    static let selectionEdge = Color(red: 0.235, green: 0.420, blue: 0.647)

    /// Status bar: an Aqua two-band gradient with a hard gloss step at 43%.
    /// Far lighter than a modern eye expects.
    static let chromeTop = Color(red: 0.953, green: 0.969, blue: 0.980)
    static let chromeGlossTop = Color(red: 0.894, green: 0.914, blue: 0.925)
    static let chromeGlossBottom = Color(red: 0.851, green: 0.867, blue: 0.882)
    static let chromeBottom = Color(red: 0.804, green: 0.820, blue: 0.831)

    /// The 1px rule under the status bar is a genuinely dark hairline, and it
    /// does a lot of work separating chrome from content.
    static let dividerLine = Color(red: 0.431, green: 0.439, blue: 0.451)

    /// The play/pause glyph in the status bar is blue, not black.
    static let transportGlyph = Color(red: 0.161, green: 0.553, blue: 0.831)
    /// Battery fill is green in the *normal* state, not just when charging.
    static let batteryFillTop = Color(red: 0.620, green: 0.910, blue: 0.420)
    static let batteryFillBottom = Color(red: 0.180, green: 0.620, blue: 0.070)
    static let batteryOutline = Color(red: 0.290, green: 0.298, blue: 0.314)

    /// Empty-artwork placeholder on Now Playing.
    static let progressTrack = Color(red: 0.808, green: 0.816, blue: 0.827)
}
