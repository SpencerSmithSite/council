// The Swift side of shared/golden/prompts/prompts.json: what the Flutter chat
// screen sends a backend (lib/src/services/inference/chat_prompt.dart),
// reproduced by CouncilCore/Inference/ChatPrompt.swift. The Flutter side
// writes and checks the same file in test/chat_prompt_golden_test.dart; the
// README beside the fixture documents the format.
//
// Strings are compared by UTF-16 code unit, because Swift's `==` would accept
// an NFC/NFD difference that Dart would not, and several cases are about
// exactly that.

import Foundation
import Testing
@testable import CouncilCore

struct GoldenPromptFile: Decodable {
    let system: String
    let cases: [GoldenPromptCase]
}

struct GoldenPromptCase: Decodable, Sendable, CustomTestStringConvertible {
    struct Pinned: Decodable, Sendable {
        let contentUnitId: Int
        let quote: String
        let reference: String
        let sourceTitle: String?
    }

    struct Retrieved: Decodable, Sendable {
        let id: Int
        let content: String
        let sourceTitle: String?
        let sourceAuthor: String?
        let tradition: String?
        let sourceURL: String?

        enum CodingKeys: String, CodingKey {
            case id, content, tradition
            case sourceTitle = "source_title"
            case sourceAuthor = "source_author"
            case sourceURL = "source_url"
        }
    }

    struct StoredCitation: Decodable, Sendable {
        let contentId: Int
        let source: String
        let author: String?
        let tradition: String?
        let sourceUrl: String?
    }

    let id: String
    let question: String
    let contextBudgetChars: Int
    let pinned: Pinned?
    let retrieved: [Retrieved]
    let perPassage: Int
    let prompt: String
    let citations: [StoredCitation]
    let citationsJson: String
    let traceable: [Bool]

    var testDescription: String { id }

    var pinnedPassage: PinnedPassage? {
        pinned.map {
            PinnedPassage(contentUnitId: $0.contentUnitId, quote: $0.quote, reference: $0.reference,
                          sourceTitle: $0.sourceTitle)
        }
    }

    /// The rows as `Retrieval.searchForRAG` would return them; only the
    /// columns the prompt reads are set.
    var rows: [ContentUnitRow] {
        retrieved.map {
            ContentUnitRow(id: $0.id, sourceId: nil, unitType: nil, unitNumber: nil, title: nil,
                           content: $0.content, parentId: nil, sequence: nil, provenance: nil,
                           sourceTitle: $0.sourceTitle, sourceAuthor: $0.sourceAuthor, dateComposed: nil,
                           sourceURL: $0.sourceURL, license: nil, tradition: $0.tradition, sourceType: nil,
                           rank: nil)
        }
    }
}

enum GoldenPrompts {
    static let file: GoldenPromptFile = {
        do {
            let data = try Data(contentsOf: Repo.golden("prompts/prompts.json"))
            return try JSONDecoder().decode(GoldenPromptFile.self, from: data)
        } catch {
            fatalError("Can't read shared/golden/prompts/prompts.json: \(error)")
        }
    }()
}

@Suite struct ChatPromptGoldenTests {
    @Test func theSystemPromptIsDartsVerbatim() {
        #expect(DartText.equal(ChatPrompt.systemPrompt, GoldenPrompts.file.system))
    }

    @Test(arguments: GoldenPrompts.file.cases)
    func prompt(_ golden: GoldenPromptCase) throws {
        let built = try #require(ChatPrompt(question: golden.question, retrieved: golden.rows,
                                            pinned: golden.pinnedPassage,
                                            contextBudgetChars: golden.contextBudgetChars))
        let count = golden.retrieved.count + (golden.pinned == nil ? 0 : 1)
        #expect(ChatPrompt.perPassageBudget(contextBudgetChars: golden.contextBudgetChars, passageCount: count)
            == golden.perPassage)
        #expect(DartText.equal(built.system, GoldenPrompts.file.system))
        if !DartText.equal(built.prompt, golden.prompt) {
            Issue.record("prompt differs from the fixture \(Self.firstDifference(built.prompt, golden.prompt))")
        }

        try #require(built.citations.count == golden.citations.count)
        for (citation, expected) in zip(built.citations, golden.citations) {
            #expect(citation.contentId == expected.contentId)
            #expect(DartText.equal(citation.source, expected.source))
            #expect(citation.author == expected.author)
            #expect(citation.tradition == expected.tradition)
            #expect(citation.sourceURL == expected.sourceUrl)
        }
        #expect(built.citations.map(\.isTraceable) == golden.traceable)
        #expect(DartText.equal(Citation.jsonText(built.citations), golden.citationsJson),
                "stored citation JSON must be byte-for-byte what jsonEncode writes")
        #expect(DartText.equal(ChatPrompt.citations(retrieved: golden.rows, pinned: golden.pinnedPassage)
                    .map(\.promptLabel).joined(separator: "|"),
                built.citations.map(\.promptLabel).joined(separator: "|")))
    }

    /// Where two prompts part, for a readable failure.
    static func firstDifference(_ a: String, _ b: String) -> String {
        let x = Array(a.utf16), y = Array(b.utf16)
        let at = (0..<min(x.count, y.count)).first { x[$0] != y[$0] } ?? min(x.count, y.count)
        func around(_ units: [UInt16]) -> String {
            String(decoding: units[max(0, at - 30)..<min(units.count, at + 30)], as: UTF16.self).debugDescription
        }
        return "at code unit \(at) (lengths \(x.count) and \(y.count)): \(around(x)) vs \(around(y))"
    }
}

