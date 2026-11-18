import SwiftUI

@main
struct WorkbookApp: App {
    @State private var settings = AppSettings()
    @State private var navigator = Navigator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(navigator)
                .tint(Theme.brass)
                .preferredColorScheme(.light)
        }
    }
}
