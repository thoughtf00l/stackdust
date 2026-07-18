import SwiftUI

@main
struct StackdustApp: App {
    var body: some Scene {
        Window("Stackdust", id: "main") {
            ContentView()
        }
        .defaultSize(width: 900, height: 680)
        .windowResizability(.contentMinSize)
    }
}
