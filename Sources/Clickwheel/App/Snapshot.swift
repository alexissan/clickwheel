import AppKit
import SwiftUI

/// Renders the device to a PNG and exits.
///
/// Exists so the body can be inspected while iterating on the materials
/// without needing screen-recording permission to photograph the window —
/// and because it captures exactly the pixels the app draws, at any scale.
///
///     CLICKWHEEL_SNAPSHOT=/tmp/ipod.png open -W build/Clickwheel.app
///
/// `CLICKWHEEL_SNAPSHOT_SCREEN` picks which screen to show: `menu` (default),
/// `nowplaying`, `settings`, `boot`, `clock`, `about`, or `brick`.
@MainActor
enum Snapshot {
    static var requestedPath: String? {
        ProcessInfo.processInfo.environment["CLICKWHEEL_SNAPSHOT"]
    }

    /// True while rendering a snapshot.
    ///
    /// `ImageRenderer` can't draw `NSViewRepresentable`, so the scroll catcher
    /// is left out — otherwise it shows up as a placeholder rectangle over the
    /// click wheel and makes the render impossible to judge.
    static var isRendering: Bool { requestedPath != nil }

    /// Captures the real window rather than rendering offscreen.
    ///
    /// `ImageRenderer` and a live window do not necessarily take the same path
    /// through SwiftUI's compositor, so an offscreen snapshot can look correct
    /// while the window on screen does not. This is the only way to see what
    /// is actually being drawn without screen-recording permission.
    static func captureWindowIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CLICKWHEEL_CAPTURE_WINDOW"]
        else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else {
                FileHandle.standardError.write(Data("capture: no window\n".utf8))
                exit(1)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                print("capture: wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
            }
            exit(0)
        }
    }

    static func run(path: String, services: AppDelegate.Services) async {
        // Same startup path the app uses, so a snapshot proves the real one.
        await services.library.start()
        if let failure = services.library.loadFailure {
            FileHandle.standardError.write(
                Data("snapshot: library failed — \(failure.errorDescription ?? "?")\n".utf8)
            )
        }
        if let favourites = services.library.favourites {
            _ = await services.library.songs(in: favourites)
        }

        await configure(services)

        // Lets a snapshot reproduce the dimmed-panel state, which is otherwise
        // only reachable by waiting out the backlight timer.
        if ProcessInfo.processInfo.environment["CLICKWHEEL_SNAPSHOT_DIM"] != nil {
            services.device.dimForPreview()
        }

        let height: CGFloat = 900
        let view = IPodBody(height: height, sheen: 0.34, light: CGPoint(x: -0.12, y: -0.08))
            .environment(services.device)
            .environment(services.library)
            .environment(services.player)
            .environment(services.navigator)
            .environment(services.brick)
            .padding(40)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        // Pin the colour space: left to its own devices the renderer can hand
        // back an extended-linear image, which makes every sampled value
        // disagree with what the shader actually wrote.
        renderer.colorMode = ColorRenderingMode.nonLinear

        guard
            let image = renderer.cgImage,
            let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL,
                "public.png" as CFString,
                1,
                nil
            )
        else {
            FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
            exit(1)
        }

        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("snapshot: wrote \(path) (\(image.width)×\(image.height))")
        exit(0)
    }

    /// Puts the navigator on whichever screen was asked for.
    private static func configure(_ services: AppDelegate.Services) async {
        let which = ProcessInfo.processInfo.environment["CLICKWHEEL_SNAPSHOT_SCREEN"] ?? "menu"
        let navigator = services.navigator

        switch which {
        case "boot":
            return
        case "nowplaying":
            navigator.finishBoot()
            if let list = services.library.favourites,
               let songs = services.library.cachedSongs(in: list), !songs.isEmpty {
                services.player.stageForPreview(list: list, songs: songs, index: 2)
                await services.player.loadPreviewArtwork()
            }
            navigator.previewPush(.nowPlaying)
        case "settings":
            navigator.finishBoot()
            navigator.previewPush(.menu(.settings))
        case "playlists":
            navigator.finishBoot()
            navigator.previewPush(.menu(.playlists))
        case "tracks":
            navigator.finishBoot()
            if let list = services.library.favourites {
                navigator.previewPush(.menu(.tracks(listID: list.id)))
            }
        case "clock":
            navigator.finishBoot()
            navigator.previewPush(.clock)
        case "about":
            navigator.finishBoot()
            navigator.previewPush(.about)
        case "brick":
            navigator.finishBoot()
            navigator.previewPush(.brick)
        default:
            navigator.finishBoot()
        }

        // Drives real scroll steps through the same path the wheel uses, so a
        // snapshot can show whether navigation actually moves the selection.
        if let steps = ProcessInfo.processInfo.environment["CLICKWHEEL_SNAPSHOT_SCROLL"],
           let count = Int(steps) {
            for _ in 0..<abs(count) {
                navigator.scroll(by: count > 0 ? 1 : -1)
            }
            print("snapshot: scrolled \(count), selection now \(navigator.current.selection), "
                + "window \(navigator.current.window)")
        }
    }
}
