import SwiftUI

/// The click wheel: circular drag, scroll wheel, and the five buttons.
struct ClickWheelView: View {
    @Environment(DeviceState.self) private var device

    /// Where on the ring a press landed.
    enum Region {
        case menu, next, playPause, previous
    }

    let diameter: CGFloat
    let buttonDiameter: CGFloat
    let isEnabled: Bool
    /// -1...1 key-light position, shared with the shell so the whole device
    /// agrees about where the room is.
    let light: CGPoint

    /// Where the wheel's hole ends, as a fraction of its radius.
    ///
    /// Half a millimetre wider than the button so there is a visible moulding
    /// groove between them. Matching the button exactly made the two shapes
    /// butt together with no gap, which is what a sticker looks like.
    private var innerRatio: CGFloat {
        (buttonDiameter + 0.5 * (diameter / Metrics.wheelDiameter)) / diameter
    }

    /// Emitted for each detent the wheel passes; positive is clockwise.
    let onScroll: (Int) -> Void
    let onPress: (Region) -> Void
    let onSelect: () -> Void
    /// Fired once the wheel has been still for a moment, ending a scrub.
    let onIdle: () -> Void

    @State private var accumulatedAngle: Double = 0
    @State private var lastAngle: Double?
    @State private var dragDistance: Double = 0
    @State private var dragStart: CGPoint?
    @State private var isCentrePressed = false
    @State private var idleTask: Task<Void, Never>?

    /// Degrees of rotation per detent. The real wheel had 96 positions per
    /// revolution; this is a little coarser so a mouse drag stays controllable.
    private static let degreesPerDetent: Double = 9

    var body: some View {
        ZStack {
            wheel
            labels
            centreButton
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(localized: "a11y.wheel", defaultValue: "Click wheel", bundle: .module)
        )
    }

    // MARK: - Wheel surface

    private var wheel: some View {
        Circle()
            .fill(.white)
            .clickWheelMaterial(
                size: CGSize(width: diameter, height: diameter),
                innerRatio: innerRatio,
                light: light,
                style: device.style
            )
            .contentShape(
                // Only the ring should take drags; the hole belongs to Select.
                Circle().subtracting(Circle().inset(by: (diameter - buttonDiameter) / 2))
            )
            .gesture(ringGesture)
            .allowsHitTesting(isEnabled)
    }

    private var ringGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let centre = CGPoint(x: diameter / 2, y: diameter / 2)
                if dragStart == nil {
                    dragStart = value.startLocation
                    lastAngle = angle(of: value.startLocation, from: centre)
                    dragDistance = 0
                }
                let current = angle(of: value.location, from: centre)
                guard let previous = lastAngle else { return }

