import Foundation
import Security

struct AppSettings: Codable {
    var baseURL: String = ""
    var model: String = ""
    private(set) var enabled: Bool = true
    private(set) var showMenuBarIcon: Bool = true
    var popupAfterCopy: Bool = false
    var translationTarget: String = TranslationLanguage.simplifiedChinese.rawValue
    var englishAccent: EnglishAccent = .american
    var profiles: [APIProfile] = [.legacy()]
    var translationProfileID: String = APIProfile.legacyID
    var chatProfileID: String = APIProfile.legacyID
    var cacheEnabled: Bool = true
    var cacheMaxEntries: Int = 200
    var cacheMaxMegabytes: Int = 5
    var historyEnabled: Bool = true

    private enum CodingKeys: String, CodingKey {
        case baseURL, model, enabled, showMenuBarIcon, popupAfterCopy, translationTarget, englishAccent
        case profiles, translationProfileID, chatProfileID
        case cacheEnabled, cacheMaxEntries, cacheMaxMegabytes, historyEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        showMenuBarIcon = try values.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        // A hidden, paused accessory app has no usable selection entry point.
        // Normalize this state on load as well as in all preference mutations.
        if !showMenuBarIcon { enabled = true }
        popupAfterCopy = try values.decodeIfPresent(Bool.self, forKey: .popupAfterCopy) ?? false
        let target = try values.decodeIfPresent(String.self, forKey: .translationTarget)
        translationTarget = target.flatMap(TranslationLanguage.init(rawValue:))?.rawValue
            ?? TranslationLanguage.simplifiedChinese.rawValue
        let accent = try values.decodeIfPresent(String.self, forKey: .englishAccent)
        englishAccent = accent.flatMap(EnglishAccent.init(rawValue:)) ?? .american
        // Older online-speech provider metadata is intentionally ignored.
        // System speech keeps the saved accent and never needs a dictionary key.

        // Migration is metadata-only. Keep the original Keychain account and do
        // not request Keychain access merely because an upgraded app launched.
        let storedProfiles = (try? values.decode([APIProfile].self, forKey: .profiles)) ?? []
        var seenIDs = Set<String>()
        profiles = storedProfiles.filter {
            APIProfile.isValidID($0.id) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seenIDs.insert($0.id).inserted
        }
        if profiles.isEmpty { profiles = [.legacy(baseURL: baseURL, model: model)] }
        let translationID = (try? values.decode(String.self, forKey: .translationProfileID)) ?? APIProfile.legacyID
        let chatID = (try? values.decode(String.self, forKey: .chatProfileID)) ?? APIProfile.legacyID
        translationProfileID = profiles.contains(where: { $0.id == translationID }) ? translationID : profiles[0].id
        chatProfileID = profiles.contains(where: { $0.id == chatID }) ? chatID : profiles[0].id
        synchronizeLegacyConfiguration()

        cacheEnabled = (try? values.decode(Bool.self, forKey: .cacheEnabled)) ?? true
        let entries = (try? values.decode(Int.self, forKey: .cacheMaxEntries)) ?? 200
        cacheMaxEntries = (1...10_000).contains(entries) ? entries : 200
        let megabytes = (try? values.decode(Int.self, forKey: .cacheMaxMegabytes)) ?? 5
        cacheMaxMegabytes = (1...100).contains(megabytes) ? megabytes : 5
        historyEnabled = (try? values.decode(Bool.self, forKey: .historyEnabled)) ?? true
    }

    mutating func setEnabled(_ requested: Bool) {
        enabled = requested || !showMenuBarIcon
    }

    mutating func setShowMenuBarIcon(_ visible: Bool) {
        showMenuBarIcon = visible
        if !visible { enabled = true }
    }

    mutating func synchronizeLegacyConfiguration() {
        guard let profile = profiles.first(where: { $0.id == translationProfileID }) else { return }
        baseURL = profile.baseURL
        model = profile.model
    }
}

private struct SettingsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Injected by regression tests so profile migration and failures never access
/// a real user's Keychain. Only the production implementation uses Security.
protocol SettingsAPIKeyStore {
    func load(account: String) throws -> String
    func save(_ key: String, account: String) throws
    func delete(account: String) throws
}

