import SwiftUI

enum DeviceStyle: String, CaseIterable, Identifiable {
    case classic, black, field, walnut, midnight, champagne

    var id: String { rawValue }

    var label: String {
        let fallback = switch self {
        case .classic: "Classic White"
        case .black: "Black"
        case .field: "Field"
        case .walnut: "Walnut"
        case .midnight: "Midnight"
        case .champagne: "Champagne"
        }
        return Bundle.module.localizedString(forKey: "style.\(rawValue)", value: fallback, table: nil)
    }

    var finish: Finish {
        switch self {
        case .classic:
            Finish(shell: 0xF0F1F3, wheel: 0xF2F2F3, button: 0xD2D3D7, ink: 0x909296, roughness: 0.085)
        case .black:
            Finish(shell: 0x151619, wheel: 0x222328, button: 0x37393F, ink: 0xC2C5CC, roughness: 0.10)
        case .field:
            Finish(shell: 0x626C48, wheel: 0x292E26, button: 0x92977D, ink: 0xD4D8C5, roughness: 0.58)
        case .walnut:
            Finish(shell: 0x704A36, wheel: 0xD9CFBA, button: 0xA88B68, ink: 0x665744, roughness: 0.32)
        case .midnight:
            Finish(shell: 0x263B58, wheel: 0x252E3C, button: 0x9BA6B5, ink: 0xCBD5E3, roughness: 0.22)
        case .champagne:
            Finish(shell: 0xC3AD85, wheel: 0xECE5D6, button: 0xB19A74, ink: 0x7A6B51, roughness: 0.38)
        }
    }

    struct Finish {
        let shell: RGB
        let wheel: RGB
        let button: RGB
        let ink: RGB
        let roughness: Float

        init(shell: UInt32, wheel: UInt32, button: UInt32, ink: UInt32, roughness: Float) {
            self.shell = RGB(shell)
            self.wheel = RGB(wheel)
            self.button = RGB(button)
            self.ink = RGB(ink)
            self.roughness = roughness
        }
    }

    struct RGB {
        let red: Float
        let green: Float
        let blue: Float

        init(_ hex: UInt32) {
            red = Float((hex >> 16) & 255) / 255
            green = Float((hex >> 8) & 255) / 255
            blue = Float(hex & 255) / 255
        }

        var color: Color {
            Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue), opacity: 1)
        }

        var argument: Shader.Argument { .float3(red, green, blue) }
    }
}
