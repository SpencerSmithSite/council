// Covers Inference/FoundationModelsBackend.swift: the states and their
// wording, the snapshot-to-delta conversion, and (where this Mac has Apple
// Intelligence switched on) one real generation.

import Foundation
import Testing
@testable import CouncilCore

#if canImport(FoundationModels)
import FoundationModels
#endif

@Suite struct FoundationModelsBackendTests {
    /// Only the states a reader can do something about are offered: ready,
    /// switched off, still downloading. Hardware that can never run it gets
    /// no permanently grey row.
    @Test func whichStatesAreWorthOffering() {
        let offered = PlatformLlmState.allCases.filter(\.worthOffering)
        #expect(offered == [.available, .notEnabled, .modelNotReady])
    }

    @Test func statusFollowsTheReport() async {
        let ready = FoundationModelsBackend { PlatformLlmAvailability(.available, "Ready.") }
        #expect(await ready.checkStatus() == .available("Ready."))
        let off = FoundationModelsBackend { PlatformLlmAvailability(.notEnabled, "Switched off.") }
        #expect(await off.checkStatus() == .unavailable("Switched off."))
        #expect(!off.availability.isAvailable)
    }

    @Test func describesItself() async {
        let backend = FoundationModelsBackend { PlatformLlmAvailability(.available, "") }
        #expect(backend.id == .platform)
        #expect(backend.displayName == "Apple Intelligence")
        #expect(backend.isPrivate)
        #expect(backend.contextBudgetChars == 4000)
        #expect(await backend.availableModels().isEmpty)
    }

    #if canImport(FoundationModels)
    /// The bridge's sentences, platform by platform.
    @Test func unavailableReasonsAreWordedAsTheBridgeWordedThem() {
        let notEligible = FoundationModelsBackend.unavailable(.deviceNotEligible)
        let notEnabled = FoundationModelsBackend.unavailable(.appleIntelligenceNotEnabled)
        let notReady = FoundationModelsBackend.unavailable(.modelNotReady)
        #expect(notEligible.state == .notEligible)
        #expect(notEnabled.state == .notEnabled)
        #expect(notReady.state == .modelNotReady)
        #if os(macOS)
        #expect(notEligible.detail == "This Mac does not support Apple Intelligence. It needs Apple silicon.")
        #expect(notEnabled.detail
            == "Apple Intelligence is switched off. Turn it on in System Settings → Apple Intelligence & Siri.")
        #else
        #expect(notEligible.detail
            == "This iPhone does not support Apple Intelligence. It needs an iPhone 15 Pro or newer.")
        #expect(notEnabled.detail
            == "Apple Intelligence is switched off. Turn it on in Settings → Apple Intelligence & Siri.")
        #endif
        #expect(notReady.detail
            == "Apple Intelligence is still downloading its model. This finishes on its own — try again shortly.")
    }

    /// Whatever this Mac reports maps to one of the states, with a sentence.
    @Test func thisDevicesAvailabilityMaps() {
        let report = FoundationModelsBackend.systemAvailability()
        #expect(!report.detail.isEmpty)
        #expect(report.state != .osTooOld && report.state != .unsupportedPlatform)
    }

    @Test func otherErrorsKeepTheFrameworksDescription() {
        struct Odd: LocalizedError { var errorDescription: String? { "Something odd." } }
        #expect(FoundationModelsBackend.readable(Odd()) == "Something odd.")
    }

    /// A smoke test against the real model, when this Mac can run it.
    /// Skipped (not failed) everywhere else, CI included.
    @Test(.enabled(if: FoundationModelsBackend.systemAvailability().isAvailable), .timeLimit(.minutes(2)))
    func aRealAnswerStreamsAsDeltas() async throws {
        let backend = FoundationModelsBackend()
        #expect(await backend.checkStatus().available)
        let result = await drain(backend.generate(
            prompt: "Relevant sources:\n\n[1] John 1:1\nIn the beginning was the Word.\n\n\n"
                + "User question: What was in the beginning?\n\nAnswer using the provided sources. "
                + "Cite them as [1], [2] and so on.",
            system: ChatPrompt.systemPrompt))
        #expect(result.error == nil, "\(String(describing: result.error))")
        let answer = result.pieces.joined()
        #expect(!answer.isEmpty)
        // Deltas, not snapshots: no piece repeats the answer so far.
        if result.pieces.count > 2 {
            #expect(result.pieces.last.map { !answer.hasPrefix($0) || $0.count < 3 } ?? true)
        }
    }
    #endif

    // MARK: Snapshots to deltas

    @Test func cumulativeSnapshotsBecomeTheirAdditions() {
        var deltas = SnapshotDeltas()
        #expect(deltas.next("") == nil)
        #expect(deltas.next("The") == "The")
        #expect(deltas.next("The") == nil)
        #expect(deltas.next("The Word") == " Word")
        #expect(deltas.next("The Word was") == " was")
    }

    /// The bridge compared `Character` counts: "e" then "e\u{301}" is one
    /// character both times, so the accent was skipped and later dropped.
    @Test func aCombiningMarkAfterItsLetterIsNotLost() {
        var deltas = SnapshotDeltas()
        var answer = ""
        for snapshot in ["Ecclesiaste", "Ecclesiaste\u{301}", "Ecclesiaste\u{301}s"] {
            answer += deltas.next(snapshot) ?? ""
        }
        #expect(DartText.equal(answer, "Ecclesiaste\u{301}s"))
    }

    @Test func emojiSequencesGrowScalarByScalar() {
        var deltas = SnapshotDeltas()
        var answer = ""
        for snapshot in ["👨", "👨\u{200D}", "👨\u{200D}👩", "👨\u{200D}👩 ok"] {
            answer += deltas.next(snapshot) ?? ""
        }
        #expect(DartText.equal(answer, "👨\u{200D}👩 ok"))
    }

    /// Never seen, but not promised against: a revised snapshot sends nothing
    /// and the answer carries on from it.
    @Test func aRevisionSendsNothingAndTheRestStillArrives() {
        var deltas = SnapshotDeltas()
        #expect(deltas.next("Grace is") == "Grace is")
        #expect(deltas.next("Grace was") == nil)
        #expect(deltas.next("Grace was given") == " given")
    }
}
