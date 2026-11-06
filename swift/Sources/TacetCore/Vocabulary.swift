import Foundation

/// The user's word list (#30): terms whisper is nudged toward through its
/// prompt. One plain-text file on the server, one entry per line, so every
/// client dictating to that server shares it and a hand edit just works.
///
/// The file is the only source of the prompt. It is re-validated on every
/// load, not only when the `/vocabulary` endpoint writes it, because anything
/// with shell access on the server (including a Claude session) can append to
/// it directly.
public struct Vocabulary: Equatable {
    public enum Line: Equatable {
        case comment(String)              // `#` lines and blank lines, kept verbatim
        case term(String)
        case invalid(String, reason: String)
    }

    public private(set) var lines: [Line]

    public init(lines: [Line] = []) { self.lines = lines }

    public var terms: [String] {
        lines.compactMap { if case .term(let t) = $0 { return t } else { return nil } }
    }

    public var ignored: [(line: String, reason: String)] {
        lines.compactMap {
            if case .invalid(let l, let r) = $0 { return (l, r) } else { return nil }
        }
    }

    // MARK: - File format

    public static func parse(_ text: String) -> Vocabulary {
        var vocabulary = Vocabulary()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            vocabulary.lines.append(vocabulary.classify(String(raw)))
        }
        // A file ending in a newline splits into a trailing empty line; drop it
        // so serialize() can add exactly one back.
        if case .comment("")? = vocabulary.lines.last { vocabulary.lines.removeLast() }
        return vocabulary
    }

    public func serialize() -> String {
        lines.map { line -> String in
            switch line {
            case .comment(let s): return s
            case .term(let t): return t
            case .invalid(let raw, _): return raw
            }
        }.joined(separator: "\n") + "\n"
    }

    private func classify(_ raw: String) -> Line {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.hasPrefix("#") { return .comment(raw) }
        if let reason = Self.termProblem(text) ?? duplicateProblem(text) {
            return .invalid(raw, reason: reason)
        }
        return .term(text)
    }

    // MARK: - Editing

    public enum AddResult: Equatable {
        case added
        case alreadyPresent
        case refused(String)
    }

    public mutating func add(_ raw: String) -> AddResult {
        let term = Self.normalizeSpaces(raw)
        if let reason = Self.termProblem(term) { return .refused(reason) }
        if duplicateProblem(term) != nil { return .alreadyPresent }
        lines.append(.term(term))
        return .added
    }

    /// Removes the term, matched case-insensitively. Returns whether it was there.
    public mutating func remove(_ raw: String) -> Bool {
        let key = Self.normalizeSpaces(raw).lowercased()
        let before = lines.count
        lines.removeAll { if case .term(let t) = $0 { return t.lowercased() == key } else { return false } }
        return lines.count != before
    }

    private func duplicateProblem(_ term: String) -> String? {
        let key = term.lowercased()
        return terms.contains { $0.lowercased() == key } ? "duplicate of an earlier entry" : nil
    }

    // MARK: - Validation

    static let maxTermLength = 64
    static let maxTermWords = 3
    static let allowedPunctuation: Set<Character> = ["-", "_", ".", "+", "#", "/", "@", ":"]

    /// Why `term` can't be a term, or nil if it can. Terms reach whisper's
    /// prompt, so they stay short and word-like: no shell metacharacters, no
    /// quotes, nothing that reads as an instruction rather than a word.
    static func termProblem(_ term: String) -> String? {
        if term.isEmpty { return "empty" }
        if term.count > maxTermLength { return "longer than \(maxTermLength) characters" }
        if term.split(separator: " ").count > maxTermWords { return "more than \(maxTermWords) words" }
        if let bad = term.first(where: { !isAllowed($0) }) {
            return "contains \"\(bad)\"; terms may use letters, digits, spaces and - _ . + # / @ :"
        }
        if !term.contains(where: { $0.isLetter || $0.isNumber }) { return "has no letters or digits" }
        return nil
    }

    private static func isAllowed(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == " " || allowedPunctuation.contains(c)
    }

    static func normalizeSpaces(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Migration from whisper.prompt

    /// The terms of a pre-#30 `whisper.prompt`. Everything after
    /// "Vocabulary:" is the list; a prompt without that marker is read as a
    /// bare comma-separated list. Pieces that aren't valid terms are kept as
    /// invalid lines so the user sees them instead of losing them silently.
    public static func migrated(fromPrompt prompt: String) -> Vocabulary {
        var list = prompt
        if let marker = prompt.range(of: "vocabulary:", options: .caseInsensitive) {
            list = String(prompt[marker.upperBound...])
        }
        var vocabulary = Vocabulary(lines: [.comment(header)])
        for piece in list.split(separator: ",") {
            var term = normalizeSpaces(String(piece))
            if term.hasSuffix(".") { term.removeLast() }
            guard !term.isEmpty else { continue }
            vocabulary.lines.append(vocabulary.classify(term))
        }
        return vocabulary
    }

    static let header = "# tacet vocabulary: one term per line. See `tacet vocab --help`."

    // MARK: - The prompt

    public struct Prompt: Equatable {
        public let text: String
        public let included: [String]       // terms in the prompt
        public let estimatedTokens: Int
    }

    /// Whisper reads at most 223 prompt tokens and silently drops the START
    /// of anything longer (whisper.cpp 1.8.4, src/whisper.cpp:6897, 7098).
    /// The count here is an estimate, so the cap is set well below that, and
    /// the most important terms go LAST so an overrun loses the least.
    ///
    /// Priority is newest first: a term was usually added because whisper had
    /// just got it wrong.
    public func prompt(preamble: String, maxTokens: Int) -> Prompt {
        var chosen: [String] = []
        for term in terms.reversed() {
            let candidate = Self.render(preamble: preamble, terms: [term] + chosen)
            if Self.estimateTokens(candidate) > maxTokens { continue }
            chosen.insert(term, at: 0)
        }
        // `chosen` is least important first, so the newest term ends up last.
        let text = chosen.isEmpty ? "" : Self.render(preamble: preamble, terms: chosen)
        return Prompt(text: text, included: chosen, estimatedTokens: Self.estimateTokens(text))
    }

    static func render(preamble: String, terms: [String]) -> String {
        let lead = preamble.isEmpty ? "" : preamble + " "
        return lead + "Vocabulary: " + terms.joined(separator: ", ") + "."
    }

    /// Characters per token for a comma-separated jargon list. Uncalibrated
    /// against whisper's tokenizer, and deliberately pessimistic: short
    /// technical words split into more tokens than prose does.
    static let charsPerToken = 2.5

    static func estimateTokens(_ text: String) -> Int {
        Int((Double(text.count) / charsPerToken).rounded(.up))
    }
}
