import Foundation

/// UserDefaults keys shared between the Settings UI (@AppStorage) and non-View readers (HarnessModel).
enum SettingsKeys {
    /// Bool. When true the server is launched with a wired-memory limit (anti-cold-start). Default false.
    static let keepModelResident = "keepModelResident"

    static let chatProvider = "chatProvider"            // ModelProvider.Kind.rawValue
    static let chatModel = "chatModel"
    static let consolidationProvider = "consolidationProvider"
    static let consolidationModel = "consolidationModel"

    /// String. Base URL of the i3 browser service (port 8083). Empty = drive a local `agent-browser`.
    static let browserBaseURL = "browserBaseURL"
    /// String. Bearer token for the i3 browser service.
    static let browserBearerToken = "browserBearerToken"
}
