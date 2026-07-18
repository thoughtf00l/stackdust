import SwiftUI

struct ContentView: View {
    let themeStore: ThemeStore
    @State private var model = AppModel()

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
        .onChange(of: themeStore.selected, initial: true) { _, theme in
            model.themePalette = theme.colors
        }
        .task { model.attemptResume() }
    }
}

#Preview {
    ContentView(themeStore: ThemeStore())
}
