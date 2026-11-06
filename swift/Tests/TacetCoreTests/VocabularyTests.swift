import XCTest
@testable import TacetCore

final class VocabularyTests: XCTestCase {
    /// A pre-#30 `whisper.prompt` in the documented shape, about as long as a
    /// real one: migration must carry every term across, fit the default
    /// budget, and reproduce the same prompt text.
    static let legacyPrompt = "Technical dictation. Vocabulary: Postgres, Kubernetes, Terraform, "
        + "tmux, Redis, Nginx, GraphQL, gRPC, OAuth, Webpack, TypeScript, Rust, Go, Python, repo, PR, "
        + "schema, migration, cluster, shard, CLI, API, JSON, YAML, Docker, Claude Code, Homebrew, launchd."

    func testParseKeepsCommentsAndRoundTrips() {
        let text = "# mine\nTacet\n\nClaude Code\n"
        let v = Vocabulary.parse(text)
        XCTAssertEqual(v.terms, ["Tacet", "Claude Code"])
        XCTAssertEqual(v.serialize(), text)
    }

    func testInvalidLinesAreIgnoredButKept() {
        // A line appended by hand (or by a Claude session with a shell) is
        // held to the same rules as one added through the endpoint.
        let v = Vocabulary.parse("Tacet\necho $HOME\ntacet\n")
        XCTAssertEqual(v.terms, ["Tacet"])
        XCTAssertEqual(v.ignored.count, 2)
        XCTAssertTrue(v.ignored[0].reason.hasPrefix("contains \"$\""), v.ignored[0].reason)
        XCTAssertEqual(v.ignored[1].reason, "duplicate of an earlier entry")
        XCTAssertEqual(v.serialize(), "Tacet\necho $HOME\ntacet\n")
    }

    func testAddValidatesAndRefusesDuplicates() {
        var v = Vocabulary()
        XCTAssertEqual(v.add("  Claude   Code "), .added)
        XCTAssertEqual(v.add("claude code"), .alreadyPresent)
        XCTAssertEqual(v.add("a b c d"), .refused("more than 3 words"))
        if case .refused = v.add("$(whoami)") {} else { XCTFail("shell syntax must be refused") }
        XCTAssertEqual(v.terms, ["Claude Code"])
    }

    func testRemoveIsCaseInsensitive() {
        var v = Vocabulary.parse("Tacet\nClickHouse\n")
        XCTAssertTrue(v.remove("clickhouse"))
        XCTAssertFalse(v.remove("Postgres"))
        XCTAssertEqual(v.terms, ["Tacet"])
    }

    func testLegacyPromptMigratesCompletelyAndFits() {
        let v = Vocabulary.migrated(fromPrompt: Self.legacyPrompt)
        XCTAssertEqual(v.terms.count, 28) // "Claude Code" is one term
        XCTAssertEqual(v.terms.first, "Postgres")
        XCTAssertEqual(v.terms.last, "launchd")
        XCTAssertTrue(v.ignored.isEmpty)
        let p = v.prompt(preamble: "Technical dictation.", maxTokens: 150)
        XCTAssertEqual(p.included.count, v.terms.count, "every migrated term fits the default budget")
        XCTAssertEqual(p.text, Self.legacyPrompt, "the migrated prompt is the prompt it replaces")
    }

    func testPromptPutsNewestTermsLastAndDropsOldestOverBudget() {
        let v = Vocabulary.parse("Oldest\nMiddle\nNewest\n")
        let all = v.prompt(preamble: "", maxTokens: 150)
        XCTAssertEqual(all.text, "Vocabulary: Oldest, Middle, Newest.")
        let tight = v.prompt(preamble: "", maxTokens: Vocabulary.estimateTokens("Vocabulary: Middle, Newest."))
        XCTAssertEqual(tight.included, ["Middle", "Newest"])
    }

    func testEmptyVocabularyMeansNoPrompt() {
        XCTAssertEqual(Vocabulary().prompt(preamble: "Technical dictation.", maxTokens: 150).text, "")
    }

