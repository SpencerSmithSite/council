import Foundation
import Testing
@testable import CouncilCore

// The Swift side of shared/golden/segments/segments.json: what the Flutter
// reader's segmenter (lib/src/reader/passage_segments.dart) makes of each
// passage, reproduced by CouncilCore/Reading/PassageSegments.swift. The Flutter
// side writes and checks the same file in test/segments_golden_test.dart; the
// README beside the fixture documents the format.
//
// Everything is exact. Offsets are UTF-16 code units because highlights saved
// by the Flutter app are stored that way, and strings are compared by code
// unit because Swift's `==` would accept an NFC/NFD difference that Dart would
// not.
//
// Parameterised over the cases so a failure names the case, and each check
// reports the first field that differs rather than a wall of diffs.

struct GoldenSegmentCase: Decodable, Sendable, CustomTestStringConvertible {
    struct Segment: Decodable, Sendable {
        let index: Int
        let start: Int
        let end: Int
        let text: String
        let number: Int?

        /// Written as `[index, start, end, text, number|null]`.
        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            index = try row.decode(Int.self)
            start = try row.decode(Int.self)
            end = try row.decode(Int.self)
            text = try row.decode(String.self)
            number = try row.decodeIfPresent(Int.self)
        }
    }

    struct Selection: Decodable, Sendable {
        let selected: [Int]
        let reference: String
        let quote: String
    }

    let id: String
    let why: String
    let unitTitle: String?
    let content: String
    let kind: String
    let nouns: [String]
    let segments: [Segment]
    let selections: [Selection]

    var testDescription: String { id }
}

private struct GoldenSegmentsFile: Decodable {
    let cases: [GoldenSegmentCase]
}

enum GoldenSegments {
    static let cases: [GoldenSegmentCase] = {
        do {
            let data = try Data(contentsOf: Repo.golden("segments/segments.json"))
            return try JSONDecoder().decode(GoldenSegmentsFile.self, from: data).cases
        } catch {
            fatalError("Could not read shared/golden/segments/segments.json: \(error)")
        }
    }()
}

/// Nil when the two strings are the same code units; otherwise where and how
/// they differ, escaped so invisible characters show.
private func stringDifference(_ actual: String, _ expected: String) -> String? {
    let a = Array(actual.utf16), e = Array(expected.utf16)
    guard a != e else { return nil }
    let at = zip(a, e).prefix { $0 == $1 }.count
    func around(_ units: [UInt16]) -> String {
        let lo = max(0, at - 12), hi = min(units.count, at + 12)
        return String(decoding: units[lo..<hi], as: UTF16.self).debugDescription
    }
    return "differs at UTF-16 offset \(at) (lengths \(a.count) vs \(e.count)): "
        + "got …\(around(a))… expected …\(around(e))…"
}

/// The first field where `actual` departs from `golden`, or nil.
private func segmentationDifference(_ actual: SegmentedPassage,
                                    _ golden: GoldenSegmentCase) -> String? {
    if actual.kind.rawValue != golden.kind {
        return "kind: \(actual.kind.rawValue) != \(golden.kind)"
    }
    for (count, noun) in golden.nouns.enumerated() {
        if let diff = stringDifference(actual.noun(count), noun) { return "noun(\(count)) \(diff)" }
    }
    for (i, (segment, expected)) in zip(actual.segments, golden.segments).enumerated() {
        if segment.index != expected.index { return "segment \(i) index: \(segment.index) != \(expected.index)" }
        if segment.start != expected.start { return "segment \(i) start: \(segment.start) != \(expected.start)" }
        if segment.end != expected.end { return "segment \(i) end: \(segment.end) != \(expected.end)" }
        if let diff = stringDifference(segment.text, expected.text) { return "segment \(i) text \(diff)" }
        if segment.number != expected.number {
            return "segment \(i) number: \(String(describing: segment.number)) != \(String(describing: expected.number))"
        }
    }
    if actual.segments.count != golden.segments.count {
        return "segment count: \(actual.segments.count) != \(golden.segments.count)"
    }
    return nil
}

