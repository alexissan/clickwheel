import SwiftUI

/// The whole device: shell, screen, hold switch and click wheel, laid out from
/// the real millimetre dimensions in `Metrics`.
struct IPodBody: View {
    @Environment(Navigator.self) private var navigator
    @Environment(DeviceState.self) private var device
    @Environment(BrickGame.self) private var brick

    /// Rendered height of the device in points; everything else derives from it.
    let height: CGFloat
    /// 0...1, where the specular band sits on the screen glass. Driven by the
    /// window's position so reflections shift as the iPod is moved around.
    let sheen: CGFloat
    /// -1...1 position of the key light, from the same window-position signal
    /// as `sheen`. Without this the glass reflection moved while the plastic
    /// stayed nailed in place, which read as video composited onto a still.
    let light: CGPoint

    @State private var scrollReader = WheelScrollReader()

    private var scale: CGFloat { Metrics.scale(forHeight: height) }
    private var width: CGFloat { Metrics.bodyWidth * scale }

    var body: some View {
        ZStack(alignment: .topLeading) {
            shell
            screen
            wheel
        }
        .frame(width: width, height: height)
        .modifier(ContactShadow(scale: scale))
    }

    // MARK: - Shell

    private var shell: some View {
        Rectangle()
            .fill(.white)
            .frame(width: width, height: height)
            .glossyShellMaterial(
                size: CGSize(width: width, height: height),
                radius: Metrics.cornerRadius * scale,
                // Points per millimetre, so the shader can lay out the chrome
                // hairline, parting seam and plastic roll at their real sizes.
                bevel: scale,
                light: light,
                wheelCentre: CGPoint(
                    x: Metrics.wheelCentreX * scale - width / 2,
                    y: Metrics.wheelCentreY * scale - height / 2
                ),
                wheelRadius: Metrics.wheelDiameter * scale / 2,
                style: device.style
            )
    }

    // MARK: - Screen

    private var screen: some View {
        let screenWidth = Metrics.screenWidth * scale
        let screenHeight = Metrics.screenHeight * scale
        let unit = screenWidth / Metrics.screenPixelsWide
        let bezelInset = 1.4 * scale

        return ZStack {
            // A soft occlusion halo where the window cuts into the plastic —
            // the plastic shades gently into the opening instead of meeting
            // the black frame at a hard boundary.
            RoundedRectangle(cornerRadius: (Metrics.screenCornerRadius + 1.0) * scale, style: .continuous)
                .fill(.black)
                .frame(width: screenWidth + bezelInset * 2 + 1.2 * scale,
                       height: screenHeight + bezelInset * 2 + 1.2 * scale)
                .blur(radius: 1.1 * scale)
                .opacity(0.18)

            // The LCD's own black frame, visible as a thin border on the real
            // device between the white plastic and the active area.
            RoundedRectangle(cornerRadius: (Metrics.screenCornerRadius + 0.6) * scale, style: .continuous)
                .fill(Palette.bezel)
                .frame(width: screenWidth + bezelInset * 2, height: screenHeight + bezelInset * 2)

            ScreenView(unit: unit)
                .frame(width: screenWidth, height: screenHeight)
                .clipShape(
                    RoundedRectangle(cornerRadius: Metrics.screenCornerRadius * scale, style: .continuous)
                )
                // Rasterise the whole panel before the shader. Without this,
                // text runs are composited separately from the layer the
                // shader filters, and every one of them keeps its own
                // unfiltered white box — invisible while the shader only
                // brightened, glaring once it darkens white by any amount.
                .drawingGroup()
                .screenGlassMaterial(
                    size: CGSize(width: screenWidth, height: screenHeight),
                    sheen: sheen,
                    unit: unit
                )

            // The acrylic window's edge. Its lower lip catches the room and
            // its upper one sits in shadow — the cue that there is a
            // transparent material with thickness here, not a black border
            // printed on the face.
            RoundedRectangle(cornerRadius: (Metrics.screenCornerRadius + 0.6) * scale, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.32), location: 0.00),
                            .init(color: .clear, location: 0.22),
                            .init(color: .clear, location: 0.78),
                            .init(color: .white.opacity(0.38), location: 1.00),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.4 * scale
                )
                .frame(
                    width: screenWidth + bezelInset * 2,
                    height: screenHeight + bezelInset * 2
                )
                .allowsHitTesting(false)
        }
        .frame(width: screenWidth + bezelInset * 2, height: screenHeight + bezelInset * 2)
        .offset(
            x: Metrics.screenLeft * scale - bezelInset,
            y: Metrics.screenTop * scale - bezelInset
        )
    }

    // MARK: - Click wheel

    private var wheel: some View {
        let diameter = Metrics.wheelDiameter * scale
        let button = Metrics.buttonDiameter * scale

        return ClickWheelView(
            diameter: diameter,
            buttonDiameter: button,
            isEnabled: !device.isHeld,
            light: light,
            onScroll: handleScroll,
            onPress: handlePress,
            onSelect: handleSelect,
            onIdle: { navigator.wheelIdled() }
        )
        .frame(width: diameter, height: diameter)
        .onAppear {
            scrollReader.start(
                onScroll: { handleScroll($0) },
                onIdle: { navigator.wheelIdled() }
            )
        }
        .onDisappear { scrollReader.stop() }
        .offset(
            x: Metrics.wheelCentreX * scale - diameter / 2,
            y: Metrics.wheelCentreY * scale - diameter / 2
        )
    }

    // The Hold switch is deliberately not drawn. On the real A1136 it lives on
    // the top edge — which is polished stainless, not white plastic, and is not
    // visible face-on. Both rectified reference photographs show a front face
    // that is completely clean apart from the screen window and the wheel, so
    // a capsule up in the corner was the loudest "not an iPod" tell on it.
    // Hold is still fully available: Settings › Hold, or the H key.

    // MARK: - Input routing

    private func handleScroll(_ steps: Int) {
        guard !device.isHeld else { return }
        if case .brick = navigator.screen {
            brick.movePaddle(by: steps)
            device.wake()
            return
        }
        navigator.scroll(by: steps)
    }

    private func handlePress(_ region: ClickWheelView.Region) {
        guard !device.isHeld else { return }
        switch region {
        case .menu:
            if case .brick = navigator.screen { brick.stop() }
            navigator.pressMenu()
        case .next: navigator.pressNext()
        case .previous: navigator.pressPrevious()
        case .playPause: navigator.pressPlayPause()
        }
    }

    private func handleSelect() {
        guard !device.isHeld else { return }
        if case .brick = navigator.screen {
            if brick.isOver { brick.reset() }
            brick.start()
            device.wake()
            return
        }
        navigator.pressSelect()
    }
}

/// The shadow the device casts on the desktop.
///
/// Drawn as an explicit blurred shape *behind* the body rather than with
/// `.shadow` on the body itself. `.shadow` on a view carrying a `colorEffect`
/// composites over the filtered layer instead of behind it, which tinted the
/// whole shell — a uniform ×0.53 with a dark radial core exactly matching the
/// blur profile. Radii are in millimetres, scaled like every other dimension.
struct ContactShadow: ViewModifier {
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius * scale, style: .continuous)
                .fill(.black)
                .blur(radius: 2.2 * scale)
                .opacity(0.30)
                .offset(y: 1.6 * scale)
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.cornerRadius * scale, style: .continuous)
                        .fill(.black)
                        .blur(radius: 0.5 * scale)
                        .opacity(0.22)
                        .offset(y: 0.4 * scale)
                }
        }
    }
}
