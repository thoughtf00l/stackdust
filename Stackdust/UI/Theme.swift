import SwiftUI
import AppKit

/// One palette color, stored as sRGB components so themes serialize to `UserDefaults`
/// and cross into the off-main-thread layout pass (`Sendable`, no AppKit inside).
struct ThemeColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 0xRRGGBB.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = Int(h) % 6
        let f = h - h.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch sector {
        case 0: self.init(red: brightness, green: t, blue: p)
        case 1: self.init(red: q, green: brightness, blue: p)
        case 2: self.init(red: p, green: brightness, blue: t)
        case 3: self.init(red: p, green: q, blue: brightness)
        case 4: self.init(red: t, green: p, blue: brightness)
        default: self.init(red: brightness, green: p, blue: q)
        }
    }

    /// Reads the picker's `Color` back into sRGB components. Main-thread only (AppKit).
    @MainActor
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// HSB components for the sunburst's per-depth saturation/brightness ramps. Pure math —
    /// callable from the detached layout pass.
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let mx = max(red, green, blue)
        let mn = min(red, green, blue)
        let delta = mx - mn
        guard delta > 0 else { return (0, 0, mx) }
        var hue: Double
        switch mx {
        case red: hue = (green - blue) / delta
        case green: hue = (blue - red) / delta + 2
        default: hue = (red - green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / mx, mx)
    }
}

/// A chart theme: branch colors for the sunburst and the contents panel, cycled across
/// depth-1 branches, plus the app accent color.
struct Theme: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var colors: [ThemeColor]
    var accent: ThemeColor
}

/// Selection, edits, and custom themes, persisted in `UserDefaults`. Built-in themes are
/// defined in code; editing one stores an override that `resetBuiltIn` discards.
@MainActor
@Observable
final class ThemeStore {

    /// Colors and accent of an edited built-in theme (its id and name stay fixed).
    private struct Override: Codable {
        var colors: [ThemeColor]
        var accent: ThemeColor
    }

    nonisolated static let builtIns: [Theme] = [
        Theme(id: "stackdust", name: "Stackdust",
              colors: [ThemeColor(hex: 0x4A8FF7), ThemeColor(hex: 0x58DB65),
                       ThemeColor(hex: 0xFAC53E), ThemeColor(hex: 0xF55D78),
                       ThemeColor(hex: 0x8D41FF)],
              accent: ThemeColor(hex: 0x8D41FF)),
        Theme(id: "classic", name: "Classic",
              colors: (0..<10).map {
                  ThemeColor(hue: Double($0) / 10, saturation: 0.80, brightness: 0.70)
              },
              accent: ThemeColor(hex: 0x007AFF)),
        Theme(id: "ocean", name: "Ocean",
              colors: [ThemeColor(hex: 0x3D86F2), ThemeColor(hex: 0x35C4D7),
                       ThemeColor(hex: 0x6558F5), ThemeColor(hex: 0x4FD8A7),
                       ThemeColor(hex: 0x8AA8FF)],
              accent: ThemeColor(hex: 0x35C4D7)),
        Theme(id: "sunset", name: "Sunset",
              colors: [ThemeColor(hex: 0xF55D78), ThemeColor(hex: 0xFA8F3E),
                       ThemeColor(hex: 0xFAC53E), ThemeColor(hex: 0xB04FFB),
                       ThemeColor(hex: 0xF2695C)],
              accent: ThemeColor(hex: 0xFA8F3E)),
        Theme(id: "violet", name: "Violet",
              colors: [ThemeColor(hex: 0x8D41FF), ThemeColor(hex: 0xB892FF),
                       ThemeColor(hex: 0x6F2FD6), ThemeColor(hex: 0xD0B3FF),
                       ThemeColor(hex: 0x5B21B8)],
              accent: ThemeColor(hex: 0x8D41FF)),
    ]

    /// The palette `AppModel` starts with before the store pushes the persisted selection.
    nonisolated static var defaultPalette: [ThemeColor] { builtIns[0].colors }

