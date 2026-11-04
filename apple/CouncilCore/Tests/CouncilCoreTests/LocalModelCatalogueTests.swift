// Mirrors test/local_model_catalogue_test.dart and
// test/local_model_architecture_test.dart.

import Foundation
import Testing
@testable import CouncilCore

/// The catalogue, the memory and disk gates, and the per-device
/// recommendation.
///
/// The Dart ran these on the host and so could only exercise the platform it
/// ran on; here the platform is an argument, so the phone and desktop rules
/// are both asserted on any machine.
@Suite struct LocalModelCatalogueTests {
    // MARK: - The catalogue

    @Test func offersOnlyQwenFromUngatedMLXCommunityRepositories() {
        for model in LocalModel.catalogue {
            // Gemma and friends are gated behind a Hugging Face account, which
            // this backend promises readers they don't need.
            #expect(model.name.hasPrefix("Qwen"))
            #expect(model.repository.hasPrefix("mlx-community/Qwen3-"))
            #expect(model.repository.hasSuffix("-4bit"))
        }
    }

    @Test func keepsTheFlutterIDsSinceThePreferenceStoresThem() {
        #expect(LocalModel.catalogue.map(\.id) == ["qwen3-0.6b", "qwen3-1.7b", "qwen3-4b-2507", "qwen3-8b"])
        let ids = LocalModel.catalogue.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyModelIsPinnedToACommitAndCarriesWhatMLXLoads() {
        for model in LocalModel.catalogue {
            #expect(model.revision.count == 40 && model.revision.allSatisfy(\.isHexDigit), "\(model.id)")
            let paths = Set(model.files.map(\.path))
            for required in ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"] {
                #expect(paths.contains(required), "\(model.id) lacks \(required)")
            }
            #expect(paths.count == model.files.count, "\(model.id) lists a file twice")
            for file in model.files {
                #expect(file.bytes > 0)
                #expect(file.sha256.count == 64 && file.sha256.allSatisfy { "0123456789abcdef".contains($0) })
                let url = model.url(for: file).absoluteString
                #expect(url == "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(file.path)")
            }
        }
    }

    @Test func theInstructModelHasItsOwnTemplateAndNeverThinks() {
        // The 2507 Instruct ships its template as chat_template.jinja; without
        // it the tokenizer has no template at all.
        #expect(LocalModel.qwen3_4B.files.contains { $0.path == "chat_template.jinja" })
        #expect(!LocalModel.qwen3_4B.thinksByDefault)
        for model in [LocalModel.qwen3_0_6B, .qwen3_1_7B, .qwen3_8B] {
            #expect(model.thinksByDefault, "\(model.id)")
        }
    }

    @Test func downloadSizesAreTheRealOnes() {
        // Summed from the pinned files, as listed by the Hugging Face API.
        #expect(LocalModel.qwen3_0_6B.downloadBytes == 346_934_932)
        #expect(LocalModel.qwen3_1_7B.downloadBytes == 979_564_558)
        #expect(LocalModel.qwen3_4B.downloadBytes == 2_274_521_011)
        #expect(LocalModel.qwen3_8B.downloadBytes == 4_619_333_858)
        #expect(LocalModel.catalogue.map(\.approximateSize) == ["347 MB", "980 MB", "2.3 GB", "4.6 GB"])
        #expect(LocalModel.qwen3_0_6B.downloadMB == 331)
    }

    @Test func theCatalogueIsOrderedSmallestFirst() {
        // conservativeDefault() returns the first and is meant to be the most
        // conservative option, not merely the first written.
        for platform in [LocalModelPlatform.phone, .desktop] {
            let ram = LocalModel.offered(on: platform).map(\.ramMB)
            #expect(ram == ram.sorted())
        }
    }

    @Test func whatIsOfferedIsASubsetOfTheCatalogue() {
        for platform in [LocalModelPlatform.phone, .desktop] {
            for model in LocalModel.offered(on: platform) {
                #expect(LocalModel.catalogue.contains(model))
            }
        }
    }

    // MARK: - Resolving a stored id

    @Test func findsEveryModelOfferedHereOrNot() {
        // Chosen on a Mac, opened on a phone.
        for platform in [LocalModelPlatform.phone, .desktop] {
            for model in LocalModel.catalogue {
                #expect(LocalModel.byID(model.id, on: platform) == model)
            }
        }
    }

