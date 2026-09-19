import Foundation

private struct SpeechSettingsFailure: Error, CustomStringConvertible {
    let description: String
}

/// Any credential access is a failure, including attempted operations that the
/// settings store catches. Returning to system speech needs no Keychain access.
private final class UnavailableSpeechKeys: SettingsAPIKeyStore {
    let values: [String: String]
    var attempts: [String] = []

    init(values: [String: String]) { self.values = values }

    func load(account: String) throws -> String {
        attempts.append("read:\(account)")
        throw SpeechSettingsFailure(description: "Unexpected credential read")
    }

    func save(_ key: String, account: String) throws {
        attempts.append("write:\(account)")
        throw SpeechSettingsFailure(description: "Unexpected credential write")
    }

    func delete(account: String) throws {
        attempts.append("delete:\(account)")
        throw SpeechSettingsFailure(description: "Unexpected credential deletion")
    }
}

@main
struct SpeechSettingsRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw SpeechSettingsFailure(description: message) }
    }

    static func snapshot(_ settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(settings)
    }

    @MainActor
    static func main() throws {
        let suiteName = "Huaci.SpeechSettingsRegression.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SpeechSettingsFailure(description: "Could not create isolated preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferencesKey = "HuaciSettings.v1"
        let chatID = "958097B7-95AB-4F10-A594-E59313468DAA"
        let credentials = ["APIKey": "test-ai-key",
                           "APIKey.profile.\(chatID)": "test-chat-key",
                           "MerriamWebsterAPIKey": "test-old-dictionary-key"]
        let keys = UnavailableSpeechKeys(values: credentials)

        // Include former provider values, malformed values and absent metadata.
        // Every case must retain both accents and all unrelated preferences.
        let oldProviders: [Any?] = ["merriamWebster", "system", "future-provider", 17, NSNull(), nil]
        for accent in EnglishAccent.allCases {
            var expected = AppSettings()
            expected.setEnabled(false)
            expected.popupAfterCopy = true
            expected.translationTarget = TranslationLanguage.korean.rawValue
            expected.englishAccent = accent
            expected.profiles = [
                .legacy(baseURL: "https://api.deepseek.com", model: "translation-model"),
                APIProfile(id: chatID, name: "Independent chat", baseURL: "https://example.com/v1", model: "chat-model")
            ]
            expected.translationProfileID = APIProfile.legacyID
            expected.chatProfileID = chatID
            expected.synchronizeLegacyConfiguration()
            expected.cacheEnabled = false
            expected.cacheMaxEntries = 321
            expected.cacheMaxMegabytes = 9
            expected.historyEnabled = false
            let expectedData = try snapshot(expected)

            for oldProvider in oldProviders {
                var oldJSON = try JSONSerialization.jsonObject(with: expectedData) as! [String: Any]
                oldJSON["speechProvider"] = oldProvider
                let originalData = try JSONSerialization.data(withJSONObject: oldJSON)
                defaults.set(originalData, forKey: preferencesKey)
                let store = SettingsStore(defaults: defaults, keyStore: keys)
                let migratedData = try snapshot(store.settings)
                try check(migratedData == expectedData,
                          "Obsolete speech providers must not reset the saved accent or other preferences")
                try check(defaults.data(forKey: preferencesKey) == originalData && keys.attempts.isEmpty,
                          "Loading an upgrade must not rewrite preferences or access credentials")

                var speechChanges = 0
                var unrelatedChanges = 0
                store.onSpeechSettingsChange = { speechChanges += 1 }
                store.onChange = { unrelatedChanges += 1 }
                store.onVisibilityChange = { unrelatedChanges += 1 }
                store.onTranslationPreferencesChange = { unrelatedChanges += 1 }

                let newAccent: EnglishAccent = accent == .british ? .american : .british
                store.setEnglishAccent(newAccent)
                var changed = expected
                changed.englishAccent = newAccent
                let changedData = try snapshot(changed)
                let actualData = try snapshot(store.settings)
                let reloaded = SettingsStore(defaults: defaults, keyStore: keys)
                let reloadedData = try snapshot(reloaded.settings)
                try check(actualData == changedData && reloadedData == changedData,
                          "Changing the accent must persist and preserve API profiles, cache, history and target language")
                try check(speechChanges == 1 && unrelatedChanges == 0,
                          "Changing the accent must notify only speech observers")
                try check(keys.attempts.isEmpty && keys.values == credentials,
                          "System speech must not read, overwrite or delete old dictionary or AI credentials")
                guard let persisted = defaults.data(forKey: preferencesKey) else {
                    throw SpeechSettingsFailure(description: "Accent preference was not persisted")
                }
                let text = String(decoding: persisted, as: UTF8.self)
                try check(!credentials.values.contains(where: { text.contains($0) }),
                          "Saved accent preferences must not contain credentials")
            }
        }
        try check(AppSettings().englishAccent == .american,
                  "Fresh installs must preserve the existing American system voice default")
        print("System speech upgrade, accent persistence and credential isolation checks passed (isolated preferences; no real Keychain, network or audio).")
    }
}
