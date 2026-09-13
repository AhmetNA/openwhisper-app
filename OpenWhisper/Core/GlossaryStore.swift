import Foundation

/// Single source of truth for reading and parsing the user's glossary file
/// (`<ApplicationSupport>/OpenWhisper/glossary.txt`). `LLMCleanup`, `WhisperTranscriber`, and
/// `PhoneticGlossaryCorrector` each used to carry their own copy of `glossaryURL` and their own
/// (near-identical, but not identical) parsing logic. Consolidated here so there is exactly one
/// place that knows the file format, and exactly one cache to reason about.
enum GlossaryStore {

    /// Path to the user's personal glossary file (symlinked to the project's sozluk.txt in dev
    /// setups — see the comment on `currentCacheKey()` for why that matters for caching).
    static var glossaryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenWhisper/glossary.txt")
    }

    /// (mtime, size) of the resolved glossary file, used to decide whether a cached parse is
    /// still valid. Both fields are compared, not mtime alone, as cheap extra insurance against
    /// a filesystem with coarse mtime resolution reporting "unchanged" across two edits that
    /// land in the same tick but change the byte count.
    private struct CacheKey: Equatable {
        let modificationDate: Date
        let size: Int
    }

    private static let lock = NSLock()
    private static var isCachePopulated = false
    private static var cachedKey: CacheKey?
    private static var cachedLines: [String] = []

    /// Reads the glossary file's current (mtime, size) through a *resolved* path. Returns nil
    /// when the file doesn't exist or its resource values can't be read.
    ///
    /// `glossaryURL` is a symlink to the repo's `sozluk.txt` in dev setups (confirmed on this
    /// machine: `~/Library/Application Support/OpenWhisper/glossary.txt` -> the repo's
    /// `sozluk.txt`). Neither `FileManager.attributesOfItem(atPath:)` nor
    /// `URL.resourceValues(forKeys:)` called directly on a symlink's own path follows the
    /// link — both report the symlink's own (essentially static) mtime/size, never the
    /// target's. A cache keyed on either would never observe an edit to the real glossary file
    /// and would silently go stale for the lifetime of the process, breaking the "edit
    /// glossary.txt, no app restart needed" guarantee this store exists to preserve. Verified
    /// empirically with a throwaway target+symlink pair: `resourceValues` read on the raw
    /// symlink path stayed byte-for-byte identical across a target-file edit, while the same
    /// call on `resolvingSymlinksInPath()` picked up the new mtime and size immediately. Do not
    /// "simplify" this by dropping `resolvingSymlinksInPath()` — that would silently reintroduce
    /// the staleness bug with no compiler or test signal.
    private static func currentCacheKey() -> CacheKey? {
        let resolved = glossaryURL.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modificationDate = values.contentModificationDate,
              let size = values.fileSize
        else {
            return nil
        }
        return CacheKey(modificationDate: modificationDate, size: size)
    }

    /// Parses raw glossary file contents into trimmed, non-empty, non-`#`-comment lines. Shared
    /// by `terms()` and `singleWordTerms()` — the latter narrows this list further rather than
    /// re-reading/re-parsing the file.
    private static func parseLines(from contents: String) -> [String] {
        contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Returns the parsed glossary lines, reloading from disk only when the file's (mtime,
    /// size) has changed since the last read (or hasn't been read yet). Must be called with
    /// `lock` held.
    private static func linesLocked() -> [String] {
        let key = currentCacheKey()
        if isCachePopulated && cachedKey == key {
            return cachedLines
        }
        let lines: [String]
        if let contents = try? String(contentsOf: glossaryURL, encoding: .utf8) {
            lines = parseLines(from: contents)
        } else {
            lines = []
        }
        isCachePopulated = true
        cachedKey = key
        cachedLines = lines
        return lines
    }

    /// Full glossary terms. Matches the original `LLMCleanup`/`WhisperTranscriber`
    /// `loadGlossaryTerms()` semantics: nil when the file is missing/unreadable OR parses to
    /// zero terms — those two cases were never distinguished by callers, so this preserves
    /// that.
    static func terms() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        let lines = linesLocked()
        return lines.isEmpty ? nil : lines
    }

    /// Single-word glossary terms only — a multi-word entry (e.g. "AI agent") can't be the
    /// target of a one-word phonetic correction. Matches the original
    /// `PhoneticGlossaryCorrector.loadSingleWordGlossaryTerms()` semantics: always returns an
    /// array (empty, not nil, when there's nothing to match), since that caller never
    /// distinguished "no glossary" from "no matches possible".
    static func singleWordTerms() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return linesLocked().filter { !$0.contains(" ") }
    }
}