    @Test func fallsBackToTheConservativeDefaultForAnIDSinceRemoved() {
        // 'gemma3-1b' shipped before the Gemma weights turned out to be gated.
        #expect(LocalModel.byID("gemma3-1b", on: .phone) == LocalModel.conservativeDefault(on: .phone))
        #expect(LocalModel.byID("gemma3-1b", on: .desktop) == .qwen3_0_6B)
    }

    // MARK: - The memory gate

    @Test func hidesAModelTheDeviceCannotHold() {
        // A 2 GB phone. Nothing fits, so exactly one is shown so the card can
        // say why, and it is honest about not fitting.
        let offered = LocalModel.available(deviceMemoryMB: 2048, on: .phone)
        #expect(offered == [.qwen3_0_6B])
        #expect(!offered[0].fits(deviceMemoryMB: 2048, on: .phone))
    }

    @Test func neverOffersNothingSoTheScreenCanExplainItself() {
        for platform in [LocalModelPlatform.phone, .desktop] {
            let offered = LocalModel.available(deviceMemoryMB: 512, on: platform)
            #expect(offered.count == 1)
            #expect(!offered[0].fits(deviceMemoryMB: 512, on: platform))
        }
    }

    @Test func offersEverythingThePlatformHasWhenMemoryIsAmple() {
        for platform in [LocalModelPlatform.phone, .desktop] {
            #expect(LocalModel.available(deviceMemoryMB: 65536, on: platform) == LocalModel.offered(on: platform))
        }
    }

    @Test func isPermissiveWhenTheAmountCannotBeRead() {
        // Unknown must not be treated as too little.
        #expect(LocalModel.qwen3_8B.fits(deviceMemoryMB: nil, on: .desktop))
        #expect(LocalModel.available(deviceMemoryMB: nil, on: .desktop) == LocalModel.offered(on: .desktop))
    }

    @Test func readsThisDevicesMemory() {
        let total = LocalDeviceMemory.totalMB()
        #expect(total != nil && total! > 1024)
        #if os(macOS)
        #expect(LocalDeviceMemory.appAvailableMB() == nil, "macOS has no per-app cap")
        #endif
    }

    // MARK: - The recommendation matches the machine

    @Test func moreMemoryEarnsAMoreCapableModel() {
        for platform in [LocalModelPlatform.phone, .desktop] {
            let small = LocalModel.recommended(forDeviceMemory: 3000, on: platform)
            let large = LocalModel.recommended(forDeviceMemory: 64000, on: platform)
            #expect(small != large)
            #expect(large.ramMB > small.ramMB)
        }
    }

    @Test func theRecommendationIsAlwaysOneTheDeviceCanHold() {
        for platform in [LocalModelPlatform.phone, .desktop] {
            for mb in [2048, 3000, 6000, 8000, 16000, 64000] {
                let pick = LocalModel.recommended(forDeviceMemory: mb, on: platform)
                let offered = LocalModel.available(deviceMemoryMB: mb, on: platform)
                #expect(offered.contains(pick))
                // Below the floor nothing fits and the smallest is shown with a
                // warning; above it, the pick must genuinely fit.
                if offered.count > 1 || mb >= LocalModel.offered(on: platform)[0].requiredMB(on: platform) {
                    #expect(mb >= pick.requiredMB(on: platform))
                }
            }
        }
    }

    @Test func itIsNeverTheSmallestWhenTheDeviceCanDoBetter() {
        for platform in [LocalModelPlatform.phone, .desktop] {
            let offered = LocalModel.available(deviceMemoryMB: 64000, on: platform)
            #expect(LocalModel.recommended(forDeviceMemory: 64000, on: platform) != offered[0])
        }
    }

    @Test func itAgreesWithTheRowThePickerMarksRecommended() {
        for platform in [LocalModelPlatform.phone, .desktop] {
            for mb in [3000, 8000, 64000] {
                let labelled = LocalModel.tiers(deviceMemoryMB: mb, on: platform).first { $0.tier == .recommended }
                #expect(LocalModel.recommended(forDeviceMemory: mb, on: platform) == labelled?.model)
            }
        }
    }

    @Test func aModestMacIsOfferedSomethingRatherThanNothing() {
        // The smallest model must be reachable on every platform.
        let offered = LocalModel.available(deviceMemoryMB: 4000, on: .desktop)
        #expect(!offered.isEmpty)
        #expect(offered[0].fits(deviceMemoryMB: 4000, on: .desktop))
    }

