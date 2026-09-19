import Foundation

private struct TranslationStorageFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct TranslationStorageRegression {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TranslationStorageFailure(description: message) }
    }

    static func record(_ original: String, text: String = "翻译结果", target: String = "zh-CN",
                       favorite: Bool = false, dictionary: DictionaryEntry? = nil) -> SavedTranslation {
        SavedTranslation(original: original, targetLanguage: target, translatedText: text,
                         dictionary: dictionary, requestedModel: "test-model", returnedModel: "actual-model",
                         endpointHost: "api.example.test", createdAt: Date(timeIntervalSince1970: 1_000),
                         isFavorite: favorite)
    }

    static func key(_ original: String, target: String = "zh-CN", profile: String = "profile-a",
                    endpoint: String = "https://api.example.test/v1", model: String = "test-model") -> TranslationCacheKey {
        TranslationCacheKey(original: original, targetLanguage: target, profileID: profile,
                            endpoint: endpoint, model: model)
    }

    static func encodedBytes<T: Encodable>(_ value: T) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value).count
    }

    static func main() throws {
        let defaults = TranslationCache()
        try check(defaults.maxEntries == 200 && defaults.maxBytes == 5_000_000,
                  "The default memory cache must have both the advertised limits")
        let a = record("alpha"), b = record("bravo"), c = record("charlie")
        let cache = TranslationCache(maxEntries: 2)
        cache.insert(a, for: key("alpha"))
        cache.insert(b, for: key("bravo"))
        try check(cache.value(for: key("alpha")) == a, "A cache hit must return the complete saved result")
        cache.insert(c, for: key("charlie"))
        try check(cache.value(for: key("bravo")) == nil && cache.count == 2,
                  "Reading an older entry must protect it when the least recently used entry is evicted")
        try check(cache.value(for: key("alpha", target: "ar")) == nil
                  && cache.value(for: key("alpha", profile: "profile-b")) == nil
                  && cache.value(for: key("alpha", endpoint: "https://relay.example.test")) == nil
                  && cache.value(for: key("alpha", model: "other-model")) == nil,
                  "Different languages, profiles, endpoints and models must never reuse another result")

        let unicode = record("語🤖عربي", text: "含引号\"与换行\n한국어😀")
        let unicodeKey = key(unicode.original)
        let byteCount = try encodedBytes(unicodeKey) + encodedBytes(unicode)
        let exact = TranslationCache(maxEntries: 10, maxBytes: byteCount)
        exact.insert(unicode, for: unicodeKey)
        try check(exact.count == 1 && exact.totalBytes == byteCount,
                  "The text budget must count exact UTF-8 JSON bytes, including escaping and metadata")
        exact.configure(maxEntries: 10, maxBytes: byteCount - 1)
        try check(exact.count == 0 && exact.totalBytes == 0,
                  "Reducing the byte limit must immediately evict entries above the new limit")
        exact.insert(unicode, for: unicodeKey)
        try check(exact.count == 0, "An individually oversized entry must not be cached")
        exact.configure(maxEntries: 10, maxBytes: byteCount)
        exact.insert(unicode, for: unicodeKey)
        var bigger = unicode
        bigger.translatedText += String(repeating: "更多文字", count: 100)
        exact.insert(bigger, for: unicodeKey)
        try check(exact.value(for: unicodeKey) == nil && exact.totalBytes == 0,
                  "An oversized replacement must also discard the stale previous value")

        cache.configure(maxEntries: 1, maxBytes: 5_000_000)
        try check(cache.count == 1, "Reducing the count limit must immediately enforce it")
        cache.removeAll()
        try check(cache.count == 0 && cache.totalBytes == 0, "Clearing the cache releases all counted text")
        cache.configure(maxEntries: 0, maxBytes: 5_000_000)
        cache.insert(a, for: key(a.original))
        try check(cache.count == 0, "A zero entry limit disables caching")

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("HuaciTranslationStorage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        func file(_ name: String) -> URL { temporary.appendingPathComponent(name + ".json") }

        let dictionary = DictionaryEntry(sourceLanguage: "en", pronunciation: nil,
            senses: [.init(partOfSpeech: "noun", meaning: "苹果")],
            collocations: [.init(text: "apple tree", translation: "苹果树")],
            examples: [.init(text: "I ate an apple.", translation: "我吃了一个苹果。")])
        let historyURL = file("history")
        let history = TranslationHistoryStore(fileURL: historyURL, maxHistoryEntries: 2,
                                               maxFavoriteEntries: 1)
        let apple = record("apple", text: "apple\n音标未提供\n名词：苹果\napple tree：苹果树", dictionary: dictionary)
        history.add(apple)
        history.toggleFavorite(id: apple.id)
        var replacement = record("apple", text: "更新的完整词典解释", dictionary: dictionary)
        replacement.createdAt = Date(timeIntervalSince1970: 2_000)
        history.add(replacement)
        try check(history.records.count == 1 && history.records[0].id == apple.id
                  && history.records[0].isFavorite && history.records[0].translatedText == replacement.translatedText
                  && history.records[0].createdAt == replacement.createdAt,
                  "Repeated queries must update the text/date while preserving the favorite and stable identity")
        history.add(a)
        history.add(b)
        history.add(c)
        try check(history.records.count == 3 && !history.records.contains(where: { $0.id == a.id })
                  && history.records.contains(where: { $0.id == apple.id && $0.isFavorite }),
                  "History count eviction must discard old nonfavorites while preserving favorites")
        let beforeLimit = try Data(contentsOf: historyURL)
        history.toggleFavorite(id: c.id)
        let afterLimit = try Data(contentsOf: historyURL)
        try check(history.lastError != nil && history.records.first(where: { $0.id == c.id })?.isFavorite == false
                  && afterLimit == beforeLimit,
                  "Reaching the favorite limit must report failure without deleting another favorite or changing disk")
        history.clearHistory()
        try check(history.records.count == 1 && history.records[0].id == apple.id && history.lastError == nil,
                  "Clear history must retain favorites and a successful save clears the previous error")
        let reloaded = TranslationHistoryStore(fileURL: historyURL)
        try check(reloaded.records == history.records && reloaded.records[0].dictionary == dictionary,
                  "Favorites and structured dictionaries, including nil pronunciation, must survive a disk round trip")
        try check(reloaded.maxHistoryEntries == 200 && reloaded.maxFavoriteEntries == 1_000
                  && reloaded.maxBytes == 20_000_000,
                  "Local history defaults must limit nonfavorites, favorites and text size independently")
        reloaded.clearAll()
        try check(reloaded.records.isEmpty && TranslationHistoryStore(fileURL: historyURL).records.isEmpty,
                  "Explicit clear-all must remove favorites as well as recent history")

        // With automatic history disabled, the visible new result B can coexist
        // with an old result A on disk. Favoriting must save B, not toggle A.
        let explicitFavoriteURL = file("explicit-favorite")
        let explicitFavorite = TranslationHistoryStore(fileURL: explicitFavoriteURL,
                                                        maxFavoriteEntries: 1)
        let oldVisible = record("shared original", text: "旧译文 A")
        explicitFavorite.add(oldVisible)
        var newVisible = record("shared original", text: "新译文 B", dictionary: dictionary)
        newVisible.createdAt = Date(timeIntervalSince1970: 3_000)
        newVisible.requestedModel = "new-requested-model"
        newVisible.returnedModel = "new-returned-model"
        newVisible.endpointHost = "new.example.test"
        explicitFavorite.saveFavorite(newVisible, isFavorite: true)
        var expectedFavorite = newVisible
        expectedFavorite.id = oldVisible.id
        expectedFavorite.isFavorite = true
        try check(explicitFavorite.records == [expectedFavorite]
                  && explicitFavorite.lastError == nil,
                  "Explicit favorite must upsert the complete currently visible result while retaining the old identity")
        let savedFavorite = TranslationHistoryStore(fileURL: explicitFavoriteURL)
        try check(savedFavorite.records == [expectedFavorite],
                  "The new visible result and favorite state must be persisted together")

        let otherOld = record("another original", text: "另一条旧译文")
        explicitFavorite.add(otherOld)
        let beforeFavoriteLimit = explicitFavorite.records
        let diskBeforeFavoriteLimit = try Data(contentsOf: explicitFavoriteURL)
        let otherNew = record("another original", text: "尚未保存的新译文", dictionary: dictionary)
        explicitFavorite.saveFavorite(otherNew, isFavorite: true)
        let diskAfterFavoriteLimit = try Data(contentsOf: explicitFavoriteURL)
        try check(explicitFavorite.records == beforeFavoriteLimit && explicitFavorite.lastError != nil
                  && diskAfterFavoriteLimit == diskBeforeFavoriteLimit,
                  "An explicit favorite exceeding the limit must not partly replace text, metadata or favorite state")

        var latestVisible = newVisible
        latestVisible.translatedText = "取消收藏时显示的最新译文 C"
        explicitFavorite.saveFavorite(latestVisible, isFavorite: false)
        try check(explicitFavorite.records.first?.id == oldVisible.id
                  && explicitFavorite.records.first?.translatedText == latestVisible.translatedText
                  && explicitFavorite.records.first?.isFavorite == false,
                  "Explicitly removing a favorite must also save the current result and retain its stable identity")

        let favorite = record("favorite", text: String(repeating: "⭐️", count: 40), favorite: true)
        let newest = record("newest", text: "最新结果")
        let budget = try encodedBytes(favorite) + encodedBytes(newest)
        let limited = TranslationHistoryStore(fileURL: file("budget"), maxHistoryEntries: 20,
                                               maxFavoriteEntries: 10, maxBytes: budget)
        limited.add(favorite)
        limited.add(a)
        limited.add(newest)
        try check(limited.records.count == 2 && limited.records.contains(where: { $0.id == favorite.id })
                  && limited.records.contains(where: { $0.id == newest.id }),
                  "The text budget must evict nonfavorite history before touching favorites")
        var tooBig = record("too-big", text: String(repeating: "大", count: budget))
        let beforeOversize = limited.records
        limited.add(tooBig)
        try check(limited.records == beforeOversize && limited.lastError != nil,
                  "Oversized history results must report that they were not saved and preserve existing entries")
        tooBig.translatedText = String(repeating: "x", count: budget / 2)
        limited.add(tooBig)
        try check(limited.records == beforeOversize && limited.lastError != nil,
                  "A result that cannot coexist with favorites must fail without losing either favorites or old history")

        let languages = TranslationHistoryStore(fileURL: file("languages"))
        languages.add(apple)
        let arabic = record("apple", text: "تفاحة", target: "ar")
        languages.add(arabic)
        try check(languages.records.count == 2 && languages.records.map(\.targetLanguage) == ["ar", "zh-CN"],
                  "The same original queried in two target languages must retain two distinct history entries")

        // Replace the history directory with an ordinary file after one good
        // save. This reliably makes the next atomic write fail without relying
        // on chmod behavior under a privileged test runner.
        let folder = temporary.appendingPathComponent("writable", isDirectory: true)
        let rollbackURL = folder.appendingPathComponent("history.json")
        let rollback = TranslationHistoryStore(fileURL: rollbackURL)
        rollback.add(a)
        let originalDisk = try Data(contentsOf: rollbackURL)
        let moved = temporary.appendingPathComponent("saved-original", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        try Data("blocks-directory-creation".utf8).write(to: folder)
        rollback.add(b)
        try check(rollback.records == [a] && rollback.lastError != nil,
                  "Failed disk writes must roll back the visible history rather than pretend the result was saved")
        let diskAfterFailure = try Data(contentsOf: moved.appendingPathComponent("history.json"))
        try check(diskAfterFailure == originalDisk,
                  "The previously saved file must survive a failed mutation unchanged")

        let corruptURL = file("corrupt")
        let corruptData = Data("{ broken, private user history".utf8)
        try corruptData.write(to: corruptURL)
        let corrupt = TranslationHistoryStore(fileURL: corruptURL)
        try check(corrupt.records.isEmpty && corrupt.lastError != nil, "Unreadable history must report a load error")
        corrupt.add(a)
        corrupt.clearAll()
        let preservedCorruptData = try Data(contentsOf: corruptURL)
        try check(corrupt.records.isEmpty && corrupt.lastError != nil
                  && preservedCorruptData == corruptData,
                  "A corrupt original file must not be silently overwritten by new queries or clear-all")

        let oversizedURL = file("oversized")
        let oversizedData = Data(repeating: 32, count: 65_637)
        try oversizedData.write(to: oversizedURL)
        let oversized = TranslationHistoryStore(fileURL: oversizedURL, maxBytes: 100)
        try check(oversized.records.isEmpty && oversized.lastError != nil,
                  "The load size bound must reject oversized files before decoding records")

        print("Translation cache and local history checks passed; temporary files only, no network or credentials used.")
    }
}