/// `ChatPrompt` and `Citation` beyond what the fixture records.
@Suite struct ChatPromptTests {
    @Test func nothingToBuildFromIsNil() {
        #expect(ChatPrompt(question: "anything", retrieved: [], pinned: nil, contextBudgetChars: 4000) == nil)
        #expect(ChatPrompt.citations(retrieved: [], pinned: nil).isEmpty)
    }

    @Test(arguments: [
        (4000, 3, 1333), (4000, 6, 666), (0, 2, 400), (2399, 6, 400), (2400, 6, 400), (2406, 6, 401),
        (12000, 6, 2000), (60000, 1, 8000), (60000, 7, 8000), (56000, 7, 8000), (55999, 7, 7999), (-5, 1, 400),
    ])
    func perPassageBudget(_ budget: Int, _ count: Int, _ expected: Int) {
        #expect(ChatPrompt.perPassageBudget(contextBudgetChars: budget, passageCount: count) == expected)
    }

    @Test func truncationCountsCodeUnitsAndTrimsWithDartsSet() {
        #expect(ChatPrompt.truncated("abcdef", to: 6) == "abcdef")
        #expect(ChatPrompt.truncated("abcdefg", to: 6) == "abcdef… [truncated]")
        #expect(ChatPrompt.truncated("abc \u{85}\u{3000}defg", to: 6) == "abc… [truncated]")
        // A cut through a surrogate pair leaves U+FFFD, as the UTF-8 a
        // backend receives from the Dart app does.
        #expect(ChatPrompt.truncated("abcde𝔊z", to: 6) == "abcde\u{FFFD}… [truncated]")
    }
}

@Suite struct CitationTests {
    @Test func jsonIsWhatDartsJsonEncodeWrites() {
        let citations = [
            Citation(contentId: 42, source: "On Grace and Free Will"),
            Citation(contentId: 7, source: "Q \"x\" \\ / \t\n\u{1}", author: "Augustine", tradition: "Catholic",
                     sourceURL: "https://example.org/a?b=c"),
        ]
        #expect(Citation.jsonText(citations) == """
            [{"contentId":42,"source":"On Grace and Free Will","author":null,"tradition":null,"sourceUrl":null},\
            {"contentId":7,"source":"Q \\"x\\" \\\\ / \\t\\n\\u0001","author":"Augustine","tradition":"Catholic",\
            "sourceUrl":"https://example.org/a?b=c"}]
            """)
    }

    @Test func roundTrips() throws {
        let citations = [
            Citation(contentId: 1, source: "𝔊othic — ü", author: nil, tradition: "Reformed", sourceURL: ""),
            Citation(contentId: 2, source: "Didache", author: "", tradition: nil, sourceURL: "https://x"),
        ]
        #expect(Citation.decode(jsonText: Citation.jsonText(citations)) == citations)
    }

    /// The shape the Dart chat history test stores, with keys missing.
    @Test func missingFieldsTakeDartsDefaults() {
        #expect(Citation.decode(jsonText: #"[{"contentId": 42, "source": "On Grace and Free Will"}]"#)
            == [Citation(contentId: 42, source: "On Grace and Free Will")])
        #expect(Citation.decode(jsonText: "[{}]") == [Citation(contentId: 0, source: "Unknown source")])
    }

    @Test func aValueOfTheWrongTypeReadsAsMissing() {
        #expect(Citation.decode(jsonText: #"[{"contentId": "42", "source": 7, "author": false}]"#)
            == [Citation(contentId: 0, source: "Unknown source")])
    }

    @Test(arguments: ["not json", "{}", #"{"contentId": 1}"#, "[1, 2]", #"[{"contentId": 1}, 2]"#, "", "null"])
    func anythingButAnArrayOfObjectsIsMalformed(_ blob: String) {
        #expect(Citation.decode(jsonText: blob) == nil)
    }

    @Test func traceableNeedsANonEmptyURL() {
        #expect(!Citation(contentId: 1, source: "s").isTraceable)
        #expect(!Citation(contentId: 1, source: "s", sourceURL: "").isTraceable)
        #expect(Citation(contentId: 1, source: "s", sourceURL: "https://x").isTraceable)
    }

    @Test func promptLabelLeavesOutWhatIsMissingOrEmpty() {
        #expect(Citation(contentId: 1, source: "S").promptLabel == "S")
        #expect(Citation(contentId: 1, source: "S", author: "", tradition: "").promptLabel == "S")
        #expect(Citation(contentId: 1, source: "S", author: "A").promptLabel == "S — A")
        #expect(Citation(contentId: 1, source: "S", tradition: "Reformed").promptLabel == "S — Reformed tradition")
        #expect(Citation(contentId: 1, source: "S", author: "A", tradition: "T").promptLabel == "S — A — T tradition")
    }
}
