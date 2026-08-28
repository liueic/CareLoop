import SwiftData
import SwiftUI

@main
struct CareLoopApp: App {
    @State private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appEnvironment)
                .tint(CareTheme.sage)
        }
        .modelContainer(appEnvironment.container)
    }
}
