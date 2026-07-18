import SwiftUI

struct ContentView: View {
    let themeStore: ThemeStore
    @State private var model = AppModel()

    /// The window's effective scheme. With a custom theme background this already reflects our
    /// own `preferredColorScheme`; with the system background it tracks the system appearance.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                StartView(model: model)
            case .scanning:
                ScanningView(model: model)
            case .result:
                ResultView(model: model)
            case .failed(let message):
                FailedView(model: model, message: message)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .tint(themeStore.selected.accent.color)
        // Custom background paints the whole window (title bar included) and forces the
        // control scheme by its luminance so labels stay readable; nil follows the system.
        .containerBackground(backgroundStyle, for: .window)
        .preferredColorScheme(themeStore.selected.colorScheme)
        .environment(themeStore)
        .environment(\.themeBackground, themeStore.selected.background)
        .onChange(of: themeStore.selected, initial: true) { pushTheme() }
        .onChange(of: colorScheme) { pushTheme() }
        .task { model.attemptResume() }
    }

    /// The chart is "on a dark background" when the theme's custom color is dark, or — with the
    /// system background — when the system is in dark mode.
    private func pushTheme() {
        let theme = themeStore.selected
        let dark = theme.background.map { $0.luminance < 0.5 } ?? (colorScheme == .dark)
        model.setTheme(palette: theme.colors, darkBackground: dark)
    }

    private var backgroundStyle: AnyShapeStyle {
        if let background = themeStore.selected.background {
            AnyShapeStyle(background.color)
        } else {
            AnyShapeStyle(.windowBackground)
        }
    }
}

#Preview {
    ContentView(themeStore: ThemeStore())
}
