import AppKit
import IOKit.ps
import Observation

/// The physical state of the device: the things that would be true of an iPod
/// sitting on a desk regardless of what is on its screen.
@MainActor
@Observable
final class DeviceState {
    private let defaults: UserDefaults

    // MARK: - Hold switch

    /// When held, the wheel and buttons are dead and the status bar shows a
    /// padlock — exactly like the real slider.
    var isHeld = false {
        didSet {
            guard isHeld != oldValue else { return }
            defaults.set(isHeld, forKey: Keys.hold)
            if isHeld { Haptics.press() }
            wake()
        }
    }

    // MARK: - Backlight

    private(set) var isBacklightOn = true
    /// Seconds of inactivity before the screen sleeps. Zero means never.
    ///
    /// Defaults to never. On the real device a timeout saved battery, but a
    /// window that goes dark while you're looking at it just reads as a broken
    /// app — so the behaviour is opt-in from Settings rather than the default.
    var backlightTimeout: TimeInterval = 0 {
        didSet {
            defaults.set(backlightTimeout, forKey: Keys.backlight)
            wake()
        }
    }

    private var sleepTask: Task<Void, Never>?

    // MARK: - Settings

    var style: DeviceStyle = .classic {
        didSet {
            guard style != oldValue, !Snapshot.isRendering else { return }
            defaults.set(style.rawValue, forKey: Keys.style)
        }
    }

    var isClickerOn = true {
        didSet { defaults.set(isClickerOn, forKey: Keys.clicker) }
    }

    var isHapticsOn = true {
        didSet { defaults.set(isHapticsOn, forKey: Keys.haptics) }
    }

    /// Renders the device at its true physical size using the display's
    /// reported dimensions.
    var isActualSize = false {
        didSet { defaults.set(isActualSize, forKey: Keys.actualSize) }
    }

    var floatsAboveOtherWindows = false {
        didSet { defaults.set(floatsAboveOtherWindows, forKey: Keys.floats) }
    }

    // MARK: - Battery

    /// Charge fraction 0...1, mirrored from the Mac's own battery so the
    /// status bar meter means something.
    private(set) var batteryLevel: Double = 1.0
    private(set) var isCharging = false

    private var batteryTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = DeviceStyle(rawValue: defaults.string(forKey: Keys.style) ?? "") ?? .classic
        isHeld = defaults.bool(forKey: Keys.hold)
        isClickerOn = defaults.object(forKey: Keys.clicker) as? Bool ?? true
        isHapticsOn = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        isActualSize = defaults.bool(forKey: Keys.actualSize)
        floatsAboveOtherWindows = defaults.bool(forKey: Keys.floats)
        backlightTimeout = defaults.object(forKey: Keys.backlight) as? TimeInterval ?? 0

        refreshBattery()
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                // Cancelling makes the sleep throw immediately and `try?`
                // swallows it — without this guard the loop runs one last
                // refresh *after* cancellation, undoing whatever the caller
                // cancelled the task to set.
                guard !Task.isCancelled else { return }
                self?.refreshBattery()
            }
        }
        wake()
    }

    // Both long-lived tasks capture `self` weakly and exit on their own once
    // it goes away, so there is nothing to tear down in `deinit` — which is
    // just as well, since it can't touch main-actor state.

    // MARK: - Backlight control

    /// Dims the panel for a snapshot without touching the stored timeout.
    ///
    /// Going through `backlightTimeout` would persist the preview value to
    /// UserDefaults and leave the real app sleeping its backlight instantly.
    func dimForPreview() {
        sleepTask?.cancel()
        isBacklightOn = false
    }

    /// Pins the meter for snapshots and demo renders, so the captured device
    /// doesn't inherit whatever charge the Mac happens to have.
    func stageBatteryForPreview(_ level: Double) {
        batteryTask?.cancel()
        batteryTask = nil
        batteryLevel = min(1, max(0, level))
        isCharging = false
    }

    /// Called on every interaction. Lights the screen and restarts the timer.
    func wake() {
        isBacklightOn = true
        sleepTask?.cancel()
        guard backlightTimeout > 0 else { return }
        sleepTask = Task { [weak self, timeout = backlightTimeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.isBacklightOn = false
        }
    }

    // MARK: - Battery

    private func refreshBattery() {
        guard
            let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard
                let info = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                let current = info[kIOPSCurrentCapacityKey] as? Int,
                let maximum = info[kIOPSMaxCapacityKey] as? Int,
                maximum > 0
            else { continue }

            batteryLevel = min(1, max(0, Double(current) / Double(maximum)))
            isCharging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return
        }

        // Desktop Macs report no battery at all; a full meter is the least
        // misleading thing to show.
        batteryLevel = 1
        isCharging = true
    }

    private enum Keys {
        static let style = "device.style"
        static let hold = "device.hold"
        static let clicker = "device.clicker"
        static let haptics = "device.haptics"
        static let backlight = "device.backlightTimeout"
        static let actualSize = "device.actualSize"
        static let floats = "device.floatsAboveOtherWindows"
    }
}
