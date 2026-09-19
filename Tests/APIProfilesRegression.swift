import Foundation

private struct ProfileRegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private final class MemoryProfileKeys: SettingsAPIKeyStore {
    var values: [String: String] = [:]
    var reads: [String] = []
    var writes: [String] = []
    var deletions: [String] = []
    var rejectWrites = false
    var rejectDeletes = false

    func load(account: String) throws -> String {
        reads.append(account)
        return values[account] ?? ""
    }

    func save(_ key: String, account: String) throws {
        if rejectWrites { throw ProfileRegressionFailure(description: "Simulated Keychain save denial") }
        writes.append(account)
        if key.isEmpty { values.removeValue(forKey: account) }
        else { values[account] = key }
    }

    func delete(account: String) throws {
        if rejectDeletes { throw ProfileRegressionFailure(description: "Simulated Keychain deletion denial") }
        deletions.append(account)
        values.removeValue(forKey: account)
    }
}

@main
struct APIProfilesRegression {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw ProfileRegressionFailure(description: message) }
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        var rejected = false
        do { try operation() } catch { rejected = true }
        try check(rejected, message)
    }

    @MainActor
    static func main() throws {
        let suiteName = "Huaci.APIProfilesRegression.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ProfileRegressionFailure(description: "Could not create isolated preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferencesKey = "HuaciSettings.v1"
        let legacyData = Data(#"{"baseURL":"https://api.deepseek.com/chat/completions","model":"legacy-model","enabled":false,"showMenuBarIcon":false,"popupAfterCopy":true,"translationTarget":"ko","englishAccent":"en-GB"}"#.utf8)
        defaults.set(legacyData, forKey: preferencesKey)
        let keys = MemoryProfileKeys()
        keys.values["APIKey"] = "test-legacy-credential"
        let store = SettingsStore(defaults: defaults, keyStore: keys)
        try check(keys.reads.isEmpty && keys.writes.isEmpty && keys.deletions.isEmpty,
                  "Launching an upgraded app must not access Keychain")
        try check(defaults.data(forKey: preferencesKey) == legacyData,
                  "Loading a migration must not overwrite the original preferences")
        try check(store.settings.profiles == [.legacy(baseURL: "https://api.deepseek.com/chat/completions", model: "legacy-model")],
                  "Old public configuration must migrate to the fixed default profile")
        try check(store.settings.translationProfileID == "default" && store.settings.chatProfileID == "default",
                  "Both purposes must keep using the existing configuration after upgrade")
        try check(store.settings.enabled && !store.settings.showMenuBarIcon && store.settings.popupAfterCopy
                  && store.settings.translationTarget == "ko" && store.settings.englishAccent == .british,
                  "Migration must preserve old preferences and normalize a hidden paused app")
        try check(store.settings.cacheEnabled && store.settings.cacheMaxEntries == 200
                  && store.settings.cacheMaxMegabytes == 5 && store.settings.historyEnabled,
                  "Migration must apply the promised cache and history defaults")
        let original = try store.configuration()
        try check(original.apiKey == "test-legacy-credential" && keys.reads == ["APIKey"],
                  "Legacy credentials must continue using the original Keychain account")

        var configurationChanges = 0
        var preferenceChanges = 0
        store.onChange = { configurationChanges += 1 }
        store.onTranslationPreferencesChange = { preferenceChanges += 1 }
        let secondID = try store.saveProfile(id: nil, name: "  工作配置  ",
                                            baseURL: "https://api.openai.com", model: "test-chat-model", apiKey: "test-second-credential")
        try check(UUID(uuidString: secondID) != nil && secondID != "default", "New profiles must have unique UUID identities")
        try check(store.settings.profiles.count == 2 && store.settings.profiles[1].name == "工作配置",
                  "Saving a profile must preserve earlier configurations and normalize its display name")
        try check(keys.values["APIKey"] == "test-legacy-credential"
                  && keys.values["APIKey.profile.\(secondID)"] == "test-second-credential",
                  "A new profile's key must not overwrite the legacy credential")
        try check(store.settings.translationProfileID == "default" && store.settings.chatProfileID == "default",
                  "Adding a profile must not silently change either default purpose")
        try store.setDefaultProfiles(translationID: secondID, chatID: "default")
        let translation = try store.configuration(for: .translation)
        let chat = try store.configuration(for: .chat)
        try check(translation.apiKey == "test-second-credential" && translation.model == "test-chat-model"
                  && chat.apiKey == "test-legacy-credential" && chat.model == "legacy-model",
                  "Translation and chat must resolve their own profile and credential")
        try check(store.settings.baseURL == translation.endpoint.absoluteString && store.settings.model == translation.model,
                  "Legacy public fields must mirror the translation default")

        try store.save(baseURL: "https://api.openai.com/v1", model: "updated-model", apiKey: "test-updated-credential")
        try check(store.profile(for: .translation).id == secondID && store.profile(for: .translation).model == "updated-model"
                  && store.profile(for: .chat).id == "default" && store.profile(for: .chat).model == "legacy-model",
                  "The legacy save API must only update the current translation profile")
        try check(keys.values["APIKey"] == "test-legacy-credential"
                  && keys.values["APIKey.profile.\(secondID)"] == "test-updated-credential",
                  "Editing a selected profile must preserve other credentials")

        let savedMetadata = defaults.data(forKey: preferencesKey)
        let savedProfiles = store.settings.profiles
        let changesBeforeFailure = configurationChanges
        let writesBeforeFailure = keys.writes.count
        try rejects("Unknown profile IDs must not create new Keychain accounts") {
            _ = try store.saveProfile(id: "not-a-profile", name: "Invalid", baseURL: "https://api.openai.com",
                                      model: "some-model", apiKey: "test-unused")
        }
        try rejects("Invalid names must be rejected before credential changes") {
            _ = try store.saveProfile(id: secondID, name: " ", baseURL: "https://api.openai.com",
                                      model: "some-model", apiKey: "test-unused")
        }
        try rejects("Invalid configuration must be rejected before credential changes") {
            _ = try store.saveProfile(id: secondID, name: "Invalid", baseURL: "http://example.com",
                                      model: "some-model", apiKey: "test-unused")
        }
        try rejects("Unknown default IDs must not alter the selected roles") {
            try store.setDefaultProfiles(translationID: "missing", chatID: secondID)
        }
        try check(keys.writes.count == writesBeforeFailure, "Validation failures must not touch Keychain")
        keys.rejectWrites = true
        try rejects("A rejected credential update must report failure") {
            _ = try store.saveProfile(id: secondID, name: "Changed", baseURL: "https://api.deepseek.com",
                                      model: "changed-model", apiKey: "test-rejected-credential")
        }
        try rejects("A rejected new credential must not leave an orphaned profile") {
            _ = try store.saveProfile(id: nil, name: "New rejected", baseURL: "https://api.deepseek.com",
                                      model: "changed-model", apiKey: "test-rejected-credential")
        }
        keys.rejectWrites = false
        keys.rejectDeletes = true
        try rejects("A rejected Keychain deletion must preserve the profile") { try store.deleteProfile(id: secondID) }
        keys.rejectDeletes = false
        try check(defaults.data(forKey: preferencesKey) == savedMetadata && store.settings.profiles == savedProfiles
                  && store.settings.translationProfileID == secondID && store.settings.chatProfileID == "default"
                  && configurationChanges == changesBeforeFailure,
                  "Failed mutations must preserve metadata, role assignments and observers")

        let changesBeforePreferences = configurationChanges
        try store.saveTranslationPreferences(cacheEnabled: false, maxEntries: 450, maxMegabytes: 12, historyEnabled: false)
        try check(!store.settings.cacheEnabled && store.settings.cacheMaxEntries == 450
                  && store.settings.cacheMaxMegabytes == 12 && !store.settings.historyEnabled,
                  "Cache limits and history preference must persist independently")
        try check(configurationChanges == changesBeforePreferences && preferenceChanges == 1,
                  "Translation preferences must not cancel conversations through onChange")
        let validPreferences = defaults.data(forKey: preferencesKey)
        for entries in [0, -1, 10_001] {
            try rejects("Invalid cache entry limits must report an error instead of clipping") {
                try store.saveTranslationPreferences(cacheEnabled: true, maxEntries: entries, maxMegabytes: 5, historyEnabled: true)
            }
        }
        for size in [0, -1, 101] {
            try rejects("Invalid cache byte limits must report an error instead of clipping") {
                try store.saveTranslationPreferences(cacheEnabled: true, maxEntries: 200, maxMegabytes: size, historyEnabled: true)
            }
        }
        try check(defaults.data(forKey: preferencesKey) == validPreferences && preferenceChanges == 1,
                  "Rejected preference changes must preserve the previous valid values")
        try store.saveTranslationPreferences(cacheEnabled: true, maxEntries: 1, maxMegabytes: 1, historyEnabled: true)
        try store.saveTranslationPreferences(cacheEnabled: true, maxEntries: 10_000, maxMegabytes: 100, historyEnabled: true)

        let rawJSON = String(decoding: defaults.data(forKey: preferencesKey)!, as: UTF8.self)
        try check(!rawJSON.contains("test-legacy-credential") && !rawJSON.contains("test-updated-credential")
                  && !rawJSON.contains("test-second-credential") && !rawJSON.contains("apiKey"),
                  "Preferences must never persist API keys")
        let reloaded = SettingsStore(defaults: defaults, keyStore: keys)
        try check(reloaded.settings.profiles == store.settings.profiles
                  && reloaded.settings.translationProfileID == secondID && reloaded.settings.chatProfileID == "default"
                  && reloaded.settings.cacheMaxEntries == 10_000 && reloaded.settings.cacheMaxMegabytes == 100,
                  "Profiles, purpose assignment and limits must survive relaunch")

        try store.deleteProfile(id: "default")
        try check(store.settings.profiles.count == 1 && store.settings.translationProfileID == secondID
                  && store.settings.chatProfileID == secondID && keys.values["APIKey"] == nil,
                  "Deleting a selected profile must remove its key and choose a remaining profile")
        try check(store.settings.baseURL == store.settings.profiles[0].baseURL
                  && keys.values["APIKey.profile.\(secondID)"] == "test-updated-credential",
                  "Deletion must preserve the remaining profile and synchronize legacy fields")
        let deletionsBeforeLast = keys.deletions.count
        try rejects("The last API profile must be retained") { try store.deleteProfile(id: secondID) }
        try check(keys.deletions.count == deletionsBeforeLast && store.settings.profiles.count == 1,
                  "Rejecting deletion of the last profile must not touch its credential")

        let corrupted = Data(#"{"baseURL":"https://api.deepseek.com","model":"survives","profiles":[],"translationProfileID":"missing","chatProfileID":"missing","cacheMaxEntries":0,"cacheMaxMegabytes":900,"cacheEnabled":"bad","historyEnabled":null}"#.utf8)
        let repaired = try JSONDecoder().decode(AppSettings.self, from: corrupted)
        try check(repaired.profiles == [.legacy(baseURL: "https://api.deepseek.com", model: "survives")]
                  && repaired.translationProfileID == "default" && repaired.chatProfileID == "default"
                  && repaired.cacheMaxEntries == 200 && repaired.cacheMaxMegabytes == 5
                  && repaired.cacheEnabled && repaired.historyEnabled,
                  "Corrupted new fields must normalize without discarding an old valid configuration")
        print("API profile migration, credential isolation, rollback and cache preferences checks passed (isolated preferences; no real Keychain or network).")
    }
}
