import Foundation
import Testing
@testable import Clickwheel

@MainActor
struct DeviceStyleTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "ClickwheelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func styleSurvivesRestart() {
        withDefaults { defaults in
            for style in DeviceStyle.allCases {
                let device = DeviceState(defaults: defaults)
                device.style = style
                #expect(DeviceState(defaults: defaults).style == style)
            }
        }
    }

    @Test func unknownStoredStyleFallsBackToClassic() {
        withDefaults { defaults in
            defaults.set("retired-finish", forKey: "device.style")
            #expect(DeviceState(defaults: defaults).style == .classic)
        }
    }

    @Test func wheelSelectsStylesAndRemembersPosition() {
        withDefaults { defaults in
            let device = DeviceState(defaults: defaults)
            device.isClickerOn = false
            device.isHapticsOn = false
            let source = MusicAppSource()
            let navigator = Navigator(library: Library(source: source), player: Player(source: source),
                                      device: device, clicker: Clicker())
            navigator.finishBoot()
            navigator.scroll(by: 2)
            navigator.pressSelect()
            #expect(navigator.screen == .menu(.settings))
            navigator.pressSelect()
            #expect(navigator.screen == .menu(.styles))

            for (index, style) in DeviceStyle.allCases.enumerated() {
                navigator.scroll(by: index - navigator.current.selection)
                navigator.pressSelect()
                #expect(device.style == style)
                #expect(navigator.currentRows.filter { $0.detail == "✓" }.map(\.id) == [style.id])
                navigator.pressMenu()
                #expect(navigator.currentRows.first?.detail == style.label)
                navigator.pressSelect()
                #expect(navigator.current.selection == index)
            }

            navigator.pressMenu()
            navigator.scroll(by: 100)
            #expect(navigator.currentRows[navigator.current.selection].id == "about")
            #expect(navigator.current.window == 1)
            navigator.pressSelect()
            #expect(navigator.screen == .about)
            navigator.pressMenu()
            navigator.pressMenu()
            #expect(navigator.screen == .menu(.main))
        }
    }
}
