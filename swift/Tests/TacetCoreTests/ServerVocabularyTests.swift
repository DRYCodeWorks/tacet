import XCTest
@testable import TacetCore

final class ServerVocabularyTests: XCTestCase {
    private var server: TacetServer!
    private var whisper: StubWhisper!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        // A temp file, never ~/.config/tacet (#20).
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("vocabulary.txt")
        makeServer(legacyPrompt: "")
    }

    private func makeServer(legacyPrompt: String) {
        whisper = StubWhisper(.success("hello world"))
        server = TacetServer(config: TacetConfig(), key: "testkey", whisper: whisper,
                             vocabulary: VocabularyStore(url: fileURL, legacyPrompt: legacyPrompt),
                             logger: Logger(label: "test"))
    }

    private func edit(_ json: String, key: String = "testkey",
                      contentType: String = "application/json") -> HTTPResponse {
        server.dispatch(HTTPRequest(method: "POST", target: "/vocabulary",
                                    headers: ["x-tacet-key": key, "content-type": contentType],
                                    body: Data(json.utf8)))
    }

    private func list(key: String = "testkey") -> HTTPResponse {
        server.dispatch(HTTPRequest(method: "GET", target: "/vocabulary",
                                    headers: ["x-tacet-key": key], body: Data()))
    }

    private func json(_ resp: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]) ?? [:]
    }

    private func dictate() -> HTTPResponse {
        server.dispatch(HTTPRequest(method: "POST", target: "/dictate",
                                    headers: ["x-tacet-key": "testkey", "content-type": "audio/wav"],
                                    body: WAVFixtures.loudWAV()))
    }

    func testBothRoutesRequireTheKey() {
        XCTAssertEqual(list(key: "wrong").status, 401)
        XCTAssertEqual(edit("{\"add\":[\"Tacet\"]}", key: "wrong").status, 401)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEditRequiresJSON() {
        // text/plain is CORS-safelisted; accepting it would let a page write here.
        XCTAssertEqual(edit("{\"add\":[\"Tacet\"]}", contentType: "text/plain").status, 415)
        XCTAssertEqual(edit("not json").status, 400)
        XCTAssertEqual(edit("{}").status, 400)
    }

    func testAddReportsEachEntryAndPersists() {
        let resp = edit("{\"add\":[\"Tacet\",\"Tacet\",\"rm -rf ~\"]}")
        XCTAssertEqual(resp.status, 200)
        let results = json(resp)["results"] as? [[String: Any]] ?? []
        XCTAssertEqual(results.map { $0["status"] as? String }, ["added", "already present", "refused"])
        let saved = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(Vocabulary.parse(saved).terms, ["Tacet"])
    }

    func testDictationSendsTheVocabularyAsThePrompt() {
        _ = edit("{\"add\":[\"Tacet\"]}")
        XCTAssertEqual(dictate().status, 200)
        XCTAssertEqual(whisper.prompts, ["Technical dictation. Vocabulary: Tacet."])
    }

    func testNoVocabularySendsAnEmptyPrompt() {
        XCTAssertEqual(dictate().status, 200)
        XCTAssertEqual(whisper.prompts, [""])
    }

    func testLegacyPromptKeepsBiasingBeforeMigration() {
        // An upgraded server whose plist still carries --prompt and that has
        // no vocabulary file yet: the empty per-request prompt would override
        // the flag, so the store must serve the legacy terms instead.
        makeServer(legacyPrompt: VocabularyTests.legacyPrompt)
        XCTAssertEqual(dictate().status, 200)
        XCTAssertEqual(whisper.prompts, [VocabularyTests.legacyPrompt])
    }

    func testListMarksTermsOutsideTheBudget() {
        _ = edit("{\"add\":[\"Tacet\"]}")
        let body = json(list())
        let terms = body["terms"] as? [[String: Any]] ?? []
        XCTAssertEqual(terms.first?["text"] as? String, "Tacet")
        XCTAssertEqual(terms.first?["in_prompt"] as? Bool, true)
        XCTAssertNotNil((body["prompt"] as? [String: Any])?["max_tokens"])
    }
}