    @Test func theHeaviestModelsAreNeverOfferedOnAPhone() {
        // Phones cap what one app may hold well below physical memory, so a
        // 16 GB iPad still can't hold a 5 GB model.
        let phone = LocalModel.available(deviceMemoryMB: 64000, on: .phone)
        #expect(phone.allSatisfy { $0.minPhoneRAMMB != nil })
        #expect(!phone.contains(.qwen3_8B) && !phone.contains(.qwen3_4B))
        #expect(LocalModel.available(deviceMemoryMB: 64000, on: .desktop).contains(.qwen3_8B))
    }

    @Test func aPhoneNeedsMoreHeadroomThanADesktopForTheSameModel() {
        for model in LocalModel.catalogue {
            guard let phone = model.minPhoneRAMMB else { continue }
            #expect(phone >= model.minDeviceRAMMB, "\(model.id)")
        }
    }

    @Test func thePlatformDecidesTheCeilingNotTheFloor() {
        #expect(LocalModel.offered(on: .desktop).contains(.qwen3_8B))
        #expect(LocalModel.offered(on: .desktop).contains(.qwen3_0_6B))
        #expect(LocalModel.offered(on: .phone) == [.qwen3_0_6B, .qwen3_1_7B])
    }

    @Test func recommendsPerDeviceClass() {
        // Nominal sizes as the OS reports them, roughly.
        #expect(LocalModel.recommended(forDeviceMemory: 3900, on: .phone) == .qwen3_0_6B)  // 4 GB iPhone
        #expect(LocalModel.recommended(forDeviceMemory: 5700, on: .phone) == .qwen3_0_6B)  // 6 GB iPhone
        #expect(LocalModel.recommended(forDeviceMemory: 7600, on: .phone) == .qwen3_1_7B)  // 8 GB iPhone
        #expect(LocalModel.recommended(forDeviceMemory: 8192, on: .desktop) == .qwen3_1_7B)
        #expect(LocalModel.recommended(forDeviceMemory: 16384, on: .desktop) == .qwen3_4B)
        #expect(LocalModel.recommended(forDeviceMemory: 65536, on: .desktop) == .qwen3_4B)
    }

    // MARK: - The tiers offered to a reader

    @Test func neverMoreThanThreeTiersAndAlwaysARecommendation() {
        for platform in [LocalModelPlatform.phone, .desktop] {
            for mb in [2048, 3000, 6000, 8000, 16000, 64000] {
                let tiers = LocalModel.tiers(deviceMemoryMB: mb, on: platform)
                #expect((1...3).contains(tiers.count))
                #expect(tiers.contains { $0.tier == .recommended })
            }
        }
    }

    @Test func tiersRunSmallestToLargestAndAreDistinctModels() {
        let tiers = LocalModel.tiers(deviceMemoryMB: 64000, on: .desktop)
        #expect(tiers.map(\.tier) == [.small, .recommended, .large])
        let ram = tiers.map(\.model.ramMB)
        #expect(ram == ram.sorted())
        #expect(Set(tiers.map(\.model.id)).count == 3)
        // The largest that fits is also the slowest; defaulting to it makes
        // the feature feel broken on the machines that can run the most.
        #expect(tiers[1].model.ramMB < tiers[2].model.ramMB)
    }

    @Test func everyTierOfferedIsOneTheDeviceCanActuallyHold() {
        for platform in [LocalModelPlatform.phone, .desktop] {
            for mb in [3000, 6000, 8000, 16000, 64000] {
                for option in LocalModel.tiers(deviceMemoryMB: mb, on: platform) {
                    #expect(mb >= option.model.requiredMB(on: platform))
                }
            }
        }
    }

    @Test func tierCopyIsPresent() {
        for tier in LocalModelTier.allCases {
            #expect(!tier.label.isEmpty && !tier.rationale.isEmpty)
        }
    }

    // MARK: - The disk check

    @Test func refusesAModelThatWillNotFitInTheSpaceLeft() {
        // A 4.6 GB download onto a 1 GB disk fails after the bytes have been
        // fetched, which on a metered connection is paid for nothing.
        #expect(!LocalDeviceStorage.hasRoom(for: LocalModel.qwen3_8B.downloadBytes, freeBytes: 1_000_000_000))
    }

