import AppKit
import SwiftUI

/// Root view: the device, plus the keyboard controls and window plumbing.
struct RootView: View {
    @Environment(DeviceState.self) private var device
    @Environment(Navigator.self) private var navigator
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    @State private var sheen: CGFloat = 0.35
    /// Key-light position, -1...1. Shares the window-position signal with
    /// `sheen` so the plastic and the glass agree about where the room is.
    @State private var light: CGPoint = .zero
    @State private var height: CGFloat = 560
    /// Keyboard input comes through a local event monitor, not `onKeyPress`:
    /// the `.plain` window is borderless and `canBecomeKey` is false, so no
    /// view in it can ever hold keyboard focus.
    @State private var keys = KeyMonitor()

    /// Where the window sits on screen, 0...1, the base the cursor offsets.
    @State private var roomAnchor = CGPoint(x: 0.5, y: 0.5)
    @State private var hostWindow: NSWindow?
    @State private var cursorTask: Task<Void, Never>?

    var body: some View {
        IPodBody(height: height, sheen: sheen, light: light)
            .padding(Self.shadowPadding)
            .background(WindowAccessor { window in
                configure(window)
            })
            .task { await start() }
            .onAppear {
                keys.start { handleKey($0) }
                startCursorTracking()
            }
            .onDisappear {
                keys.stop()
                cursorTask?.cancel()
                cursorTask = nil
            }
    }

    /// Room around the body for the drop shadow to render into; the window
    /// itself is transparent, so this is invisible except as the shadow.
    private static let shadowPadding: CGFloat = 26

    // MARK: - Startup

    private func start() async {
        await library.start()
        await player.syncVolume()

        if let failure = library.loadFailure {
            navigator.showMessage(
                title: failure.errorDescription ?? "Error",
                detail: failure.recoveryHint
            )
            return
        }

        // Hold the boot screen briefly, the way the real device took a moment
        // to spin up, then land on the favourites playlist.
        try? await Task.sleep(for: .milliseconds(1400))
        navigator.finishBoot()

        if let favourites = library.favourites {
            _ = await library.songs(in: favourites)
        }
    }

    // MARK: - Keyboard

    /// Full keyboard control, which is also what makes the device usable
    /// without a pointing device. Returns true when the key was consumed.
    private func handleKey(_ token: String) -> Bool {
        // H has to survive Hold, or switching Hold on from Settings would
        // strand the user: the wheel is dead, so the menu that turned it on is
        // no longer reachable to turn it off.
        let unlocks = token == "escape" || token == "h"
        guard !device.isHeld || unlocks else { return false }

        switch token {
        case "up":
            navigator.scroll(by: -1)
        case "down":
            navigator.scroll(by: 1)
        case "return", "space", "right":
            navigator.pressSelect()
        case "left", "escape":
            navigator.pressMenu()
        case "p":
            navigator.pressPlayPause()
        case "n":
            navigator.pressNext()
        case "b":
            navigator.pressPrevious()
        case "h":
            device.isHeld.toggle()
        default:
            return false
        }
        return true
    }

    // MARK: - Window

    private func configure(_ window: NSWindow) {
        // Fully borderless. A transparent titlebar still reserves its band
        // above the content and paints a hairline across it — visible on the
        // desktop above the device, and no combination of `titleVisibility`,
        // `titlebarAppearsTransparent` and `titlebarSeparatorStyle` removes it.
        //
        // Rather than going `.borderless` — which makes `canBecomeKey` false
        // and would need the window's class swapped out from under SwiftUI to
        // restore it — the window stays titled and the titlebar view itself is
        // removed. `.fullSizeContentView` then lets the content occupy the
        // whole frame, so nothing is left to draw a hairline above the device.
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        // The container is what actually paints the band and its hairline;
        // the properties above only make its *contents* invisible. AppKit adds
        // it to the frame *after* the first configure pass and macOS 26 nests
        // a _NSTitlebarDecorationView inside that draws its own hairline, so
        // the sweep is recursive and re-runs on didBecomeKey (see Coordinator)
        // — hiding only on launch left the line on screen until the window
        // happened to be dragged.
        if let frame = window.contentView?.superview {
            hideTitlebarChrome(in: frame)
        }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false          // the SwiftUI shadow is the real one
        window.level = device.floatsAboveOtherWindows ? .floating : .normal

        // A borderless window is not key by default even once it is on screen.
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }

