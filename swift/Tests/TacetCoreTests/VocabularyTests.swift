import XCTest
@testable import TacetCore

final class VocabularyTests: XCTestCase {
    /// The maintainer's pre-#30 prompt, verbatim: migration must carry every
    /// term across and reproduce the same prompt text.
    static let legacyPrompt = "Technical dictation. Vocabulary: ClickHouse, tmux, Graphite, "
        + "Terraform, Kubernetes, Alembic, MergeTree, Tailscale, ReplacingMergeTree, Postgres, "
        + "Kafka, Claude Code, DRYCodeWorks, repo, PR, stack, migration, schema, query, cluster, "
        + "shard, partition, CLI, API, JSON, YAML, Docker, launchd."

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
        XCTAssertEqual(v.terms.first, "ClickHouse")
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

    func testVocabCommandParsesVerbsAndCommaLists() {
        XCTAssertEqual(VocabCommand.parse([]), .list)
        XCTAssertEqual(VocabCommand.parse(["add", "ClickHouse, Tacet", "Claude Code"]),
                       .add(["ClickHouse", "Tacet", "Claude Code"]))
        XCTAssertEqual(VocabCommand.parse(["rm", "Tacet"]), .remove(["Tacet"]))
        XCTAssertNil(VocabCommand.parse(["add"]))
        XCTAssertNil(VocabCommand.parse(["frobnicate"]))
    }
}
