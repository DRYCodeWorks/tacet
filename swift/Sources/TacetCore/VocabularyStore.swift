import Foundation

/// The vocabulary file on disk, shared by every request the server handles.
///
/// Reads re-check the file's modification time, so a hand edit takes effect
/// on the next dictation with no restart. Writes go through `update`, which
/// re-reads the file first so an edit made by hand since the last read is
/// never overwritten, then replaces it atomically.
public final class VocabularyStore {
    public let url: URL
    /// The pre-#30 `whisper.prompt`. Used only while no vocabulary file exists,
    /// so an upgraded server keeps its biasing before migration has run.
    let legacyPrompt: String
    private let lock = NSLock()
    private var cached = Vocabulary()
    private var cachedModified: Date?

    public init(url: URL, legacyPrompt: String = "") {
        self.url = url
        self.legacyPrompt = legacyPrompt
    }

    public func current() -> Vocabulary {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// Apply `change` to the freshest copy of the file and save the result.
    public func update<T>(_ change: (inout Vocabulary) -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var vocabulary = loadLocked()
        let result = change(&vocabulary)
        try saveLocked(vocabulary)
        return result
    }

    /// Write the legacy prompt's terms to a new file, once. Returns a log line
    /// describing what happened, or nil when there was nothing to migrate.
    public func migrateIfNeeded(preamble: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !FileManager.default.fileExists(atPath: url.path),
              !legacyPrompt.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let vocabulary = Vocabulary.migrated(fromPrompt: legacyPrompt)
        try saveLocked(vocabulary)
        var note = "migrated \(vocabulary.terms.count) terms from whisper.prompt to \(url.path)"
        if let lead = legacyPreamble, lead != preamble {
            note += "; its preamble \"\(lead)\" differs from [vocabulary] preamble \"\(preamble)\", "
                + "set that to keep it"
        }
        return note
    }

    private var legacyPreamble: String? {
        guard let marker = legacyPrompt.range(of: "vocabulary:", options: .caseInsensitive) else { return nil }
        return Vocabulary.normalizeSpaces(String(legacyPrompt[..<marker.lowerBound]))
    }

    // MARK: - Locked helpers

    private func loadLocked() -> Vocabulary {
        guard let modified = modificationDate() else {
            // No file yet: fall back to the legacy prompt rather than to
            // nothing, so biasing survives until migration writes the file.
            return legacyPrompt.isEmpty ? Vocabulary() : Vocabulary.migrated(fromPrompt: legacyPrompt)
        }
        if modified != cachedModified, let text = try? String(contentsOf: url, encoding: .utf8) {
            cached = Vocabulary.parse(text)
            cachedModified = modified
        }
        return cached
    }

    private func saveLocked(_ vocabulary: Vocabulary) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(vocabulary.serialize().utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        cached = vocabulary
        cachedModified = modificationDate()
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
