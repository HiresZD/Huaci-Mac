import Foundation

/// Only translation text and its display metadata are retained. API credentials,
/// conversation messages, rendered views and images never belong in this model.
struct SavedTranslation: Codable, Equatable, Identifiable {
    var id: UUID
    var original: String
    var targetLanguage: String
    var translatedText: String
    var dictionary: DictionaryEntry?
    var requestedModel: String
    var returnedModel: String?
    var endpointHost: String
    var createdAt: Date
    var isFavorite: Bool

    init(id: UUID = UUID(), original: String, targetLanguage: String,
         translatedText: String, dictionary: DictionaryEntry? = nil,
         requestedModel: String, returnedModel: String? = nil,
         endpointHost: String, createdAt: Date = Date(), isFavorite: Bool = false) {
        self.id = id
        self.original = original
        self.targetLanguage = targetLanguage
        self.translatedText = translatedText
        self.dictionary = dictionary
        self.requestedModel = requestedModel
        self.returnedModel = returnedModel
        self.endpointHost = endpointHost
        self.createdAt = createdAt
        self.isFavorite = isFavorite
    }
}

struct TranslationCacheKey: Hashable, Codable {
    let original: String
    let targetLanguage: String
    let profileID: String
    let endpoint: String
    let model: String

    init(original: String, targetLanguage: String, profileID: String,
         endpoint: String, model: String) {
        self.original = original
        self.targetLanguage = targetLanguage
        self.profileID = profileID
        self.endpoint = endpoint
        self.model = model
    }
}

private enum TranslationTextEncoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func byteCount<T: Encodable>(_ value: T) -> Int? {
        try? encoder().encode(value).count
    }
}

/// A memory-only LRU. The byte budget is the sum of the UTF-8 JSON encodings of
/// every cache key and record, including dictionary text, JSON escaping and
/// metadata. It is a text-data budget, NOT a promise about total process RAM:
/// Swift collections, object bookkeeping and temporary encodings have overhead.
/// Neither the cache nor its keys are written to disk.
final class TranslationCache {
    private struct Item {
        let value: SavedTranslation
        let bytes: Int
    }

    private var items: [TranslationCacheKey: Item] = [:]
    private var recency: [TranslationCacheKey] = [] // least recently used first
    private(set) var totalBytes = 0
    private(set) var maxEntries: Int
    private(set) var maxBytes: Int
    var count: Int { items.count }

    init(maxEntries: Int = 200, maxBytes: Int = 5_000_000) {
        self.maxEntries = max(0, maxEntries)
        self.maxBytes = max(0, maxBytes)
    }

    func value(for key: TranslationCacheKey) -> SavedTranslation? {
        guard let item = items[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return item.value
    }

    func insert(_ value: SavedTranslation, for key: TranslationCacheKey) {
        // Replacing an oversized result must also remove the previous result:
        // otherwise a later lookup could unexpectedly revive stale text.
        remove(key)
        guard maxEntries > 0, maxBytes > 0,
              let keyBytes = TranslationTextEncoding.byteCount(key),
              let valueBytes = TranslationTextEncoding.byteCount(value),
              keyBytes <= maxBytes, valueBytes <= maxBytes - keyBytes else { return }
        let bytes = keyBytes + valueBytes
        while count >= maxEntries || totalBytes > maxBytes - bytes {
            guard let oldest = recency.first else { return }
            remove(oldest)
        }
        items[key] = Item(value: value, bytes: bytes)
        recency.append(key)
        totalBytes += bytes
    }

    func configure(maxEntries: Int, maxBytes: Int) {
        self.maxEntries = max(0, maxEntries)
        self.maxBytes = max(0, maxBytes)
        while count > self.maxEntries || totalBytes > self.maxBytes {
            guard let oldest = recency.first else { break }
            remove(oldest)
        }
    }

    func removeAll() {
        items.removeAll(keepingCapacity: false)
        recency.removeAll(keepingCapacity: false)
        totalBytes = 0
    }

    private func remove(_ key: TranslationCacheKey) {
        if let item = items.removeValue(forKey: key) { totalBytes -= item.bytes }
        recency.removeAll { $0 == key }
    }
}

/// Local, bounded history. A mutation becomes visible only after an atomic disk
/// write succeeds; failure preserves both the last saved UI state and disk data.
/// Corrupt or incompatible files are preserved and locked against accidental
/// replacement for this store's lifetime. Favorites are never evicted to fit a
/// newer result; only nonfavorite history may be discarded.
@MainActor
final class TranslationHistoryStore {
    private struct Document: Codable {
        let version: Int
        let records: [SavedTranslation]
    }

    private struct StorageError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct RecordIdentity: Hashable {
        let original: String
        let targetLanguage: String
    }

    private(set) var records: [SavedTranslation] = []
    private(set) var lastError: String?
    var onChange: (() -> Void)?
    let fileURL: URL
    let maxHistoryEntries: Int
    let maxFavoriteEntries: Int
    let maxBytes: Int
    private var loadingError: String?

