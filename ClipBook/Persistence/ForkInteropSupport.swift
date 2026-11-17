import Foundation

struct ForkPreferences: Equatable {
    static let userDefaultsKey = "ClipBookForkPreferencesV1"

    var schemaVersion: Int = 1
}

extension ForkPreferences: Codable {
    init(from decoder: Decoder) throws {
        let defaults = ForkPreferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? defaults.schemaVersion
    }
}

extension PreferencesStore {
    func loadForkPreferences() -> ForkPreferences {
        guard let data = userDefaults.data(forKey: ForkPreferences.userDefaultsKey),
              let preferences = try? decoder.decode(ForkPreferences.self, from: data) else {
            return ForkPreferences()
        }
        return preferences
    }

    func saveForkPreferences(_ preferences: ForkPreferences) {
        if let data = try? encoder.encode(preferences) {
            userDefaults.set(data, forKey: ForkPreferences.userDefaultsKey)
        }
    }
}
