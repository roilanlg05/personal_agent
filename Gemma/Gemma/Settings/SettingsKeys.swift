import Foundation

/// UserDefaults keys shared between the Settings UI (@AppStorage) and non-View readers (HarnessModel).
enum SettingsKeys {
    /// Bool. When true the server is launched with a wired-memory limit (anti-cold-start). Default false.
    static let keepModelResident = "keepModelResident"
}
