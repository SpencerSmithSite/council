import Foundation
import Testing
@testable import CouncilCore

// These values are shared with the Flutter app and with files already on
// users' devices; a change here has to be deliberate on both sides.

@Test func corpusConstantsMatchFlutter() {
    #expect(CorpusConstants.idSpace == 2)
    #expect(CorpusConstants.embeddingModel == "all-MiniLM-L6-v2-int8-384")
}

@Test func embeddingModelNameCarriesVectorWidth() {
    #expect(CorpusConstants.embeddingModel.hasSuffix("-\(SearchConstants.vectorDims)"))
}

@Test func persistedBackendIDsAreStable() {
    #expect(InferenceBackendID.allCases.map(\.rawValue) ==
        ["none", "platform", "local", "ollama", "anthropic", "openai", "gemini", "xai"])
}

@Test func flutterPreferenceKeysArePrefixed() {
    #expect(FlutterPreferences.defaultsKey("theme") == "flutter.theme")
}

@Test func goldenFixturesAreReachable() {
    #expect(FileManager.default.fileExists(atPath: Repo.golden("search/search.json").path))
    #expect(FileManager.default.fileExists(atPath: Repo.golden("packs/scenarios.json").path))
}
