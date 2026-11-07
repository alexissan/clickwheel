import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct ClickwheelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.services.device)
                .environment(delegate.services.library)
                .environment(delegate.services.player)
                .environment(delegate.services.navigator)
                .environment(delegate.services.brick)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Owns the object graph.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct Services {
        let device: DeviceState
        let library: Library
        let player: Player
        let navigator: Navigator
        let brick: BrickGame
        let clicker: Clicker
    }

    /// Built during `init`, not in `applicationDidFinishLaunching`.
    ///
    /// SwiftUI evaluates the scene body before the delegate's launch callback
    /// runs, so anything created there is still nil when the first window is
    /// built — and `AppDelegate` isn't observable, so the window would never
    /// learn about it afterwards.
    let services: Services

    override init() {
        // Only one backend ships today. `MusicSource` exists so a MusicKit
        // implementation can be slotted in ahead of this one without the rest
        // of the app noticing — see the note in `MusicSource`.
        let source = MusicAppSource()

        let device = DeviceState()
        let library = Library(source: source)
        let player = Player(source: source)
        let clicker = Clicker()

        services = Services(
            device: device,
            library: library,
            player: player,
            navigator: Navigator(
                library: library,
                player: player,
                device: device,
                clicker: clicker
            ),
            brick: BrickGame(),
            clicker: clicker
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let path = Snapshot.requestedPath {
            Task { await Snapshot.run(path: path, services: services) }
        }
        Snapshot.captureWindowIfRequested()
        Snapshot.dumpWindowIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Hands the user's Music.app settings back before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        services.clicker.stop()
        // Terminate waits for this; it is a couple of Apple events at most.
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await services.player.relinquish()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.5)
    }
}
