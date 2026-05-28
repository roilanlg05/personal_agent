import Foundation

/// Persists GenerationSettings as JSON in UserDefaults. Injectable for tests.
public struct SettingsStore: Sendable {
    private let defaults: UserDefaults
    private let key = "gemma.generationSettings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> GenerationSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(GenerationSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: GenerationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