    @Test func leavesHeadroomRatherThanFillingTheDiskExactly() {
        let bytes = LocalModel.qwen3_0_6B.downloadBytes
        #expect(!LocalDeviceStorage.hasRoom(for: bytes, freeBytes: bytes + 10_000_000))
        #expect(LocalDeviceStorage.hasRoom(for: bytes, freeBytes: bytes + LocalDeviceStorage.headroomBytes))
        #expect(LocalDeviceStorage.hasRoom(for: bytes, freeBytes: bytes + 2_000_000_000))
    }

    @Test func isPermissiveWhenFreeSpaceCannotBeRead() {
        #expect(LocalDeviceStorage.hasRoom(for: 1 << 40, freeBytes: nil))
    }

    @Test func readsFreeSpaceEvenForADirectoryNotYetCreated() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "no/such/\(UUID().uuidString)")
        let free = LocalDeviceStorage.freeBytes(at: missing)
        #expect(free != nil && free! > 0)
    }

    @Test func sizeLabelsAreDecimal() {
        #expect(LocalModelFormat.size(346_934_932) == "347 MB")
        #expect(LocalModelFormat.size(999_400_000) == "999 MB")
        #expect(LocalModelFormat.size(2_274_521_011) == "2.3 GB")
    }

    // MARK: - Where it runs

    @Test func runsOnAppleSiliconWithAMetalGPU() {
        for platform in [LocalModelPlatform.phone, .desktop] {
            let env = LocalModelEnvironment(platform: platform, isSimulator: false, isAppleSilicon: true,
                                            hasMetalDevice: true)
            #expect(env.unsupportedReason == nil)
            #expect(env.runsLocalModels)
        }
    }

    @Test func notInTheSimulator() {
        // MLX needs GPU features the Simulator lacks and fails with Metal
        // assertions rather than errors, so it must be refused up front.
        let env = LocalModelEnvironment(platform: .phone, isSimulator: true, isAppleSilicon: true,
                                        hasMetalDevice: false)
        #expect(env.unsupportedReason?.contains("Simulator") == true)
    }

    @Test func notAnIntelMac() {
        let env = LocalModelEnvironment(platform: .desktop, isSimulator: false, isAppleSilicon: false,
                                        hasMetalDevice: true)
        #expect(env.unsupportedReason?.contains("Apple silicon") == true)
        #expect(env.unsupportedReason?.contains("Intel") == true)
    }

    @Test func notWithoutAMetalDevice() {
        let env = LocalModelEnvironment(platform: .desktop, isSimulator: false, isAppleSilicon: true,
                                        hasMetalDevice: false)
        #expect(env.unsupportedReason?.contains("Metal") == true)
    }

    @Test func thereIsAReasonForEveryEnvironmentThatCannotRunOne() {
        // The UI keys off runsLocalModels and the copy off unsupportedReason;
        // if they ever disagree, one of them shows a reader a contradiction.
        for platform in [LocalModelPlatform.phone, .desktop] {
            for simulator in [false, true] {
                for silicon in [false, true] {
                    for metal in [false, true] {
                        let env = LocalModelEnvironment(platform: platform, isSimulator: simulator,
                                                        isAppleSilicon: silicon, hasMetalDevice: metal)
                        #expect((env.unsupportedReason == nil) == (!simulator && silicon && metal))
                        #expect(env.unsupportedReason?.isEmpty != true)
                    }
                }
            }
        }
    }

    @Test func thisMacRunsThem() {
        #if os(macOS) && arch(arm64)
        #expect(LocalModelEnvironment.current.unsupportedReason == nil)
        #endif
    }

    // MARK: - Generation settings

    @Test func theAnswerGetsWhatThePromptLeavesOfTheWindow() {
        let model = LocalModel.qwen3_0_6B
        #expect(model.answerTokenLimit(promptTokens: 0) == 2048)
        #expect(model.answerTokenLimit(promptTokens: 1500) == 548)
        // Never squeezed to nothing.
        #expect(model.answerTokenLimit(promptTokens: 1900) == LocalModel.minimumAnswerTokens)
        #expect(model.answerTokenLimit(promptTokens: 5000) == LocalModel.minimumAnswerTokens)
    }

    @Test func thinkingIsSwitchedOffWhereTheModelWouldOtherwiseThink() {
        let hybrid = LocalModelBackend.thinkingContext(for: .qwen3_0_6B)
        #expect(hybrid?["enable_thinking"] as? Bool == false)
        #expect(LocalModelBackend.thinkingContext(for: .qwen3_4B) == nil)
    }

    @Test func decodingIsGreedyAsInTheFlutterApp() {
        #expect(LocalModelBackend.temperature == 0)
    }
}