        updateSize(for: window)
        updateSheen(for: window)
    }

    private func hideTitlebarChrome(in view: NSView) {
        for subview in view.subviews {
            if String(describing: type(of: subview)).contains("Titlebar") {
                subview.isHidden = true
            } else {
                hideTitlebarChrome(in: subview)
            }
        }
    }

    private func updateSize(for window: NSWindow) {
        let target: CGFloat
        if device.isActualSize {
            let perMM = Metrics.pointsPerMillimetre(on: window.screen ?? NSScreen.main)
            target = Metrics.bodyHeight * perMM
        } else {
            target = 560
        }
        guard abs(target - height) > 0.5 else { return }
        height = target
    }

    /// Maps the window's position on screen to where the reflection falls.
    private func updateSheen(for window: NSWindow) {
        hostWindow = window
        guard let screen = window.screen ?? NSScreen.main else { return }
        let x = (window.frame.midX - screen.frame.minX) / max(1, screen.frame.width)
        let y = (window.frame.midY - screen.frame.minY) / max(1, screen.frame.height)
        roomAnchor = CGPoint(x: x, y: y)
        (sheen, light) = Self.room(atX: x, y: y)
    }

    /// One mapping from a screen-space position to the lighting uniforms, so
    /// the window signal and the cursor signal cannot drift apart. The same
    /// value drives the glass sheen and the plastic's key light: body and
    /// glass move together rather than a reflection sliding over a static
    /// object.
    private static func room(atX x: CGFloat, y: CGFloat) -> (CGFloat, CGPoint) {
        let sheen = 0.12 + (x * 0.55) + (1 - y) * 0.35
        let light = CGPoint(x: (x - 0.5) * 0.9, y: (y - 0.5) * 0.6)
        return (sheen, light)
    }

    // MARK: - Cursor parallax

    /// The cursor nudges the lighting around the window's own anchor, so the
    /// reflections shift as the pointer passes — the object answers the room
    /// instead of holding a pose. Polled: `NSEvent.mouseLocation` needs no
    /// event monitor and no permission, and the writes stop once converged.
    private func startCursorTracking() {
        guard cursorTask == nil else { return }
        cursorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                trackCursor()
            }
        }
    }

    private func trackCursor() {
        guard let window = hostWindow, let screen = window.screen ?? NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        let dx = (mouse.x - window.frame.midX) / max(1, screen.frame.width)
        let dy = (mouse.y - window.frame.midY) / max(1, screen.frame.height)
        let (targetSheen, targetLight) = Self.room(
            atX: roomAnchor.x + dx * 1.1,
            y: roomAnchor.y + dy * 1.1
        )

        let stepSheen = (targetSheen - sheen) * 0.22
        let stepX = (targetLight.x - light.x) * 0.22
        let stepY = (targetLight.y - light.y) * 0.22
        // Converged: stop touching @State so an idle app stops re-rendering.
        guard abs(stepSheen) + abs(stepX) + abs(stepY) > 0.0006 else { return }
        sheen += stepSheen
        light.x += stepX
        light.y += stepY
    }
}

/// Keyboard input for a window that can never be key.
///
/// SwiftUI's `.plain` window is borderless, and its `canBecomeKey` is false,
/// so `onKeyPress` never fires — but key events still reach the application
/// while it is active, where a local monitor can take them. Consuming handled
/// keys also keeps the system from beeping at every press.
@MainActor
final class KeyMonitor {
    private var monitor: Any?

    /// `onKey` gets a normalised token ("up", "return", "p", …) and returns
    /// whether it consumed the key.
    func start(onKey: @escaping (String) -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let token: String
            switch event.keyCode {
            case 126: token = "up"
            case 125: token = "down"
            case 123: token = "left"
            case 124: token = "right"
            case 36, 76: token = "return"
            case 53: token = "escape"
            case 49: token = "space"
            default: token = event.charactersIgnoringModifiers?.lowercased() ?? ""
            }
            let handled = MainActor.assumeIsolated { onKey(token) }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Bridges to the hosting `NSWindow`, and keeps the reflection in step as the
/// window is dragged around the desktop.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            onWindow(window)
            context.coordinator.observe(window, onChange: onWindow)
            // AppKit attaches the titlebar container after the window is
            // already key, so no notification announces it — without these
            // re-runs its chrome stays visible until the window is dragged.
            for delay in [0.2, 0.6, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    guard let window else { return }
                    onWindow(window)
                }
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        onWindow(window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var tokens: [NSObjectProtocol] = []

        func observe(_ window: NSWindow, onChange: @escaping (NSWindow) -> Void) {
            let centre = NotificationCenter.default
            // didBecomeKey matters: the titlebar container only exists by
            // then, so it is the earliest moment hiding it can stick.
            for name in [
                NSWindow.didMoveNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didBecomeKeyNotification,
            ] {
                tokens.append(
                    centre.addObserver(forName: name, object: window, queue: .main) { _ in
                        MainActor.assumeIsolated { onChange(window) }
                    }
                )
            }
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
