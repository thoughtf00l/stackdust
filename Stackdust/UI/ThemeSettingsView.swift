import SwiftUI

/// The Settings (⌘,) pane: pick a chart theme, edit its colors live, manage custom themes.
/// Built-in themes are edited through overrides and can be reset; custom themes can be
/// renamed and deleted. All edits apply to the chart immediately.
struct ThemeSettingsView: View {
    let store: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            themeList
                .frame(width: 210)
            Divider()
            ThemeDetail(store: store, theme: store.selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 640, height: 420)
        // The Settings window wears the theme too: surface color, control scheme, accent.
        .background(surfaceStyle, ignoresSafeAreaEdges: .all)
        .background(TitlebarConfigurator(transparent: store.selected.hasThemedSurfaces))
        .preferredColorScheme(store.selected.colorScheme)
        .tint(store.selected.accent.color)
    }

    private var surfaceStyle: AnyShapeStyle {
        if store.selected.isGlass {
            Theme.glassMaterial(for: colorScheme)
        } else if let surface = store.selected.surface {
            AnyShapeStyle(surface.color)
        } else {
            AnyShapeStyle(Color(nsColor: store.selected.systemTintedBackground))
        }
    }

    private var themeList: some View {
        List(selection: selectionBinding) {
            Section("Built-in") {
                ForEach(store.builtInThemes) { theme in
                    ThemeListRow(theme: theme, edited: store.isEdited(theme.id))
                        .tag(theme.id)
                }
            }
            if !store.customThemes.isEmpty {
                Section("Custom") {
                    ForEach(store.customThemes) { theme in
                        ThemeListRow(theme: theme, edited: false)
                            .tag(theme.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { store.selectedID },
            set: { if let id = $0 { store.select(id) } }
        )
    }
}

private struct ThemeListRow: View {
    let theme: Theme
    let edited: Bool

    var body: some View {
        HStack {
            Text(theme.name)
            if edited {
                Text("edited")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PaletteStrip(colors: theme.colors)
                .frame(width: 50, height: 10)
        }
    }
}

/// A compact rounded strip showing a palette's colors side by side.
private struct PaletteStrip: View {
    let colors: [ThemeColor]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { index in
                colors[index].color
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct ThemeDetail: View {
    let store: ThemeStore
    let theme: Theme

    private var isBuiltIn: Bool { store.isBuiltIn(theme.id) }
    private static let maxColors = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            PaletteStrip(colors: theme.colors)
                .frame(height: 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(theme.colors.indices, id: \.self) { index in
                        colorRow(at: index)
                    }
                    Button {
                        store.addColor(to: theme.id)
                    } label: {
                        Label("Add Color", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(theme.colors.count >= Self.maxColors)
                    .padding(.top, 2)

                    Divider().padding(.vertical, 4)

                    ColorPicker("Accent", selection: accentBinding, supportsOpacity: false)
                        .help("Buttons, toggles, and selection highlights")

                    HStack {
                        Picker("Background", selection: backgroundModeBinding) {
                            Text("System").tag(BackgroundMode.system)
                            Text("Custom").tag(BackgroundMode.custom)
                            Text("Glass").tag(BackgroundMode.glass)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        if theme.background != nil {
                            ColorPicker("", selection: backgroundBinding, supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                    .help("Window background: system, a custom color (controls match its darkness), or a behind-window glass blur")
                }
                .padding(.trailing, 8)
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack {
            if isBuiltIn {
                Text(theme.name)
                    .font(.title3.weight(.semibold))
            } else {
                TextField("Theme name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .frame(maxWidth: 220)
            }
            Spacer()
        }
    }

    private func colorRow(at index: Int) -> some View {
        HStack {
            ColorPicker(
                "Color \(index + 1)",
                selection: colorBinding(at: index),
                supportsOpacity: false
            )
            Spacer()
            Button {
                store.removeColor(at: index, from: theme.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(theme.colors.count <= 2)
            .help("Remove this color")
        }
    }

    private var footer: some View {
        HStack {
            Button("Duplicate") { duplicateAndSelect() }
            Spacer()
            if isBuiltIn {
                Button("Reset to Defaults") { store.resetBuiltIn(theme.id) }
                    .disabled(!store.isEdited(theme.id))
            } else {
                Button("Delete", role: .destructive) { store.deleteCustom(theme.id) }
            }
        }
    }

    private func duplicateAndSelect() {
        if let id = store.duplicate(theme.id) {
            store.select(id)
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { theme.name },
            set: { store.rename(theme.id, to: $0) }
        )
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { theme.accent.color },
            set: { store.setAccent(ThemeColor($0), for: theme.id) }
        )
    }

    /// The dark surface from the landing page — the starting point when switching to Custom.
    private static let defaultCustomBackground = ThemeColor(hex: 0x191228)

    private enum BackgroundMode: Hashable {
        case system, custom, glass
    }

    private var backgroundModeBinding: Binding<BackgroundMode> {
        Binding(
            get: {
                if theme.isGlass { return .glass }
                return theme.background != nil ? .custom : .system
            },
            set: { mode in
                switch mode {
                case .system: store.setBackground(nil, for: theme.id)
                case .custom: store.setBackground(Self.defaultCustomBackground, for: theme.id)
                case .glass: store.setGlass(true, for: theme.id)
                }
            }
        )
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { (theme.background ?? Self.defaultCustomBackground).color },
            set: { store.setBackground(ThemeColor($0), for: theme.id) }
        )
    }

    private func colorBinding(at index: Int) -> Binding<Color> {
        Binding(
            get: {
                theme.colors.indices.contains(index) ? theme.colors[index].color : .gray
            },
            set: { store.setColor(ThemeColor($0), at: index, of: theme.id) }
        )
    }
}

#Preview {
    ThemeSettingsView(store: ThemeStore())
}