    private(set) var customThemes: [Theme]
    private var overrides: [String: Override]
    private(set) var selectedID: String

    private static let selectedKey = "themeSelectedID"
    private static let customKey = "themeCustomThemes"
    private static let overridesKey = "themeBuiltInOverrides"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customThemes = Self.decode([Theme].self, forKey: Self.customKey, from: defaults) ?? []
        overrides = Self.decode([String: Override].self, forKey: Self.overridesKey, from: defaults) ?? [:]
        selectedID = defaults.string(forKey: Self.selectedKey) ?? Self.builtIns[0].id
    }

    private let defaults: UserDefaults

    // MARK: - Reading

    /// Built-ins with any stored edits applied.
    var builtInThemes: [Theme] {
        Self.builtIns.map { resolveBuiltIn($0) }
    }

    var themes: [Theme] { builtInThemes + customThemes }

    var selected: Theme {
        themes.first { $0.id == selectedID } ?? builtInThemes[0]
    }

    func isBuiltIn(_ id: String) -> Bool {
        Self.builtIns.contains { $0.id == id }
    }

    /// True when a built-in theme has stored edits (drives the Reset button).
    func isEdited(_ id: String) -> Bool {
        overrides[id] != nil
    }

    private func resolveBuiltIn(_ theme: Theme) -> Theme {
        guard let override = overrides[theme.id] else { return theme }
        var resolved = theme
        resolved.colors = override.colors
        resolved.accent = override.accent
        return resolved
    }

    // MARK: - Selection

    func select(_ id: String) {
        guard themes.contains(where: { $0.id == id }) else { return }
        selectedID = id
        defaults.set(id, forKey: Self.selectedKey)
    }

    // MARK: - Editing

    func setColor(_ color: ThemeColor, at index: Int, of id: String) {
        mutate(id) { theme in
            guard theme.colors.indices.contains(index) else { return }
            theme.colors[index] = color
        }
    }

    func addColor(to id: String) {
        mutate(id) { theme in
            theme.colors.append(theme.colors.last ?? ThemeColor(hex: 0x8D41FF))
        }
    }

    func removeColor(at index: Int, from id: String) {
        mutate(id) { theme in
            guard theme.colors.indices.contains(index), theme.colors.count > 2 else { return }
            theme.colors.remove(at: index)
        }
    }

    func setAccent(_ color: ThemeColor, for id: String) {
        mutate(id) { $0.accent = color }
    }

    /// Renames a custom theme; built-in names are fixed.
    func rename(_ id: String, to name: String) {
        guard !isBuiltIn(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutate(id) { $0.name = trimmed }
    }

    func resetBuiltIn(_ id: String) {
        guard overrides[id] != nil else { return }
        overrides[id] = nil
        persist()
    }

    /// Copies `id` (with any edits) into a new custom theme and returns the copy's id.
    @discardableResult
    func duplicate(_ id: String) -> String? {
        guard let source = themes.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = UUID().uuidString
        copy.name = "\(source.name) Copy"
        customThemes.append(copy)
        persist()
        return copy.id
    }

    func deleteCustom(_ id: String) {
        guard !isBuiltIn(id) else { return }
        customThemes.removeAll { $0.id == id }
        if selectedID == id {
            select(Self.builtIns[0].id)
        }
        persist()
    }

    /// Applies an edit to a built-in (as an override) or a custom theme, then persists.
    private func mutate(_ id: String, _ edit: (inout Theme) -> Void) {
        if let builtIn = Self.builtIns.first(where: { $0.id == id }) {
            var theme = resolveBuiltIn(builtIn)
            edit(&theme)
            overrides[id] = Override(colors: theme.colors, accent: theme.accent)
        } else if let index = customThemes.firstIndex(where: { $0.id == id }) {
            edit(&customThemes[index])
        } else {
            return
        }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        Self.encode(customThemes, forKey: Self.customKey, to: defaults)
        Self.encode(overrides, forKey: Self.overridesKey, to: defaults)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type, forKey key: String, from defaults: UserDefaults
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(
        _ value: T, forKey key: String, to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
