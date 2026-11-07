import CoreGraphics
import SwiftUI

/// The iPod's physical dimensions, in millimetres.
///
/// Everything on screen is derived from these rather than from hand-tuned
/// pixel values, which is what lets "Actual Size" mode be genuinely
/// life-sized and keeps every proportion right at any scale.
///
/// Figures are for the 5th-generation iPod (30GB), 2005: 103.5 × 61.8 × 11 mm.
enum Metrics {
    // MARK: - Body

    static let bodyWidth: CGFloat = 61.8
    static let bodyHeight: CGFloat = 103.5
    /// A true circular fillet, not a squircle. Fitting the corner arc of a
    /// rectified photograph solves to R = 5.8–5.9 mm with ~1px residual, and
    /// a circle predicts every sample point — Apple's 2005 industrial design
    /// predates continuous-curvature corners, and a squircle here reads modern.
    static let cornerRadius: CGFloat = 5.9

    // MARK: - Screen

    /// 2.5" diagonal at 4:3 — 320×240 physical pixels.
    static let screenWidth: CGFloat = 50.8
    static let screenHeight: CGFloat = 38.1
    /// The real device tucks the screen tight to the top: 4.2 mm of white above
    /// the plastic window, less than the corner radius. At 9.0 that band was
    /// more than double, which is most of why the black frame read as a heavy
    /// bezel rather than a window cut into the plastic.
    static let screenTop: CGFloat = 5.2
    /// The lit rectangle has square corners: rounding the pixels clips the
    /// light and thickens the apparent black at each corner.
    static let screenCornerRadius: CGFloat = 0

    /// The LCD's native pixel grid. Screen content is laid out in these units
    /// and scaled up, so text lands on the same proportions the real device
    /// used regardless of window size.
    static let screenPixelsWide: CGFloat = 320
    static let screenPixelsHigh: CGFloat = 240

    // MARK: - Click wheel

    /// Measured off two independently rectified photographs, which agree on
    /// the diameter to 0.1 mm. The defining gesture of the 5G front face is a
    /// *small* wheel floating in a generous field of white: at 43 mm it nearly
    /// touched the bottom edge and the object read as a generic MP3 player.
    /// Wheel-to-body-width is 0.618, not 0.696.
    static let wheelDiameter: CGFloat = 38.2
    static let buttonDiameter: CGFloat = 13.6

    /// Centre of the wheel from the top of the body.
    ///
    /// An explicit measurement rather than a sum chained off `screenTop`, so
    /// changing the screen position can't silently drag the wheel with it. The
    /// stack it belongs to: 4.2 white + 40.1 window + 9.4 white + 38.2 wheel +
    /// 11.6 white = 103.5.
    static let wheelCentreY: CGFloat = 72.8

    /// Radius of the printed label ring (MENU, ⏭, ⏯, ⏮), 0.83 × wheel radius.
    /// Previously derived as `(wheelRadius + buttonRadius) / 2`, which was a
    /// guess and lands 3 mm too far in.
    static let labelRadius: CGFloat = 15.9

    // MARK: - Derived layout

    static var screenLeft: CGFloat { (bodyWidth - screenWidth) / 2 }
    static var wheelCentreX: CGFloat { bodyWidth / 2 }

    /// Scale factor mapping millimetres to points for a given rendered height.
    static func scale(forHeight height: CGFloat) -> CGFloat {
        height / bodyHeight
    }

    /// Points per millimetre on the display the window currently sits on.
    ///
    /// `CGDisplayScreenSize` reports the panel's true physical size, which is
    /// what makes life-size mode actually life-sized rather than a guess based
    /// on a nominal DPI.
    @MainActor
    static func pointsPerMillimetre(on screen: NSScreen?) -> CGFloat {
        guard
            let screen,
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else { return fallbackPointsPerMillimetre }

        let physical = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
        guard physical.width > 1 else { return fallbackPointsPerMillimetre }
        return screen.frame.width / physical.width
    }

    /// Roughly a 110 ppi panel — only used when a display refuses to report a
    /// physical size, which mostly means a virtual or mirrored one.
    private static let fallbackPointsPerMillimetre: CGFloat = 4.33
}
