import Foundation

private struct AutoTranslationSettingsFailure: Error, CustomStringConvertible {
    let description: String
}

private final class UnavailableAutoTranslationKeys: SettingsAPIKeyStore {
    var attempts = 0

    func load(account: String) throws -> String {
        attempts += 1
        throw AutoTranslationSettingsFailure(description: "Unexpected credential read")
    }

    func save(_ key: String, account: String) throws {
        attempts += 1
        throw AutoTranslationSettingsFailure(description: "Unexpected credential write")
    }

    func delete(account: String) throws {
        attempts += 1
        throw AutoTranslationSettingsFailure(description: "Unexpected credential deletion")
    }
}

@main
struct AutoTranslationSettingsRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw AutoTranslationSettingsFailure(description: message) }
    }

    static func snapshot(_ settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(settings)
    }

    @MainActor
    static func main() throws {
        let suiteName = "Huaci.AutoTranslationSettingsRegression.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw AutoTranslationSettingsFailure(description: "Could not create isolated preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferencesKey = "HuaciSettings.v1"
        let keys = UnavailableAutoTranslationKeys()
        let freshStore = SettingsStore(defaults: defaults, keyStore: keys)
        try check(!AppSettings().autoTranslateSelection && !freshStore.settings.autoTranslateSelection,
                  "New installs must never enable automatic API requests by default")
        try check(defaults.data(forKey: preferencesKey) == nil && keys.attempts == 0,
                  "Loading default preferences must not persist or access credentials")

        var expected = AppSettings()
        expected.setEnabled(false)
        expected.popupAfterCopy = true
        expected.translationTarget = TranslationLanguage.korean.rawValue
        expected.englishAccent = .british
        expected.profiles = [.legacy(baseURL: "https://api.deepseek.com", model: "saved-model")]
        expected.synchronizeLegacyConfiguration()
        expected.cacheEnabled = false
        expected.cacheMaxEntries = 321
        expected.cacheMaxMegabytes = 9
        expected.historyEnabled = false
        let expectedData = try snapshot(expected)

        // Missing (pre-1.3.8) or invalid opt-in must preserve other preferences
        // and remain off, rather than enabling requests or resetting the profile.
        let oldValues: [Any?] = [nil, NSNull(), "true", 1, false]
        for oldValue in oldValues {
            var oldJSON = try JSONSerialization.jsonObject(with: expectedData) as! [String: Any]
            oldJSON["autoTranslateSelection"] = oldValue
            let originalData = try JSONSerialization.data(withJSONObject: oldJSON)
            defaults.set(originalData, forKey: preferencesKey)
            let store = SettingsStore(defaults: defaults, keyStore: keys)
            let migratedData = try snapshot(store.settings)
            try check(migratedData == expectedData,
                      "Upgrade or invalid opt-in must preserve every unrelated setting and stay off")
            try check(defaults.data(forKey: preferencesKey) == originalData,
                      "Loading preferences must not rewrite the saved data")

            var selectionChanges = 0
            var unrelatedChanges = 0
            store.onSelectionPreferencesChange = { selectionChanges += 1 }
            store.onChange = { unrelatedChanges += 1 }
            store.onVisibilityChange = { unrelatedChanges += 1 }
            store.onTranslationPreferencesChange = { unrelatedChanges += 1 }
            store.onSpeechSettingsChange = { unrelatedChanges += 1 }
            store.setAutoTranslateSelection(true)
            var enabled = expected
            enabled.autoTranslateSelection = true
            let enabledData = try snapshot(enabled)
            let actualEnabledData = try snapshot(store.settings)
            let restored = SettingsStore(defaults: defaults, keyStore: keys)
            let restoredData = try snapshot(restored.settings)
            try check(actualEnabledData == enabledData && restoredData == enabledData,
                      "Opt-in must persist across restart without enabling a paused assistant or changing other preferences")
            try check(selectionChanges == 1 && unrelatedChanges == 0 && keys.attempts == 0,
                      "Opt-in must notify only selection observers and never touch credentials")

            store.setAutoTranslateSelection(true)
            try check(selectionChanges == 1,
                      "Saving the same value must not invalidate the current selection again")
            store.setAutoTranslateSelection(false)
            let disabledData = try snapshot(store.settings)
            let restoredDisabled = SettingsStore(defaults: defaults, keyStore: keys)
            let restoredDisabledData = try snapshot(restoredDisabled.settings)
            try check(disabledData == expectedData && restoredDisabledData == expectedData,
                      "Opt-out must persist across restart and preserve all other settings")
            try check(selectionChanges == 2 && unrelatedChanges == 0 && keys.attempts == 0,
                      "Opt-out must not clear translation cache, interrupt chat or access credentials")
        }
        print("Automatic translation preference defaults, migration, persistence and callback isolation checks passed (isolated preferences; no Keychain or network).")
    }
}
