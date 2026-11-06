import Foundation

/// The user's word list (#30). One plain-text file on the server, one entry
/// per line, so every client dictating to that server shares it and a hand
/// edit just works. Two kinds of entry:
///
/// - a **term** (`Tacet`): whisper is nudged toward it through the prompt;
/// - a **correction** (`a lambic -> Alembic`): rewritten in the transcript
///   after decoding, for words the prompt alone doesn't fix.
///
/// The file is re-validated on every load, not only when the `/vocabulary`
/// endpoint writes it, because anything with shell access on the server
/// (including a Claude session) can append to it directly.
public struct Vocabulary: Equatable {
    public enum Line: Equatable {
        case comment(String)              // `#` lines and blank lines, kept verbatim
        case term(String)
        case correction(from: String, to: String)
        case invalid(String, reason: String)
    }

    public private(set) var lines: [Line]

    public init(lines: [Line] = []) { self.lines = lines }

    public var terms: [String] {
        lines.compactMap { if case .term(let t) = $0 { return t } else { return nil } }
    }

    public var corrections: [(from: String, to: String)] {
        lines.compactMap { if case .correction(let f, let t) = $0 { return (f, t) } else { return nil } }
    }

    public var ignored: [(line: String, reason: String)] {
        lines.compactMap {
            if case .invalid(let l, let r) = $0 { return (l, r) } else { return nil }
        }
    }

    // MARK: - File format

    static let arrow = "->"

