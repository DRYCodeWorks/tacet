import Foundation

/// `GET` and `POST /vocabulary` (#30): read and edit the word list that
/// biases every later transcript.
///
/// Editing the list changes what future dictations type, which is new
/// authority for a key holder, so both routes require the key, and POST also
/// requires `application/json` (a browser can't send that cross-site without
/// a preflight, which fails). Validation lives in `Vocabulary`, not here, so a
/// hand-edited file is held to the same rules.
extension TacetServer {
    struct VocabularyEdit: Decodable {
        struct Fix: Decodable { let from: String; let to: String }
        let add: [String]?
        let fix: [Fix]?
        let remove: [String]?
    }

    struct EditResult: Encodable {
        let action: String
        let entry: String
        let status: String
        let reason: String?
    }

    struct VocabularyListing: Encodable {
        struct Term: Encodable { let text: String; let inPrompt: Bool }
        struct Correction: Encodable { let from: String; let to: String }
        struct Ignored: Encodable { let line: String; let reason: String }
        struct Budget: Encodable { let estimatedTokens: Int; let maxTokens: Int }
        let terms: [Term]
        let corrections: [Correction]
        let ignored: [Ignored]
        let prompt: Budget
        var results: [EditResult]?
    }

    static let maxEditsPerRequest = 1000

    func vocabularyList(_ request: HTTPRequest) -> HTTPResponse {
        if let refusal = rejectUnauthenticated(request) { return refusal }
        return encode(listing(vocabulary.current()))
    }

    func vocabularyEdit(_ request: HTTPRequest) -> HTTPResponse {
        if let refusal = rejectUnauthenticated(request) { return refusal }
        guard Self.mediaType(request) == "application/json" else {
            return jsonError(415, "expected Content-Type: application/json")
        }
        guard let edit = try? JSONDecoder().decode(VocabularyEdit.self, from: request.body) else {
            return jsonError(400, "expected a JSON object with \"add\", \"fix\" and/or \"remove\" lists")
        }
        let count = (edit.add?.count ?? 0) + (edit.fix?.count ?? 0) + (edit.remove?.count ?? 0)
        guard count > 0, count <= Self.maxEditsPerRequest else {
            return jsonError(400, "send between 1 and \(Self.maxEditsPerRequest) entries")
        }
        do {
            let (results, updated) = try vocabulary.update { v -> ([EditResult], Vocabulary) in
                let results = Self.apply(edit, to: &v, words: vocabulary.words)
                return (results, v)
            }
            logger.info("vocabulary edited: \(results.map { "\($0.action) \($0.status)" }.joined(separator: ", "))")
            var body = listing(updated)
            body.results = results
            return encode(body)
        } catch {
            logger.error("could not write \(vocabulary.url.path): \(error)")
            return jsonError(500, "could not save the vocabulary: \(error)")
        }
    }

    static func apply(_ edit: VocabularyEdit, to v: inout Vocabulary, words: WordList) -> [EditResult] {
        var results = (edit.add ?? []).map { term in
            result("add", term, v.add(term))
        }
        for fix in edit.fix ?? [] {
            results.append(result("fix", "\(fix.from) -> \(fix.to)", v.fix(from: fix.from, to: fix.to, words: words)))
        }
        for term in edit.remove ?? [] {
            let status = v.remove(term) ? "removed" : "not found"
            results.append(EditResult(action: "remove", entry: term, status: status, reason: nil))
        }
        return results
    }

    private static func result(_ action: String, _ entry: String, _ outcome: Vocabulary.AddResult) -> EditResult {
        switch outcome {
        case .added: return EditResult(action: action, entry: entry, status: "added", reason: nil)
        case .alreadyPresent: return EditResult(action: action, entry: entry, status: "already present", reason: nil)
        case .refused(let why): return EditResult(action: action, entry: entry, status: "refused", reason: why)
        case .addedAsTerm(let why):
            return EditResult(action: action, entry: entry, status: "added as a term", reason: why)
        }
    }

    func listing(_ v: Vocabulary) -> VocabularyListing {
        let prompt = v.prompt(preamble: config.vocabularyPreamble, maxTokens: config.maxPromptTokens)
        let included = Set(prompt.included)
        return VocabularyListing(
            terms: v.promptTerms.map { .init(text: $0, inPrompt: included.contains($0)) },
            corrections: v.corrections.map { .init(from: $0.from, to: $0.to) },
            ignored: v.ignored.map { .init(line: $0.line, reason: $0.reason) },
            prompt: .init(estimatedTokens: prompt.estimatedTokens, maxTokens: config.maxPromptTokens),
            results: nil)
    }

    /// JSONEncoder, not the hand-rolled `jsonText`: an ignored line can hold
    /// anything a user typed, including control characters, and only a real
    /// encoder escapes all of them.
    func encode<T: Encodable>(_ value: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let body = try? encoder.encode(value) else {
            return jsonError(500, "could not encode the response")
        }
        return HTTPResponse(status: 200, contentType: "application/json", body: body)
    }
}