                // Shortest signed path, so crossing 0°/360° doesn't spin the
                // list all the way round the other way.
                var delta = current - previous
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }

                lastAngle = current
                accumulatedAngle += delta
                dragDistance += abs(delta)

                let steps = Int(accumulatedAngle / Self.degreesPerDetent)
                if steps != 0 {
                    accumulatedAngle -= Double(steps) * Self.degreesPerDetent
                    onScroll(steps)
                    scheduleIdle()
                }
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    lastAngle = nil
                    accumulatedAngle = 0
                    dragDistance = 0
                }
                // A drag that barely moved is a press, not a scroll.
                guard dragDistance < 6 else { return }
                let centre = CGPoint(x: diameter / 2, y: diameter / 2)
                onPress(region(at: angle(of: value.startLocation, from: centre)))
            }
    }

    /// Angle in degrees, 0 at the top, increasing clockwise.
    private func angle(of point: CGPoint, from centre: CGPoint) -> Double {
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        let radians = atan2(dx, -dy)
        let degrees = radians * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    private func region(at angle: Double) -> Region {
        switch angle {
        case 315...360, 0..<45: .menu
        case 45..<135: .next
        case 135..<225: .playPause
        default: .previous
        }
    }

    /// A scrub should end when the user stops turning, not when they lift the
    /// mouse — the wheel has no "release" on the real device either.
    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            onIdle()
        }
    }

    // MARK: - Labels

    private var labels: some View {
        // Explicit measured radius rather than a midpoint between the wheel
        // and button radii, which lands about 3 mm too far in.
        let radius = diameter * (Metrics.labelRadius / Metrics.wheelDiameter)
        // MENU's cap height is 0.044 of the wheel diameter, and it is a light
        // grotesque — not semibold.
        let menuCap = diameter * 0.044
        let glyph = diameter * 0.048

        return ZStack {
            // Medium weight and near-default tracking, matching the printed
            // MENU on the Classic's wheel.
            Text(verbatim: "MENU")
                .font(.system(size: menuCap / 0.72, weight: .medium))
                .tracking(menuCap * 0.04)
                .offset(y: -radius)
            // Double-triangle-and-bar marks — `forward.end.fill` has a single
            // triangle, which is not what is printed on the wheel.
            Image(systemName: "forward.end.alt.fill")
                .font(.system(size: glyph))
                .offset(x: radius)
            Image(systemName: "playpause.fill")
                .font(.system(size: glyph))
                .scaleEffect(x: 1.08, y: 0.92)
                .offset(y: radius)
            Image(systemName: "backward.end.alt.fill")
                .font(.system(size: glyph))
                .offset(x: -radius)
        }
        .foregroundStyle(device.style.finish.ink.color)
        .allowsHitTesting(false)
    }

    // MARK: - Centre button

    private var centreButton: some View {
        Circle()
            .fill(.white)
            .centreButtonMaterial(
                size: CGSize(width: buttonDiameter, height: buttonDiameter),
                pressed: isCentrePressed,
                light: light,
                style: device.style
            )
            .frame(width: buttonDiameter, height: buttonDiameter)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isCentrePressed = true }
                    .onEnded { value in
                        isCentrePressed = false
                        // Ignore a release that wandered off the button.
                        let centre = CGPoint(x: buttonDiameter / 2, y: buttonDiameter / 2)
                        let dx = value.location.x - centre.x
                        let dy = value.location.y - centre.y
                        guard sqrt(dx * dx + dy * dy) <= buttonDiameter / 2 else { return }
                        onSelect()
                    }
            )
            .allowsHitTesting(isEnabled)
            .accessibilityLabel(
                String(localized: "a11y.select", defaultValue: "Select", bundle: .module)
            )
            .accessibilityAddTraits(.isButton)
    }
}

/// Routes trackpad and mouse-wheel scrolling to the click wheel.
///
/// This deliberately does **not** use an `NSViewRepresentable`. A representable's
/// `NSView` becomes a real subview of SwiftUI's hosting view, which puts it above
/// all SwiftUI-drawn content in AppKit hit testing no matter where it sits in a
/// `ZStack` — so a transparent catcher over the wheel swallows every `mouseDown`
/// and the drag gesture and centre button never see a thing. A local event
/// monitor observes scroll events without taking part in hit testing at all.
@MainActor
final class WheelScrollReader {
    private var monitor: Any?
    private var idleTimer: Timer?

    /// Fractional scroll accumulates until it crosses a detent, so a slow
    /// trackpad drag advances one row at a time instead of jumping.
    private var accumulated: CGFloat = 0

    /// Points of scroll per detent.
    private static let pointsPerDetent: CGFloat = 6

    func start(onScroll: @escaping (Int) -> Void, onIdle: @escaping @MainActor @Sendable () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Read the scalars out here: `NSEvent` isn't `Sendable`, so it must
            // not cross into the isolated closure below.
            //
            // Trackpads report precise deltas in points; a notched mouse wheel
            // reports whole lines, which need scaling to feel comparable.
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 6

            guard let self else { return event }
            let consumed = MainActor.assumeIsolated {
                self.handle(delta: delta, onScroll: onScroll, onIdle: onIdle)
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        idleTimer?.invalidate()
    }

    /// Returns true when the scroll was consumed by the wheel.
    private func handle(
        delta: CGFloat,
        onScroll: (Int) -> Void,
        onIdle: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        accumulated += delta
        let steps = Int(accumulated / Self.pointsPerDetent)
        if steps != 0 {
            accumulated -= CGFloat(steps) * Self.pointsPerDetent
            // Scrolling down should move down the list.
            onScroll(-steps)
            scheduleIdle(onIdle)
        }
        return true
    }

    private func scheduleIdle(_ onIdle: @escaping @MainActor @Sendable () -> Void) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
            Task { @MainActor in onIdle() }
        }
    }
}