    public static func parse(_ text: String, words: WordList = .system) -> Vocabulary {
        var vocabulary = Vocabulary()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            vocabulary.lines.append(vocabulary.classify(String(raw), words: words))
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
            case .correction(let f, let t): return "\(f) \(Self.arrow) \(t)"
            case .invalid(let raw, _): return raw
            }
        }.joined(separator: "\n") + "\n"
    }

    private func classify(_ raw: String, words: WordList) -> Line {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.hasPrefix("#") { return .comment(raw) }
        if let arrow = text.range(of: Self.arrow) {
            let from = Self.normalizeSpaces(String(text[..<arrow.lowerBound]))
            let to = Self.normalizeSpaces(String(text[arrow.upperBound...]))
            switch checkCorrection(from: from, to: to, words: words) {
            case .ok: return .correction(from: from, to: to)
            case .refused(let why), .englishWord(let why): return .invalid(raw, reason: why)
            }
        }
        if let reason = Self.termProblem(text) ?? duplicateTerm(text) {
            return .invalid(raw, reason: reason)
        }
        return .term(text)
    }

    // MARK: - Editing

    public enum AddResult: Equatable {
        case added
        case alreadyPresent
        case refused(String)
        /// The correction was refused because its trigger is an English word,
        /// and its replacement was added as a term instead.
        case addedAsTerm(String)
    }

    public mutating func add(_ raw: String) -> AddResult {
        let term = Self.normalizeSpaces(raw)
        if let reason = Self.termProblem(term) { return .refused(reason) }
        if duplicateTerm(term) != nil { return .alreadyPresent }
        lines.append(.term(term))
        return .added
    }

    public mutating func fix(from rawFrom: String, to rawTo: String, words: WordList = .system) -> AddResult {
        let from = Self.normalizeSpaces(rawFrom), to = Self.normalizeSpaces(rawTo)
        if corrections.contains(where: { $0.from.lowercased() == from.lowercased() && $0.to == to }) {
            return .alreadyPresent
        }
        switch checkCorrection(from: from, to: to, words: words) {
        case .refused(let why):
            return .refused(why)
        case .englishWord(let why):
            let kept = add(to) == .added ? "added \"\(to)\" as a term instead" : "\"\(to)\" is already a term"
            return .addedAsTerm(why + "; " + kept)
        case .ok:
            lines.append(.correction(from: from, to: to))
            return .added
        }
    }

    /// Removes every entry naming `raw`: a term, a correction from it, or a
    /// correction to it (a correction's target is an implicit term). Matching
    /// is case-insensitive. Returns whether anything was removed.
    public mutating func remove(_ raw: String) -> Bool {
        let key = Self.normalizeSpaces(raw).lowercased()
        let before = lines.count
        lines.removeAll { line in
            switch line {
            case .term(let t): return t.lowercased() == key
            case .correction(let f, let t): return f.lowercased() == key || t.lowercased() == key
            default: return false
            }
        }
        return lines.count != before
    }

    private func duplicateTerm(_ term: String) -> String? {
        let key = term.lowercased()
        return terms.contains { $0.lowercased() == key } ? "duplicate of an earlier entry" : nil
    }

    // MARK: - Validation

    static let maxTermLength = 64
    static let maxTermWords = 3
    static let allowedPunctuation: Set<Character> = ["-", "_", ".", "+", "#", "/", "@", ":"]

    /// Why `term` can't be a term, or nil if it can. Terms reach whisper's
    /// prompt and correction targets reach the pasted text, so both stay short
    /// and word-like: no shell metacharacters, no quotes, nothing that reads as
    /// an instruction rather than a word.
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

    enum CorrectionCheck: Equatable {
        case ok
        case refused(String)
        case englishWord(String)
    }

    /// The most a replacement may differ from its trigger, as a share of the
    /// longer one's letters and digits.
    static let maxRespellingDistance = 0.4

    /// A correction rewrites every later transcript, and tacet pastes into
    /// terminals, so it is bounded to *respelling what was said* (#30, D3):
    /// "cuber netties -> Kubernetes" passes, "ls -> rm -rf /" does not. A
    /// single English word can't be a trigger at all, because the rule would
    /// also fire where the user meant that word ("tacit agreement").
    func checkCorrection(from: String, to: String, words: WordList) -> CorrectionCheck {
        if let why = Self.termProblem(from) { return .refused("\"\(from)\": \(why)") }
        if let why = Self.termProblem(to) { return .refused("\"\(to)\": \(why)") }
        if from == to { return .refused("nothing to correct") }
        if corrections.contains(where: { $0.from.lowercased() == from.lowercased() }) {
            return .refused("\"\(from)\" already has a correction; remove it first")
        }
        if !from.contains(" "), words.contains(from) {
            return .englishWord("\"\(from)\" is an English word, so a correction would also rewrite it "
                + "where you meant it")
        }
        let distance = Self.respellingDistance(from, to)
        if distance > Self.maxRespellingDistance {
            return .refused("\"\(to)\" is not a respelling of \"\(from)\" "
                + "(\(Int((distance * 100).rounded()))% of letters differ; the limit is "
                + "\(Int(Self.maxRespellingDistance * 100))%)")
        }
        return .ok
    }

    /// Edit distance between the two, lowercased and stripped to letters and
    /// digits, divided by the longer length.
    static func respellingDistance(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        var previous = Array(0...y.count)
        for (i, cx) in x.enumerated() {
            var current = [i + 1]
            for (j, cy) in y.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (cx == cy ? 0 : 1)))
            }
            previous = current
        }
        return Double(previous[y.count]) / Double(longest)
    }

    // MARK: - Applying corrections

    /// Rewrite every correction trigger in `text`: whole words only,
    /// case-insensitive, any whitespace between a trigger's words. Longest
    /// triggers win, and the text is scanned once, so one rule's output is
    /// never fed to another.
    public func correct(_ text: String) -> String {
        let rules = corrections.sorted { $0.from.count > $1.from.count }
        guard !rules.isEmpty, let regex = Self.triggerPattern(rules.map(\.from)) else { return text }
        let replacement = Dictionary(rules.map { ($0.from.lowercased(), $0.to) },
                                     uniquingKeysWith: { first, _ in first })
        var out = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let found = String(text[range])
            out += text[last..<range.lowerBound]
            out += replacement[Self.normalizeSpaces(found).lowercased()] ?? found
            last = range.upperBound
        }
        return out + text[last...]
    }

    private static func triggerPattern(_ triggers: [String]) -> NSRegularExpression? {
        let alternatives = triggers.map { trigger in
            trigger.split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
        }
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
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
            vocabulary.lines.append(vocabulary.classify(term, words: WordList { _ in false }))
        }
        return vocabulary
    }

    static let header = "# tacet vocabulary: a term, or `wrong -> Right`, per line. See `tacet vocab --help`."

    // MARK: - The prompt

    public struct Prompt: Equatable {
        public let text: String
        public let included: [String]       // terms in the prompt
        public let estimatedTokens: Int
    }

    /// Everything whisper should be nudged toward, in file order: the terms,
    /// then correction targets that aren't already terms.
    public var promptTerms: [String] {
        var seen = Set(terms.map { $0.lowercased() })
        var all = terms
        for (_, to) in corrections where seen.insert(to.lowercased()).inserted {
            all.append(to)
        }
        return all
    }

    /// Whisper reads at most 223 prompt tokens and silently drops the START
    /// of anything longer (whisper.cpp 1.8.4, src/whisper.cpp:6897, 7098).
    /// The count here is an estimate, so the cap is set well below that, and
    /// the most important terms go LAST so an overrun loses the least.
    ///
    /// Priority: terms no correction covers come first, because the prompt is
    /// their only help (a homophone like "Tacet" is exactly this case). Within
    /// each group, newest first: a term was usually added because whisper had
    /// just got it wrong.
    public func prompt(preamble: String, maxTokens: Int) -> Prompt {
        let covered = Set(corrections.map { $0.to.lowercased() })
        let newestFirst = promptTerms.reversed()
        let priority = newestFirst.filter { !covered.contains($0.lowercased()) }
            + newestFirst.filter { covered.contains($0.lowercased()) }
        var chosen: [String] = []
        for term in priority {
            let candidate = Self.render(preamble: preamble, terms: [term] + chosen)
            if Self.estimateTokens(candidate) > maxTokens { continue }
            chosen.insert(term, at: 0)
        }
        // `chosen` is least important first, so the most important term ends up last.
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

/// English words, for refusing corrections whose trigger is one (#30, D3).
/// `/usr/share/dict/words` ships with macOS and needs no AppKit, which a
/// launchd job has no session for.
public struct WordList {
    let contains: (String) -> Bool

    public init(contains: @escaping (String) -> Bool) { self.contains = contains }

    public static let system: WordList = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else {
            // Fail closed: with no dictionary, every single word counts as
            // English, so only multi-word triggers can become corrections.
            return WordList { _ in true }
        }
        let words = Set(text.split(separator: "\n").map { $0.lowercased() })
        return WordList { words.contains($0.lowercased()) }
    }()
}
