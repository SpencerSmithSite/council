import CouncilCore
import SwiftUI

/// Settings, shown in a sheet on iPhone and iPad and as the Settings scene on
/// the Mac. Both callers wrap it in a NavigationStack, so it carries none of
/// its own and its rows can push.
///
/// The native counterpart of `SettingsScreen` in
/// lib/src/screens/settings_screen.dart, as a grouped `Form` in its order:
///
/// - **Appearance**: Theme (pushes `ThemePickerView`) and Font Size. Flutter
///   gives Font Size a "Reading" group of its own; with one row it reads
///   better beside the theme. It is the reader's `font_size` multiplier,
///   bound to the same `ReaderStyle` the reader's Aa sheet changes, so the
///   two always agree.
/// - **Library**: Content Packs (Flutter's "Manage content", pushing
///   `BrowseView`) and whether semantic search is running.
/// - **AI**: the backend (pushes `AIBackendView`) and Show Citations
///   (`show_citations`), which the Ask tab reads to hide the sources under
///   each answer.
/// - **Updates**: `UpdateSettingsSection`, owned by the updates feature.
/// - **About**: the version.
/// - **Show Onboarding** (`OnboardingGate.replay`) and **Reset All
///   Settings**, confirmed as Flutter confirms it.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ThemeStore.self) private var themeStore
    @Environment(ReaderStyle.self) private var readerStyle
    @Environment(\.councilPalette) private var palette

    /// `getShowCitations` in Dart: true unless switched off.
    @AppStorage(AppSettings.showCitationsKey) private var showCitations = AppSettings.defaultShowCitations

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false

    var body: some View {
        Form {
            appearanceSection
            librarySection
            aiSection
            UpdateSettingsSection()
            Section("About") {
                LabeledContent("Version", value: Self.version)
            }
            .councilListRow()
            resetSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .councilScreenBackground(grouped: true)
        #if os(macOS)
        // The Settings window sizes itself to this: tall enough to show every
        // section without scrolling at the default text size, wide enough
        // for the Font Size slider and the pushed Browse and AI screens.
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 680)
        #endif
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            NavigationLink {
                ThemePickerView()
            } label: {
                // Flutter's `_themeLabel`: "Default", or the theme's name.
                LabeledContent {
                    Text(themeStore.theme?.label ?? "Default")
                } label: {
                    Label("Theme", systemImage: "paintpalette")
                }
            }
            FontSizeRow(style: readerStyle)
        }
        .councilListRow()
    }

    // MARK: - Library

    private var librarySection: some View {
        Section {
            NavigationLink {
                BrowseView()
            } label: {
                LabeledContent {
                    Text(installedSummary)
                } label: {
                    Label("Content Packs", systemImage: "shippingbox")
                }
            }
            LabeledContent("Semantic Search", value: semanticStatus)
        } header: {
            Text("Library")
        } footer: {
            if model.semantic == .unavailable {
                Text("Searching by meaning couldn't start on this device, so search matches words only.")
            }
        }
        .councilListRow()
    }

    /// Flutter's subtitle on "Manage content", shortened to fit as a value:
    /// how many collections are installed, or "None".
    private var installedSummary: String {
        let count = model.packLibrary.installed.count
        return count == 0 ? String(localized: "None") : String(localized: "\(count) Installed")
    }

    private var semanticStatus: String {
        switch model.semantic {
        case .loading: String(localized: "Loading…")
        case .available: String(localized: "On")
        case .unavailable: String(localized: "Unavailable")
        }
    }

    // MARK: - AI

    private var aiSection: some View {
        Section {
            NavigationLink {
                AIBackendView()
            } label: {
                // The value says what answers questions now, so the
                // reader needn't open the screen to find out.
                LabeledContent {
                    Text(model.inference.backendName)
                } label: {
                    Label("AI Backend", systemImage: "sparkles")
                }
            }
            Toggle(isOn: $showCitations) {
                Label("Show Citations", systemImage: "quote.bubble")
            }
        } header: {
            Text("AI")
        } footer: {
            Text("Citations name the source behind each answer, with its tradition and provenance.")
        }
        .councilListRow()
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            // Flutter's other whole-app action: the welcome walkthrough again.
            // On iPhone and iPad Settings is itself a sheet, and a cover can't
            // be presented over the app while it is up, so it closes first.
            // On the Mac it is its own window and `dismiss` does nothing.
            Button("Show Onboarding") {
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    model.onboarding.replay()
                }
            }
            .frame(maxWidth: .infinity)
            Button("Reset All Settings", role: .destructive) {
                confirmingReset = true
            }
            .frame(maxWidth: .infinity)
            .confirmationDialog("Reset All Settings?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { resetAll() }
            } message: {
                Text("This will reset all preferences to defaults.")
            }
        }
        .councilListRow()
    }

    /// `SettingsProvider.resetAll`: clear the preference keys, then put every
    /// setting held in memory back to its default so the screens change at
    /// once, as Flutter's `load()` after `clearAll` does.
    ///
    /// The stores write through to `UserDefaults` when assigned, so they are
    /// assigned first and the keys removed after, leaving the keys absent
    /// (which is what Dart's `clearAll` leaves) rather than holding default
    /// values. `show_citations` is an `@AppStorage` and follows the removal
    /// by itself. User data is never touched: see `AppSettings.clearAll`.
    private func resetAll() {
        themeStore.themeID = ThemeCatalogue.defaultThemeID
        themeStore.mode = .system
        readerStyle.fontSize = ReaderPreferences.defaultFontSize
        readerStyle.font = ReaderPreferences.defaultFont
        readerStyle.lineSpacing = ReaderPreferences.defaultLineSpacing
        readerStyle.margins = ReaderPreferences.defaultMargins
        readerStyle.justified = ReaderPreferences.defaultJustified
        AppSettings.clearAll()
    }

    /// "2026.10.29 (8)": the CalVer release date and the build counter, both
    /// set in project.yml and carried into Info.plist.
    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(release) (\(build))"
    }()
}

