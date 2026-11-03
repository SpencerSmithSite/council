// Mirrors test/pack_catalogue_test.dart.

import Foundation
import Testing
@testable import CouncilCore

/// Noticing that a question needs content the user has not installed.
///
/// Run against the *real* generated catalogue rather than a fixture. The
/// judgements here — is "Origen" mentioned, does this pack cover the Eucharist
/// heavily — depend entirely on the actual names and tag distributions in the
/// corpus, so a hand-written fixture would test the thresholds against data
/// chosen to satisfy them.
@Suite struct PackCatalogueTests {
    // swiftlint:disable:next force_try
    static let catalogue = try! PackCatalogue.load(from: Repo.asset(PackCatalogue.bundledFileName))
    var catalogue: PackCatalogue { Self.catalogue }

    /// Every fragment, for the "nothing is missing" cases.
    var everything: Set<String> { Set(catalogue.fragments.keys) }

    /// The fragments a named collection needs — the test speaks in collections
    /// because that is what a reader installs, while the code counts fragments.
    func fragmentsOf(_ collections: [String]) -> Set<String> {
        Set(collections.flatMap { catalogue.packs[$0]!.fragments })
    }

    func suggest(_ question: String, tags: [String] = [], installed: Set<String> = []) -> [PackSuggestion] {
        catalogue.suggest(question: question, queryTags: tags, installedFragments: installed)
    }

    @Test func theCatalogueDescribesThePublishedPacks() {
        for id in ["creeds-and-confessions", "church-fathers", "author-augustine", "tradition-lutheran"] {
            #expect(catalogue.packs[id] != nil, "\(id)")
        }
        #expect(catalogue.packs["church-fathers"]!.authors.count > 50)
        #expect(catalogue.orderedPacks.count == catalogue.packs.count)
        #expect(catalogue.name(of: "church-fathers") == catalogue.packs["church-fathers"]!.name)
        #expect(catalogue.name(of: "no-such-pack") == "no-such-pack")
    }

    @Test func packsKeepTheCataloguesOrder() throws {
        // suggest() walks them in this order and breaks ties by it, as the
        // Dart map from jsonDecode does.
        let raw = try String(contentsOf: Repo.asset(PackCatalogue.bundledFileName), encoding: .utf8)
        let packsAt = try #require(raw.range(of: "\"packs\""))
        let positions = catalogue.orderedPacks.map { raw.range(of: "\"\($0.id)\": {", range: packsAt.upperBound..<raw.endIndex)!.lowerBound }
        #expect(positions == positions.sorted())
    }

    // MARK: Naming an author

    @Test func aQuestionAboutAugustinePointsAtTheAugustinePack() {
        let suggestions = suggest("What did Augustine say about grace?")
        #expect(!suggestions.isEmpty)
        // The narrowest match, not the largest: "Church Fathers" would also
        // answer it, at ten times the download.
        #expect(suggestions.first?.packID == "author-augustine")
        #expect(suggestions.first?.reason == .namesAuthor)
        #expect(suggestions.first?.explanation.contains("Augustine") == true)
        #expect(suggestions.count == 1, "overlapping collections must not each produce a notice")
    }

    @Test func aSurnameAloneIsEnough() {
        #expect(suggest("Chrysostom on almsgiving").first?.packID == "author-chrysostom")
    }