private struct KeychainAPIKeyStore: SettingsAPIKeyStore {
    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.local.huaci-assistant",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    func load(account: String) throws -> String {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw keychainError(status, action: "读取") }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SettingsError(message: "钥匙串中的 API Key 无法读取，请重新填写并保存。")
        }
        return value
    }

    func save(_ key: String, account: String) throws {
        if key.isEmpty { try delete(account: account); return }
        let request = query(account: account)
        let data = Data(key.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus, action: "保存") }

        var item = request
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Another instance may have created the item between lookup and add.
            let retryStatus = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
            guard retryStatus == errSecSuccess else { throw keychainError(retryStatus, action: "保存") }
        } else if addStatus != errSecSuccess {
            throw keychainError(addStatus, action: "保存")
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, action: "删除")
        }
    }

    private func keychainError(_ status: OSStatus, action: String) -> SettingsError {
        let message: String
        switch status {
        case errSecInteractionNotAllowed:
            message = "钥匙串当前不可访问，请解锁 Mac 后重试。"
        case errSecAuthFailed, errSecUserCanceled:
            message = "未获准\(action)钥匙串中的 API Key，请允许访问后重试。"
        default:
            message = "无法\(action)钥匙串中的 API Key（错误 \(status)），请重试。"
        }
        return SettingsError(message: message)
    }
}

@MainActor
final class SettingsStore {
    private static let preferencesKey = "HuaciSettings.v1"
    private let defaults: UserDefaults
    private let keyStore: any SettingsAPIKeyStore