@Suite("Segments golden fixture")
struct SegmentsGoldenTests {
    @Test func fixtureIsPresent() {
        let cases = GoldenSegments.cases
        #expect(cases.count == 87)
        #expect(Set(cases.map(\.id)).count == cases.count)
        // The fixture must exercise every kind, or a port that never splits
        // sentences (say) could pass it.
        #expect(Set(cases.map(\.kind)) == ["verse", "paragraph", "sentence"])
    }

    @Test(arguments: GoldenSegments.cases)
    func segments(_ golden: GoldenSegmentCase) {
        let diff = segmentationDifference(SegmentedPassage(golden.content), golden)
        #expect(diff == nil, "\(golden.id): \(diff ?? "")")
    }

    @Test(arguments: GoldenSegments.cases)
    func selections(_ golden: GoldenSegmentCase) throws {
        let passage = SegmentedPassage(golden.content)
        // Without the right segments every selection would differ too; the
        // segments test reports that, once.
        try #require(segmentationDifference(passage, golden) == nil,
                     "\(golden.id): segmentation differs")
        for (i, selection) in golden.selections.enumerated() {
            let chosen = selection.selected.map { passage.segments[$0] }
            let reference = PassageCitation.reference(unitTitle: golden.unitTitle, selected: chosen)
            let referenceDiff = stringDifference(reference, selection.reference)
            #expect(referenceDiff == nil,
                    "\(golden.id) selection \(i) \(selection.selected) reference \(referenceDiff ?? "")")
            let quote = PassageCitation.quote(passage, selected: selection.selected)
            let quoteDiff = stringDifference(quote, selection.quote)
            #expect(quoteDiff == nil,
                    "\(golden.id) selection \(i) \(selection.selected) quote \(quoteDiff ?? "")")
        }
    }

    /// The UI selects with a `Set<Int>`; the quote must not depend on its
    /// iteration order.
    @Test(arguments: GoldenSegments.cases)
    func quoteFromASet(_ golden: GoldenSegmentCase) {
        let passage = SegmentedPassage(golden.content)
        for selection in golden.selections where Set(selection.selected).count == selection.selected.count {
            let quote = PassageCitation.quote(passage, selected: Set(selection.selected))
            #expect(stringDifference(quote, selection.quote) == nil,
                    "\(golden.id) \(selection.selected)")
        }
    }
}

@Suite("Passage segments")
struct PassageSegmentsUnitTests {
    @Test func identityIsTheIndex() {
        let passage = SegmentedPassage("1. One.\n2. Two.")
        #expect(passage.segments.map(\.id) == [0, 1])
    }

    @Test func overlapsIsHalfOpen() {
        let segment = PassageSegment(index: 0, start: 10, end: 20, text: "x")
        #expect(segment.overlaps(19, 25))
        #expect(segment.overlaps(0, 11))
        #expect(segment.overlaps(12, 13))
        #expect(!segment.overlaps(20, 30))
        #expect(!segment.overlaps(0, 10))
    }

    @Test func outOfRangeIndicesAreSkippedInQuotes() {
        let passage = SegmentedPassage("1. One.\n2. Two.\n3. Three.")
        #expect(PassageCitation.quote(passage, selected: [0, 1, 9, -1]) == "One. Two.")
        #expect(PassageCitation.quote(passage, selected: [7]) == "")
    }

    @Test func offsetsAreUTF16() {
        // 😀 is one Character, one scalar and two UTF-16 code units.
        let passage = SegmentedPassage("😀 one.\n\nTwo.")
        #expect(passage.segments.map(\.start) == [0, 9])
        #expect(passage.segments.map(\.end) == [7, 13])
    }

    @Test func emptyContentIsAnEmptyParagraphPassage() {
        let passage = SegmentedPassage(" \n\u{FEFF}")
        #expect(passage.isEmpty)
        #expect(passage.kind == .paragraph)
        #expect(passage.noun(0) == "paragraphs")
    }
}
