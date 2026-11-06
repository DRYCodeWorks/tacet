import Foundation

/// `tacet vocab`: read and edit the server's vocabulary from a shell (#30).
/// This is how a Claude Code session adds words: it runs the command, and the
/// server validates every entry.
///
/// It finds the server the same way the agent does, from
/// `~/.config/tacet/client.json`; on a Mac with no client config that falls
/// back to loopback and `~/.config/tacet/key`, which is the server-only case.
public enum VocabCommand {
    public static let usage = """
    usage: tacet vocab [list]
           tacet vocab add TERM...
           tacet vocab remove TERM...

    Terms are words whisper should prefer, such as names and jargon it gets
    wrong. Quote a term with spaces ("Claude Code"); commas separate several.
    The list lives on the transcription server and changes take effect on the
    next dictation.

    """

    enum Action: Equatable {
        case list
        case add([String])
        case remove([String])
        case help
    }

    /// Exit status: 0 done, 1 something was refused or failed, 2 usage error.
    public static func run(_ args: [String],
                           out: (String) -> Void = { print($0) },
                           err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32 {
        guard let action = parse(args) else {
            err(usage)
            return 2
        }
        if action == .help {
            out(usage)
            return 0
        }
        do {
            let client = try VocabularyClient.fromClientConfig()
            let listing = try client.send(action)
            out(render(listing, action: action))
            let refused = listing.results?.contains { $0.status == "refused" } ?? false
            return refused ? 1 : 0
        } catch {
            err("tacet vocab: \(error)")
            return 1
        }
    }

    static func parse(_ args: [String]) -> Action? {
        guard let verb = args.first else { return .list }
        let terms = args.dropFirst()
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        switch verb {
        case "list": return terms.isEmpty ? .list : nil
        case "add": return terms.isEmpty ? nil : .add(terms)
        case "remove", "rm": return terms.isEmpty ? nil : .remove(terms)
        case "--help", "-h", "help": return .help
        default: return nil
        }
    }

    static func render(_ listing: VocabularyClient.Listing, action: Action) -> String {
        var lines: [String] = []
        for r in listing.results ?? [] {
            lines.append("\(r.status): \(r.entry)" + (r.reason.map { " (\($0))" } ?? ""))
        }
        let inPrompt = listing.terms.filter(\.inPrompt).count
        lines.append("Vocabulary: \(listing.terms.count) terms, \(inPrompt) in the prompt "
            + "(~\(listing.prompt.estimatedTokens) of \(listing.prompt.maxTokens) tokens).")
        if action == .list {
            lines += listing.terms.map { "  \($0.text)" + ($0.inPrompt ? "" : "  (not in the prompt: over budget)") }
        }
        if !listing.ignored.isEmpty {
            lines.append("\(listing.ignored.count) line(s) in the vocabulary file are ignored:")
            lines += listing.ignored.map { "  \($0.line)  (\($0.reason))" }
        }
        return lines.joined(separator: "\n")
    }
}

/// The HTTP side of `tacet vocab`, separate so tests can exercise rendering
/// and parsing without a server.
struct VocabularyClient {
    struct Listing: Decodable {
        struct Term: Decodable { let text: String; let inPrompt: Bool }
        struct Ignored: Decodable { let line: String; let reason: String }
        struct Budget: Decodable { let estimatedTokens: Int; let maxTokens: Int }
        struct Result: Decodable { let action: String; let entry: String; let status: String; let reason: String? }
        let terms: [Term]
        let ignored: [Ignored]
        let prompt: Budget
        let results: [Result]?
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let url: URL
    let key: String

    static func fromClientConfig() throws -> VocabularyClient {
        let config = try ClientConfig.load(defaultPort: TacetConfig.load().tacetPort)
        guard var parts = URLComponents(url: config.serverURL, resolvingAgainstBaseURL: false) else {
            throw Failure(description: "cannot read the server address \(config.serverURL)")
        }
        parts.path = "/vocabulary"
        guard let url = parts.url else { throw Failure(description: "cannot build the vocabulary URL") }
        return VocabularyClient(url: url, key: config.key)
    }

    func send(_ action: VocabCommand.Action) throws -> Listing {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(key, forHTTPHeaderField: "X-Tacet-Key")
        switch action {
        case .add(let terms): try setBody(&request, ["add": terms])
        case .remove(let terms): try setBody(&request, ["remove": terms])
        case .list, .help: request.httpMethod = "GET"
        }
        let (status, data) = try perform(request)
        guard status == 200 else { throw Failure(description: Self.detail(status, data)) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Listing.self, from: data)
    }

    private func setBody(_ request: inout URLRequest, _ body: [String: [String]]) throws {
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
    }

    private func perform(_ request: URLRequest) throws -> (Int, Data) {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<(Int, Data), Error> = .failure(Failure(description: "no response"))
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(Failure(description: "cannot reach \(url): \(error.localizedDescription)"))
            } else if let http = response as? HTTPURLResponse {
                outcome = .success((http.statusCode, data ?? Data()))
            }
            done.signal()
        }.resume()
        done.wait()
        return try outcome.get()
    }

    static func detail(_ status: Int, _ data: Data) -> String {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let detail = (obj?["detail"] as? String) ?? "no detail"
        if status == 404 {
            return "server answered 404: it predates the vocabulary list. "
                + "Update it: git pull, then ./install-server.sh on the server"
        }
        return "server answered \(status): \(detail)"
    }
}
