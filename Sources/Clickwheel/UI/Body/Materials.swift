import SwiftUI

/// Access to the compiled Metal materials.
///
/// SwiftUI's `ShaderLibrary.default` reads the `default.metallib` that Xcode
/// builds. SwiftPM doesn't produce one, so the shaders are compiled by
/// `Scripts/build_app.sh` into a named library and loaded by URL instead.
enum Materials {
    static let library: ShaderLibrary? = {
        guard let url = Bundle.module.url(forResource: "Clickwheel", withExtension: "metallib")
        else { return nil }
        return ShaderLibrary(url: url)
    }()

    /// True when the shaders loaded. The body falls back to plain gradients if
    /// they didn't, so a missing metallib degrades rather than crashes.
    static var isAvailable: Bool { library != nil }
}

extension View {
    /// Glossy white polycarbonate, shaped to a rounded rectangle.
    ///
    /// `light` is the -1...1 position of the key light, driven by where the
    /// window sits on screen. `wheelCentre` and `wheelRadius` let the shell
    /// shade the moulded well the click wheel sits in.
    func glossyShellMaterial(
        size: CGSize,
        radius: CGFloat,
        bevel: CGFloat,
        light: CGPoint,
        wheelCentre: CGPoint,
        wheelRadius: CGFloat
    ) -> some View {
        modifier(
            ShellMaterial(
                size: size,
                radius: radius,
                bevel: bevel,
                light: light,
                wheelCentre: wheelCentre,
                wheelRadius: wheelRadius
            )
        )
    }

    /// Matte wheel plastic with a hole cut for the centre button.
    func clickWheelMaterial(size: CGSize, innerRatio: CGFloat, light: CGPoint) -> some View {
        modifier(WheelMaterial(size: size, innerRatio: innerRatio, light: light))
    }

    /// Crowned centre-button plastic.
    func centreButtonMaterial(size: CGSize, pressed: Bool, light: CGPoint) -> some View {
        modifier(ButtonMaterial(size: size, pressed: pressed, light: light))
    }

    /// The LCD panel response and pixel grid, plus the specular sheen over the
    /// glass, offset by where the window sits. `unit` is points per LCD pixel.
    func screenGlassMaterial(size: CGSize, sheen: CGFloat, unit: CGFloat) -> some View {
        modifier(GlassMaterial(size: size, sheen: sheen, unit: unit))
    }
}

// MARK: - Modifiers

private struct ShellMaterial: ViewModifier {
    let size: CGSize
    let radius: CGFloat
    let bevel: CGFloat
    let light: CGPoint
    let wheelCentre: CGPoint
    let wheelRadius: CGFloat

    /// `colorEffect` tells the shader nothing about scale, so the antialiasing
    /// width has to be handed in — otherwise the silhouette is a pixel wide at
    /// 1x and visibly soft at 2x.
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        if let library = Materials.library {
            content.colorEffect(
                library.glossyShell(
                    .float2(size.width, size.height),
                    .float(radius),
                    .float(bevel),
                    .float2(light.x, light.y),
                    .float2(wheelCentre.x, wheelCentre.y),
                    .float(wheelRadius),
                    .float(1 / max(displayScale, 1))
                )
            )
        } else {
            FallbackShell(radius: radius)
        }
    }
}

private struct WheelMaterial: ViewModifier {
    let size: CGSize
    let innerRatio: CGFloat
    let light: CGPoint

    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        if let library = Materials.library {
            content.colorEffect(
                library.clickWheel(
                    .float2(size.width, size.height),
                    .float(innerRatio),
                    .float2(light.x, light.y),
                    .float(1 / max(displayScale, 1))
                )
            )
        } else {
            Circle()
                .fill(Palette.wheelBase)
                .overlay(Circle().stroke(Palette.wheelRim, lineWidth: 0.5))
        }
    }
}

private struct ButtonMaterial: ViewModifier {
    let size: CGSize
    let pressed: Bool
    let light: CGPoint

    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        if let library = Materials.library {
            content.colorEffect(
                library.centreButton(
                    .float2(size.width, size.height),
                    .float(pressed ? 1 : 0),
                    .float2(light.x, light.y),
                    .float(1 / max(displayScale, 1))
                )
            )
        } else {
            Circle().fill(pressed ? Palette.wheelRim : Palette.centreButton)
        }
    }
}

private struct GlassMaterial: ViewModifier {
    let size: CGSize
    let sheen: CGFloat
    let unit: CGFloat

    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        if let library = Materials.library {
            content.colorEffect(
                library.screenGlass(
                    .float2(size.width, size.height),
                    .float(sheen),
                    .float(unit),
                    .float(1 / max(displayScale, 1))
                )
            )
        } else {
            content
        }
    }
}

/// Gradient stand-in used only if the Metal library failed to load.
private struct FallbackShell: View {
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Palette.shellHighlight, Palette.shellBase, Palette.shellShadow],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}
