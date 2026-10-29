import AppKit
import SwiftUI

enum BrandColorResolver {
    static func color(for brand: ServiceBrand, preference: BrandColorPreference) -> Color {
        if preference.mode == .custom,
           let hex = preference.customHex,
           let custom = color(fromHex: hex) {
            return custom
        }
        return adaptiveColor(lightHex: brand.defaultLightHex, darkHex: brand.defaultDarkHex)
    }

    @MainActor
    static func color(for brand: ServiceBrand, settings: SettingsStore) -> Color {
        let preference = BrandColorPreference(
            mode: settings.colorMode(for: brand),
            customHex: settings.customColorHex(for: brand)
        )
        return color(for: brand, preference: preference)
    }

    static func color(fromHex hex: String?) -> Color? {
        guard let hex else { return nil }
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, value.allSatisfy(\.isHexDigit) else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: value).scanHexInt64(&rgb) else { return nil }
        if value.count == 8 {
            return Color(
                red: Double((rgb >> 24) & 0xFF) / 255,
                green: Double((rgb >> 16) & 0xFF) / 255,
                blue: Double((rgb >> 8) & 0xFF) / 255,
                opacity: Double(rgb & 0xFF) / 255
            )
        }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    static func hexString(for color: Color) -> String? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func adaptiveColor(lightHex: String, darkHex: String) -> Color {
        let light = nsColor(fromHex: lightHex) ?? .white
        let dark = nsColor(fromHex: darkHex) ?? .black
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }

    private static func nsColor(fromHex hex: String) -> NSColor? {
        guard let color = color(fromHex: hex) else { return nil }
        return NSColor(color).usingColorSpace(.sRGB)
    }
}