    func testStoreFallsBackToLegacyPromptUntilMigrated() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("vocabulary.txt")
        let store = VocabularyStore(url: url, legacyPrompt: Self.legacyPrompt)
        XCTAssertEqual(store.current().terms.count, 28, "no file yet: the legacy prompt still biases")
        XCTAssertNotNil(try store.migrateIfNeeded(preamble: "Technical dictation."))
        XCTAssertNil(try store.migrateIfNeeded(preamble: "Technical dictation."), "migrates once")
        XCTAssertEqual(store.current().terms.count, 28)
        _ = try store.update { $0.add("Tacet") }
        XCTAssertEqual(Vocabulary.parse(try String(contentsOf: url, encoding: .utf8)).terms.last, "Tacet")
    }

    func testStorePicksUpHandEdits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "Tacet\n".write(to: url, atomically: true, encoding: .utf8)
        let store = VocabularyStore(url: url)
        XCTAssertEqual(store.current().terms, ["Tacet"])
        try "Tacet\nYTS\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: url.path)
        XCTAssertEqual(store.current().terms, ["Tacet", "YTS"])
    }

    /// A stand-in for /usr/share/dict/words, so the tests don't depend on it.
    static let english = WordList { ["tacit", "remove", "sequel"].contains($0.lowercased()) }

    func testCorrectionsMustRespellWhatWasSaid() {
        // The guard on corrections (#30, D3): a rule may respell a mishearing,
        // never turn something said into something else.
        let accepted = [("replacing merge tree", "ReplacingMergeTree"), ("click house", "ClickHouse"),
                        ("a lambic", "Alembic"), ("cloud code", "Claude Code"),
                        ("cuber netties", "Kubernetes"), ("tea mux", "tmux")]
        for (from, to) in accepted {
            var v = Vocabulary()
            XCTAssertEqual(v.fix(from: from, to: to, words: Self.english), .added, "\(from) -> \(to)")
        }
        for (from, to) in [("ls", "rm -rf /"), ("of the", "rm -rf"), ("post gress", "Postgres; ls")] {
            var v = Vocabulary()
            if case .refused = v.fix(from: from, to: to, words: Self.english) {} else {
                XCTFail("\(from) -> \(to) must be refused")
            }
            XCTAssertTrue(v.corrections.isEmpty)
        }
    }

    func testAnEnglishWordTriggerBecomesATerm() {
        // "tacit -> Tacet" would also rewrite "tacit agreement".
        var v = Vocabulary()
        guard case .addedAsTerm(let why) = v.fix(from: "tacit", to: "Tacet", words: Self.english) else {
            return XCTFail("expected the replacement to be added as a term")
        }
        XCTAssertTrue(why.contains("English word"), why)
        XCTAssertEqual(v.terms, ["Tacet"])
        XCTAssertTrue(v.corrections.isEmpty)
    }

    func testCorrectRewritesWholeWordsLongestFirstInOnePass() {
        let v = Vocabulary.parse("""
            merge tree -> MergeTree
            replacing merge tree -> ReplacingMergeTree
            post gress -> Postgres
            postgres -> PostgreSQL
            """, words: Self.english)
        XCTAssertTrue(v.ignored.isEmpty, "\(v.ignored)")
        XCTAssertEqual(
            v.correct("Use Replacing  merge\ntree, not merge tree. Post gress; mergetrees stay."),
            "Use ReplacingMergeTree, not MergeTree. Postgres; mergetrees stay.")
    }

    func testHandEditedCorrectionsAreValidatedOnLoad() {
        let v = Vocabulary.parse("a lambic -> Alembic\nls -> rm -rf /\ntacit -> Tacet\n", words: Self.english)
        XCTAssertEqual(v.corrections.map(\.to), ["Alembic"])
        XCTAssertEqual(v.ignored.count, 2)
        XCTAssertTrue(v.ignored[0].reason.contains("not a respelling"), v.ignored[0].reason)
        XCTAssertTrue(v.ignored[1].reason.contains("English word"), v.ignored[1].reason)
        XCTAssertEqual(v.serialize(), "a lambic -> Alembic\nls -> rm -rf /\ntacit -> Tacet\n")
    }

    func testPromptPrefersTermsNoCorrectionCovers() {
        // Alembic is covered after decoding; Tacet has only the prompt.
        let v = Vocabulary.parse("Tacet\na lambic -> Alembic\n", words: Self.english)
        XCTAssertEqual(v.promptTerms, ["Tacet", "Alembic"])
        let one = v.prompt(preamble: "", maxTokens: Vocabulary.estimateTokens("Vocabulary: Tacet."))
        XCTAssertEqual(one.included, ["Tacet"])
    }

    func testRemoveDropsCorrectionsFromEitherSide() {
        var v = Vocabulary.parse("a lambic -> Alembic\ncuber netties -> Kubernetes\n", words: Self.english)
        XCTAssertTrue(v.remove("alembic"))
        XCTAssertTrue(v.remove("Cuber Netties"))
        XCTAssertTrue(v.corrections.isEmpty)
    }

    func testVocabCommandParsesVerbsAndCommaLists() {
        XCTAssertEqual(VocabCommand.parse([]), .list)
        XCTAssertEqual(VocabCommand.parse(["add", "ClickHouse, Tacet", "Claude Code"]),
                       .add(["ClickHouse", "Tacet", "Claude Code"]))
        XCTAssertEqual(VocabCommand.parse(["rm", "Tacet"]), .remove(["Tacet"]))
        XCTAssertEqual(VocabCommand.parse(["fix", "cuber netties", "Kubernetes"]),
                       .fix("cuber netties", "Kubernetes"))
        XCTAssertNil(VocabCommand.parse(["fix", "tacit"]))
        XCTAssertNil(VocabCommand.parse(["add"]))
        XCTAssertNil(VocabCommand.parse(["frobnicate"]))
    }
}