/// Flutter's Font Size row and slider: the multiplier as a value ("1.2×"),
/// then a slider from 0.8 to 1.5 in tenths (`divisions: 7`), with small and
/// large type glyphs at its ends as in the system's Text Size control.
private struct FontSizeRow: View {
    @Bindable var style: ReaderStyle
    @Environment(\.councilPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(Self.label(style.fontSize))
                    .monospacedDigit()
            } label: {
                Label("Font Size", systemImage: "textformat.size")
            }
            Slider(value: steppedSize, in: ReaderPreferences.fontSizeRange, step: ReaderStyle.fontSizeStep) {
                Text("Font Size")
            } minimumValueLabel: {
                Image(systemName: "textformat.size.smaller")
                    .foregroundStyle(palette.secondaryLabel)
                    .accessibilityHidden(true)
            } maximumValueLabel: {
                Image(systemName: "textformat.size.larger")
                    .foregroundStyle(palette.secondaryLabel)
                    .accessibilityHidden(true)
            }
            .labelsHidden()
            .accessibilityValue(Self.label(style.fontSize))
        }
    }

    /// The slider's value rounded to tenths, so a drag lands on 1.2 rather
    /// than 1.2000000000000002 and the Aa sheet's steps line up with it.
    private var steppedSize: Binding<Double> {
        Binding {
            style.fontSize
        } set: { value in
            let range = ReaderPreferences.fontSizeRange
            style.fontSize = min(max((value * 10).rounded() / 10, range.lowerBound), range.upperBound)
        }
    }

    static func label(_ size: Double) -> String {
        String(format: "%.1f×", size)
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .councilTheme(.preview())
        .environment(ReaderStyle.preview())
        .environment(AppModel())
}
