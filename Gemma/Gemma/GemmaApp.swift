import SwiftUI

@main
struct GemmaApp: App {
    @State private var model = HarnessModel()

    var body: some Scene {
        WindowGroup {
            HarnessView(model: model)
                .task {
                    await AtoZSessionManager.shared.syncSessionFromServer()
                }
                .onOpenURL { url in
                    if url.scheme == "gemma" {
                        Task {
                            await AtoZSessionManager.shared.syncSessionFromServer()
                        }
                    }
                }
        }
        #if os(macOS)
        Settings {
            SettingsView(model: model)
        }
        #endif
    }
}