    @Test func anAuthorAlreadyOnTheDeviceIsNeverSuggestedAgain() {
        // Installing "Augustine of Hippo" leaves the *Catholic* collection
        // incomplete, and that collection also lists Augustine among its
        // authors. Asking about him afterwards kept offering to install him —
        // observed in the running app, right after the download that was
        // supposed to fix it.
        let suggestions = suggest("What did Augustine say about grace?", installed: fragmentsOf(["author-augustine"]))
        #expect(suggestions.filter { $0.reason == .namesAuthor }.isEmpty,
                "his writings are installed; only a collection is incomplete")
    }

    @Test func nothingIsSuggestedOnceThePackIsInstalled() {
        #expect(suggest("What did Augustine say about grace?", installed: everything).isEmpty)
    }

    // MARK: Not crying wolf

    @Test func originalSinDoesNotMatchOrigen() {
        // Substring matching would fire here, and a notice that is wrong once is
        // a notice that gets ignored forever.
        #expect(suggest("the doctrine of original sin").filter { $0.reason == .namesAuthor }.isEmpty)
    }

    @Test func aCommonFirstNameDoesNotNameAnAuthor() {
        // "John" appears in John Chrysostom, John Cassian, John of Damascus —
        // and in any question about the fourth gospel.
        #expect(suggest("What does the gospel of John teach?").filter { $0.reason == .namesAuthor }.isEmpty)
    }

    @Test func aQuestionWithNoSubjectAndNoNameSuggestsNothing() {
        #expect(suggest("hello").isEmpty)
    }

    @Test func anInstalledLibraryIsNeverNagged() {
        #expect(suggest("the Eucharist", tags: ["eucharist"], installed: everything).isEmpty)
    }

    // MARK: Restraint

    static let everyTag = [
        "baptism", "eucharist", "grace", "justification", "trinity",
        "salvation", "sin", "church", "scripture", "prayer",
    ]

    @Test func withOnlyTheCoreASubjectQuestionDoesWarn() {
        // The core holds 7 of the 83 passages tagged eucharist. An answer built
        // from those alone is drawn from under a tenth of what exists.
        let suggestions = suggest("what happens in communion", tags: ["eucharist"])
        #expect(suggestions.count == 1, "one notice per question, not one per missing pack")
    }

    @Test func installingTheMainCollectionQuietsMostOfIt() {
        // Installing the largest pack removes the warning for most subjects,
        // because it genuinely closes most of the gap. (The largest by text is
        // 'tradition-reformed', not 'church-fathers', which is largest by
        // works; the Dart test records how naming it by reputation went stale.)
        let warned = Self.everyTag.filter {
            !suggest("a question with no names in it", tags: [$0], installed: fragmentsOf(["tradition-reformed"])).isEmpty
        }
        #expect(warned.count < 3, "after the big pack, only genuinely thin subjects should warn: \(warned)")
    }

    @Test func thePatristicPackAloneStillWarnsOnTheReformationSubjects() {
        // A notice that never fires is as useless as one that always does.
        let warned = Self.everyTag.filter {
            !suggest("a question with no names in it", tags: [$0], installed: fragmentsOf(["church-fathers"])).isEmpty
        }
        #expect(warned.count > 2, "the patristic corpus is genuinely thin on several of these")
    }

    @Test func aFullyInstalledLibraryNeverWarnsAboutAnySubject() {
        for tag in Self.everyTag {
            #expect(suggest("anything at all", tags: [tag], installed: everything).isEmpty, "\(tag)")
        }
    }

    // MARK: Covering a subject

    @Test func aSubjectAPackCoversHeavilyIsSurfaced() {
        let suggestions = suggest("What happens in the Lord's Supper?", tags: ["eucharist", "sacraments"])
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.reason == .coversSubject })
        #expect(suggestions.first?.explanation.contains("not installed") == true)
    }

    @Test func aNamedAuthorOutranksGenericSubjectCoverage() {
        let suggestions = suggest("What did Augustine teach about baptism?", tags: ["baptism"])
        #expect(suggestions.first?.reason == .namesAuthor)
        #expect(suggestions.first?.packID == "author-augustine")
    }

    // MARK: The Baptist tradition is reachable

    @Test func aBaptistPackIsPublishedAndCarriesTheConfession() throws {
        let pack = try #require(catalogue.packs["tradition-baptist"],
                                "a tradition with sources but no collection cannot be installed by anyone")
        #expect(!pack.fragments.isEmpty)
        #expect(pack.titles.contains { $0.contains("Second London Baptist") }, "\(pack.titles)")
        // Collections overlap on purpose: the essential creeds pack has it too.
        #expect(catalogue.packs["creeds-and-confessions"]!.titles.contains { $0.contains("Second London Baptist") })
    }

    @Test func askingAboutTheConfessionOffersItUntilItIsInstalled() {
        let question = "What does the Second London Baptist Confession teach about baptism?"
        let offered = suggest(question).map(\.packID)
        #expect(offered.contains("tradition-baptist") || offered.contains("creeds-and-confessions"),
                "the question names a work that is not installed")
        #expect(!suggest(question, installed: fragmentsOf(["tradition-baptist"])).map(\.packID).contains("tradition-baptist"))
    }

    @Test func theWestminsterConfessionIsTheDocumentNotAParaphrase() {
        let reformed = catalogue.packs["tradition-reformed"]!
        #expect(reformed.titles.contains("The Westminster Confession of Faith"))
        #expect(!reformed.titles.contains("Westminster Confession of Faith"), "the unprovenanced stub is back")
    }

    // MARK: A tradition with nothing installed

    @Test func aTraditionIsOfferedWhenTheQuestionNamesIt() {
        let suggestions = suggest("What do Baptists believe about baptism?", tags: ["baptism"])
        #expect(suggestions.first?.reason == .traditionAbsent)
        #expect(suggestions.first?.detail == "Baptist")
        #expect(suggestions.first?.explanation.contains("none of it is") == true)
        // The narrowest pack that fixes it, not the largest that contains it.
        #expect(suggestions.first?.packID == "tradition-baptist")
    }

    @Test func anAbsentTraditionOutranksAPackThatMerelyHoldsMore() {
        let ids = suggest("What do Baptists teach about baptism?", tags: ["baptism"]).map(\.packID)
        // Asserted present first: an ordering check alone passes most
        // convincingly when the thing being ordered is absent.
        let baptist = ids.firstIndex(of: "tradition-baptist")
        #expect(baptist != nil)
        for bigger in ["church-fathers", "nicene-fathers"] {
            guard let at = ids.firstIndex(of: bigger), let baptist else { continue }
            #expect(baptist < at)
        }
    }

    @Test func commonAliasesCountAsNamingATradition() {
        for phrasing in [
            "what do Presbyterians say about the sacraments",
            "the Lutheran view of justification",
            "an Episcopalian understanding of orders",
        ] {
            #expect(!suggest(phrasing).filter { $0.reason == .traditionAbsent }.isEmpty, "nothing matched in: \(phrasing)")
        }
    }

    @Test func aTraditionIsSilentOnceAnyOfItIsInstalled() {
        let suggestions = suggest("What do Baptists believe about baptism?", tags: ["baptism"],
                                  installed: fragmentsOf(["tradition-baptist"]))
        #expect(suggestions.filter { $0.reason == .traditionAbsent }.isEmpty)
    }

    @Test func wesleyIsReachableByName() {
        let suggestions = suggest("What did Wesley teach about assurance?")
        #expect(suggestions.first?.reason == .namesAuthor)
        #expect(suggestions.first?.detail == "John Wesley")
        #expect(suggestions.first?.packID == "tradition-methodist")
    }

    @Test func orthodoxAsAnAdjectiveIsNotReadAsATradition() {
        #expect(suggest("is this an orthodox view of the incarnation?").filter { $0.reason == .traditionAbsent }.isEmpty)
    }

    // MARK: Matching rules Dart's RegExp implies

    @Test func wordBoundariesAreASCIIAsInDart() {
        #expect(PackCatalogue.mentions("What did Augustine's sermons say?", "Augustine"))
        #expect(!PackCatalogue.mentions("Augustinian thought", "Augustine"))
        #expect(PackCatalogue.mentions("AUGUSTINE on grace", "augustine"))
        #expect(!PackCatalogue.mentions("any text", "Abc"), "needles under four code units never match")
        // Dart's non-Unicode \b sees no boundary between an accented letter and
        // a space, so a needle ending in one cannot match before a space.
        #expect(!PackCatalogue.mentions("josé said", "josé"))
        #expect(!PackCatalogue.mentions("xjosé", "josé"), "no boundary between two ASCII letters")
    }

    @Test func significantWordsSplitOnAnythingButASCIILettersAndDigits() {
        #expect(PackCatalogue.significant("The Second London Baptist Confession of Faith")
            == ["second", "london", "baptist", "confession", "faith"])
        #expect(PackCatalogue.significant("Grégoire’s 1689 work") == ["goire", "1689", "work"])
    }

    @Test func namePartsDropShortAndCommonNames() {
        #expect(PackCatalogue.nameParts(of: "John Chrysostom") == ["John Chrysostom", "Chrysostom"])
        #expect(PackCatalogue.nameParts(of: "Augustine of Hippo") == ["Augustine of Hippo", "Augustine", "Hippo"])
        #expect(PackCatalogue.nameParts(of: "Basil/Gregory") == ["Basil/Gregory", "Basil"])
    }

    @Test func aMalformedCatalogueThrows() {
        #expect(throws: (any Error).self) { try PackCatalogue.parse("{}") }
        #expect(throws: (any Error).self) { try PackCatalogue.parse(#"{"packs": {"x": {"tags": {"a": 1.5}}}}"#) }
        #expect(throws: (any Error).self) { try PackCatalogue.parse("not json") }
    }

    @Test func orderedJSONReadsEscapesAndNumbers() throws {
        let json = try OrderedJSON.parse(Data(#"{"b": [1, -2.5e1, true, null, "a\"é😀\n"], "a": {}}"#.utf8))
        #expect(json.keys == ["b", "a"])
        #expect(json["b"] == .array([.int(1), .double(-25), .bool(true), .null, .string("a\"é😀\n")]))
    }
}