    private(set) var settings: AppSettings
    var onChange: (() -> Void)?
    var onVisibilityChange: (() -> Void)?
    var onTranslationPreferencesChange: (() -> Void)?
    var onSpeechSettingsChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, keyStore: (any SettingsAPIKeyStore)? = nil) {
        self.defaults = defaults
        self.keyStore = keyStore ?? KeychainAPIKeyStore()
        if let data = defaults.data(forKey: Self.preferencesKey),
           let stored = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = stored
        } else {
            settings = AppSettings()
        }
    }

    func profile(for purpose: APIPurpose) -> APIProfile {
        let id = purpose == .translation ? settings.translationProfileID : settings.chatProfileID
        return settings.profiles.first(where: { $0.id == id }) ?? settings.profiles[0]
    }

    func loadAPIKey(profileID: String? = nil) throws -> String {
        let id = profileID ?? settings.translationProfileID
        try requireProfile(id)
        return try keyStore.load(account: keychainAccount(for: id))
    }

    func save(baseURL: String, model: String, apiKey: String) throws {
        let current = profile(for: .translation)
        _ = try saveProfile(id: current.id, name: current.name, baseURL: baseURL, model: model, apiKey: apiKey)
    }

    @discardableResult
    func saveProfile(id: String?, name: String, baseURL: String, model: String, apiKey: String) throws -> String {
        let profileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileName.isEmpty, profileName.count <= 80,
              !profileName.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw SettingsError(message: "配置名称需为 1–80 个字符，且不能包含换行或控制字符。")
        }
        if let id { try requireProfile(id) }
        let config = try APIConfiguration.validated(baseURL: baseURL, apiKey: apiKey, model: model)
        let profileID = id ?? UUID().uuidString
        let profile = APIProfile(id: profileID, name: profileName,
                                 baseURL: config.endpoint.absoluteString, model: config.model)
        var updated = settings
        if let index = updated.profiles.firstIndex(where: { $0.id == profileID }) {
            updated.profiles[index] = profile
        } else {
            updated.profiles.append(profile)
        }
        updated.synchronizeLegacyConfiguration()
        // Finish all fallible metadata work before changing the credential.
        let encoded = try encode(updated)
        try keyStore.save(config.apiKey, account: keychainAccount(for: profileID))
        commit(updated, encoded: encoded)
        onChange?()
        return profileID
    }

    func deleteProfile(id: String) throws {
        try requireProfile(id)
        guard settings.profiles.count > 1 else { throw SettingsError(message: "至少需要保留一套 API 配置。") }
        var updated = settings
        updated.profiles.removeAll(where: { $0.id == id })
        let fallback = updated.profiles[0].id
        if updated.translationProfileID == id { updated.translationProfileID = fallback }
        if updated.chatProfileID == id { updated.chatProfileID = fallback }
        updated.synchronizeLegacyConfiguration()
        let encoded = try encode(updated)
        try keyStore.delete(account: keychainAccount(for: id))
        commit(updated, encoded: encoded)
        onChange?()
    }

    func setDefaultProfiles(translationID: String, chatID: String) throws {
        try requireProfile(translationID)
        try requireProfile(chatID)
        guard translationID != settings.translationProfileID || chatID != settings.chatProfileID else { return }
        var updated = settings
        updated.translationProfileID = translationID
        updated.chatProfileID = chatID
        updated.synchronizeLegacyConfiguration()
        commit(updated, encoded: try encode(updated))
        onChange?()
    }

    func saveTranslationPreferences(cacheEnabled: Bool, maxEntries: Int, maxMegabytes: Int, historyEnabled: Bool) throws {
        guard (1...10_000).contains(maxEntries) else {
            throw SettingsError(message: "缓存条数需在 1–10,000 之间。")
        }
        guard (1...100).contains(maxMegabytes) else {
            throw SettingsError(message: "缓存文本大小需在 1–100 MB 之间。")
        }
        var updated = settings
        updated.cacheEnabled = cacheEnabled
        updated.cacheMaxEntries = maxEntries
        updated.cacheMaxMegabytes = maxMegabytes
        updated.historyEnabled = historyEnabled
        commit(updated, encoded: try encode(updated))
        onTranslationPreferencesChange?()
    }

    func setEnabled(_ enabled: Bool) {
        var updated = settings
        updated.setEnabled(enabled)
        // Encoding this fixed string/bool structure has no external failure sources.
        guard let encoded = try? JSONEncoder().encode(updated) else { return }
        commit(updated, encoded: encoded)
        onChange?()
    }

    func setShowMenuBarIcon(_ visible: Bool) {
        var updated = settings
        updated.setShowMenuBarIcon(visible)
        guard let encoded = try? JSONEncoder().encode(updated) else { return }
        commit(updated, encoded: encoded)
        onVisibilityChange?()
    }

    func setPopupAfterCopy(_ enabled: Bool) {
        var updated = settings
        updated.popupAfterCopy = enabled
        guard let encoded = try? JSONEncoder().encode(updated) else { return }
        commit(updated, encoded: encoded)
        onChange?()
    }

    /// This preference must not emit the configuration-change callback: changing
    /// language in the translation panel should keep the current selection open.
    func setTranslationTarget(_ language: TranslationLanguage) {
        var updated = settings
        updated.translationTarget = language.rawValue
        guard let encoded = try? JSONEncoder().encode(updated) else { return }
        commit(updated, encoded: encoded)
    }

    func configuration(for purpose: APIPurpose = .translation) throws -> APIConfiguration {
        try configuration(profileID: profile(for: purpose).id)
    }

    func configuration(profileID: String) throws -> APIConfiguration {
        try requireProfile(profileID)
        let selected = settings.profiles.first(where: { $0.id == profileID })!
        return try APIConfiguration.validated(baseURL: selected.baseURL,
                                              apiKey: loadAPIKey(profileID: profileID), model: selected.model)
    }

    /// A pronunciation preference must not cancel translation or AI generation.
    func setEnglishAccent(_ accent: EnglishAccent) {
        var updated = settings
        updated.englishAccent = accent
        guard let encoded = try? JSONEncoder().encode(updated) else { return }
        commit(updated, encoded: encoded)
        onSpeechSettingsChange?()
    }

    private func requireProfile(_ id: String) throws {
        guard settings.profiles.contains(where: { $0.id == id }) else {
            throw SettingsError(message: "这套 API 配置已不存在，请重新选择。")
        }
    }

    private func keychainAccount(for id: String) -> String {
        id == APIProfile.legacyID ? "APIKey" : "APIKey.profile.\(id)"
    }

    private func encode(_ updated: AppSettings) throws -> Data {
        do { return try JSONEncoder().encode(updated) }
        catch { throw SettingsError(message: "无法保存设置，请重试。") }
    }

    private func commit(_ updated: AppSettings, encoded: Data) {
        defaults.set(encoded, forKey: Self.preferencesKey)
        settings = updated
    }
}
