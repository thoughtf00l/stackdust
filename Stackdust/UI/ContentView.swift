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
        if themeStore.selected.isGlass {
            AnyShapeStyle(.ultraThinMaterial)
        } else if let background = themeStore.selected.background {
            AnyShapeStyle(background.color)
        } else {
            AnyShapeStyle(Color(nsColor: themeStore.selected.systemTintedBackground))
        }
    }
}

/// AppKit window dressing SwiftUI cannot express: a transparent title bar, so the theme's
/// window background shows through it (`containerBackground` alone stops at the title bar's
/// material). System-background themes get the standard material back.
struct TitlebarConfigurator: NSViewRepresentable {
    let transparent: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window is not attached yet during makeNSView; configure on the next runloop turn.
        DispatchQueue.main.async { [transparent] in
            Self.apply(transparent: transparent, to: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Self.apply(transparent: transparent, to: view.window)
    }

    private static func apply(transparent: Bool, to window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = transparent
        window.titlebarSeparatorStyle = transparent ? .none : .automatic
    }
}

#Preview {
    ContentView(themeStore: ThemeStore())
}