    init(fileURL: URL? = nil, maxHistoryEntries: Int = 200,
         maxFavoriteEntries: Int = 1_000, maxBytes: Int = 20_000_000) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask)[0]
            .appendingPathComponent("Huaci", isDirectory: true)
            .appendingPathComponent("translation-history.json")
        self.maxHistoryEntries = min(100_000, max(0, maxHistoryEntries))
        self.maxFavoriteEntries = min(100_000, max(0, maxFavoriteEntries))
        self.maxBytes = min(1_000_000_000, max(0, maxBytes))
        load()
    }

    func add(_ record: SavedTranslation) {
        upsert(record, favoriteOverride: nil)
    }

    /// Saves the result currently on screen and the requested favorite state in
    /// one transaction. This differs from toggling an existing history row:
    /// automatic history may be disabled, leaving an older translation on disk.
    func saveFavorite(_ record: SavedTranslation, isFavorite: Bool) {
        upsert(record, favoriteOverride: isFavorite)
    }

    private func upsert(_ record: SavedTranslation, favoriteOverride: Bool?) {
        guard canWrite() else { return }
        do {
            try validate(record)
            var candidate = records
            var incoming = record
            if let index = candidate.firstIndex(where: {
                $0.original == record.original && $0.targetLanguage == record.targetLanguage
            }) {
                let previous = candidate.remove(at: index)
                incoming.id = previous.id
                incoming.isFavorite = previous.isFavorite
            } else if candidate.contains(where: { $0.id == incoming.id }) {
                incoming.id = UUID()
            }
            if let favoriteOverride { incoming.isFavorite = favoriteOverride }
            candidate.insert(incoming, at: 0)
            try commit(bounded(candidate, protecting: incoming.id))
        } catch { report(error) }
    }

    func toggleFavorite(id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        setFavorite(id: id, isFavorite: !record.isFavorite)
    }

    func setFavorite(id: UUID, isFavorite: Bool) {
        guard canWrite(), let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].isFavorite != isFavorite else { return }
        var candidate = records
        candidate[index].isFavorite = isFavorite
        do { try commit(bounded(candidate, protecting: isFavorite ? id : nil)) }
        catch { report(error) }
    }

    func remove(id: UUID) {
        guard canWrite(), records.contains(where: { $0.id == id }) else { return }
        do { try commit(records.filter { $0.id != id }) }
        catch { report(error) }
    }

    /// Clears recent history while keeping every saved favorite.
    func clearHistory() {
        guard canWrite() else { return }
        do { try commit(records.filter(\.isFavorite)) }
        catch { report(error) }
    }

    func clearAll() {
        guard canWrite() else { return }
        do { try commit([]) }
        catch { report(error) }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            // JSON wrapper / commas are additional to the sum of record bytes.
            let maximumFileBytes = maxBytes + 65_536
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value <= Int64(maximumFileBytes) else {
                throw StorageError(message: "翻译记录文件超过大小限制。")
            }
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard data.count <= maximumFileBytes else {
                throw StorageError(message: "翻译记录文件超过大小限制。")
            }
            let document = try TranslationTextEncoding.decoder().decode(Document.self, from: data)
            guard document.version == 1 else {
                throw StorageError(message: "翻译记录文件的格式版本不兼容。")
            }
            guard document.records.count <= 200_000 else {
                throw StorageError(message: "翻译记录数量超过读取限制。")
            }
            var ids = Set<UUID>()
            var identities = Set<RecordIdentity>()
            for record in document.records {
                try validate(record)
                guard ids.insert(record.id).inserted,
                      identities.insert(RecordIdentity(original: record.original,
                                                       targetLanguage: record.targetLanguage)).inserted else {
                    throw StorageError(message: "翻译记录文件包含重复条目。")
                }
            }
            records = try bounded(document.records)
        } catch {
            records = []
            loadingError = "无法读取本地翻译记录；原文件已保留，本次运行不会覆盖它。请备份并移走该文件后重启 App。\n" + error.localizedDescription
            lastError = loadingError
        }
    }

    private func validate(_ record: SavedTranslation) throws {
        guard !record.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.targetLanguage.isEmpty, record.createdAt.timeIntervalSince1970.isFinite else {
            throw StorageError(message: "未保存翻译记录：结果为空或记录格式无效。")
        }
    }

    private func bounded(_ values: [SavedTranslation], protecting protectedID: UUID? = nil) throws -> [SavedTranslation] {
        guard values.filter(\.isFavorite).count <= maxFavoriteEntries else {
            throw StorageError(message: "收藏已达到 \(maxFavoriteEntries) 条上限；请先删除部分收藏。此次修改未保存。")
        }
        var candidate = values
        var bytes: [UUID: Int] = [:]
        for record in candidate {
            guard let count = TranslationTextEncoding.byteCount(record), count <= maxBytes else {
                throw StorageError(message: "这条翻译超过本地记录的文本容量限制，未保存；翻译仍可正常查看。")
            }
            bytes[record.id] = count
        }
        // Sum with Int64 so custom test limits and record counts cannot overflow.
        var total = candidate.reduce(Int64(0)) { $0 + Int64(bytes[$1.id] ?? 0) }
        var historyCount = candidate.filter { !$0.isFavorite }.count
        while historyCount > maxHistoryEntries || total > Int64(maxBytes) {
            guard let index = candidate.lastIndex(where: { !$0.isFavorite && $0.id != protectedID }) else {
                throw StorageError(message: "本地记录空间不足；已有收藏保持不变，此次结果未保存。")
            }
            let removed = candidate.remove(at: index)
            total -= Int64(bytes[removed.id] ?? 0)
            historyCount -= 1
        }
        return candidate
    }

    private func commit(_ candidate: [SavedTranslation]) throws {
        let data = try TranslationTextEncoding.encoder().encode(Document(version: 1, records: candidate))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        records = candidate
        lastError = nil
        onChange?()
    }

    private func canWrite() -> Bool {
        guard let loadingError else { return true }
        lastError = loadingError
        onChange?()
        return false
    }

    private func report(_ error: Error) {
        lastError = "本地翻译记录未更新：" + error.localizedDescription
        onChange?()
    }
}
