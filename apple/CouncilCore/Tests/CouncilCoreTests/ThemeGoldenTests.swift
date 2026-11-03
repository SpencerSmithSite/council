import Foundation
import Testing
@testable import CouncilCore

// The Swift side of shared/golden/themes/derived.json: every colour role the
// palette derivation produces, for every catalogue theme in both
// brightnesses, plus the Apple platform palette. The Flutter side writes and
// checks the same file in test/theme_golden_test.dart. Comparison is exact on
// the 8-bit #AARRGGBB strings, so the port has to reproduce Flutter's double
// arithmetic closely enough that every channel rounds the same way.
//
// Parameterised over the themes so a failure names the theme.

private struct GoldenFile: Decodable {
    struct Theme: Decodable {
        let id: String
        let light: [String: String]
        let dark: [String: String]

        func variant(_ brightness: Brightness) -> [String: String] {
            brightness == .dark ? dark : light
        }
    }

    struct Variants: Decodable {
        let light: [String: String]
        let dark: [String: String]
    }

    struct Platform: Decodable {
        let apple: Variants
    }

    let themes: [Theme]
    let platform: Platform
}

private enum ThemeGolden {
    static let file: GoldenFile = {
        do {
            let data = try Data(contentsOf: Repo.golden("themes/derived.json"))
            return try JSONDecoder().decode(GoldenFile.self, from: data)
        } catch {
            fatalError("Could not read shared/golden/themes/derived.json: \(error)")
        }
    }()

    static func theme(_ id: String) -> GoldenFile.Theme? {
        file.themes.first { $0.id == id }
    }
}

private func rolesAsHex(_ palette: ResolvedPalette) -> [String: String] {
    Dictionary(uniqueKeysWithValues: palette.roles.map { ($0.key, $0.value.hexARGB) })
}

@Suite("Theme golden fixture")
struct ThemeGoldenTests {
    @Test func goldenListsTheCatalogueInOrder() {
        #expect(ThemeGolden.file.themes.map(\.id) == ThemeCatalogue.named.map(\.id))
        #expect(ThemeCatalogue.named.count == 24)
    }

    @Test(arguments: ThemeCatalogue.named.map(\.id), Brightness.allCases)
    func derivedPalette(_ id: String, _ brightness: Brightness) throws {
        let theme = try #require(ThemeCatalogue.theme(id: id))
        let golden = try #require(ThemeGolden.theme(id), "\(id) is missing from the golden")
        let expected = golden.variant(brightness)
        let actual = rolesAsHex(theme.palette(brightness))
        #expect(Set(actual.keys) == Set(expected.keys))
        for (role, hex) in expected.sorted(by: { $0.key < $1.key }) {
            #expect(actual[role] == hex, "\(id) \(brightness) \(role)")
        }
    }

    @Test(arguments: Brightness.allCases)
    func applePlatformPalette(_ brightness: Brightness) {
        let apple = ThemeGolden.file.platform.apple
        let expected = brightness == .dark ? apple.dark : apple.light
        let actual = rolesAsHex(ApplePlatformPalette.palette(brightness))
        #expect(actual == expected)
    }
}

@Suite("Theme model")
struct ThemeModelTests {
    @Test func hexRoundTrips() throws {
        #expect(try #require(RGBA(hex: "#1A1B26")).hexARGB == "#FF1A1B26")
        #expect(try #require(RGBA(hex: "#993C3C43")).hexARGB == "#993C3C43")
        #expect(RGBA(hex: "1A1B26") == nil)
        #expect(RGBA(hex: "#1A1B2") == nil)
        #expect(RGBA(hex: "#GGGGGG") == nil)
    }

    @Test func roundingMatchesFlutter() {
        // 0.5 / 255 above a byte rounds up, half away from zero, as Dart's round().
        #expect(RGBA(alpha: 1, red: 0.5 / 255, green: 1.5 / 255, blue: 254.5 / 255).argb32 == 0xFF01_02FF)
        #expect(RGBA(alpha: 1, red: -0.1, green: 1.2, blue: 0).argb32 == 0xFF00_FF00)
    }

    @Test func defaultAndUnknownIdsHaveNoNamedTheme() {
        #expect(ThemeCatalogue.theme(id: ThemeCatalogue.defaultThemeID) == nil)
        #expect(ThemeCatalogue.theme(id: "no-such-theme") == nil)
        #expect(ThemeCatalogue.theme(id: "gruvbox")?.label == "Gruvbox")
    }

    @Test func themeIdsAreUnique() {
        let ids = ThemeCatalogue.named.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(ThemeCatalogue.defaultThemeID))
    }

    @Test func modeParsesStoredNamesLikeFlutter() {
        #expect(ThemeMode(storedName: "dark") == .dark)
        #expect(ThemeMode(storedName: "light") == .light)
        #expect(ThemeMode(storedName: "system") == .system)
        #expect(ThemeMode(storedName: "catppuccinMocha") == .system)
        #expect(ThemeMode(storedName: nil) == .system)
    }

    @Test func preferenceKeysMatchTheFlutterApp() {
        // lib/src/services/settings_service.dart
        #expect(ThemePreferenceKeys.mode == "theme_mode")
        #expect(ThemePreferenceKeys.themeID == "theme_id")
    }

    @Test func derivedSeparatorsAndLabelsClearTheirFloors() {
        for theme in ThemeCatalogue.named {
            for brightness in Brightness.allCases {
                let p = theme.palette(brightness)
                for bg in [p.surface, p.groupedBackground] {
                    #expect(PaletteDerivation.contrastRatio(p.separator, bg) >= PaletteDerivation.minSeparatorContrast,
                            "\(theme.id) \(brightness)")
                }
            }
        }
    }
}
