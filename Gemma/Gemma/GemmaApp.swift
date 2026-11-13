import SwiftUI

@main
struct GemmaApp: App {
    @State private var model: HarnessModel?

    init() {
        // XCTest starts the app before a test can inject its client or provider.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        _model = State(initialValue: isTestHost ? nil : HarnessModel())
    }

    var body: some Scene {
        WindowGroup {
            if let model {
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
            } else {
                Color.clear
            }
        }
        #if os(macOS)
        Settings {
            if let model {
                SettingsView(model: model)
            }
        }
        #endif
    }
}
