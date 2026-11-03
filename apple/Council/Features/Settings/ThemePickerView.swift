import CouncilCore
import SwiftUI

/// The theme picker: the light/dark mode on top, then every theme as a card
/// with live previews of its light and dark variants. The native counterpart
/// of lib/src/screens/theme_screen.dart, with "Default" first and the rest in
/// catalogue order (shared/themes.json).
///
/// Reads the `ThemeStore` from the environment, which `.councilTheme` puts
/// there, so it can be pushed from Settings with no arguments.
struct ThemePickerView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(\.councilPalette) private var palette

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        @Bindable var store = store

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Appearance")
                    Picker("Appearance", selection: $store.mode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Theme")
                    LazyVGrid(columns: columns, spacing: 12) {
                        ThemeCard(
                            label: "Default",
                            light: .system(.light),
                            dark: .system(.dark),
                            selected: store.isDefault
                        ) {
                            store.themeID = ThemeCatalogue.defaultThemeID
                        }
                        ForEach(ThemeCatalogue.named) { theme in
                            ThemeCard(
                                label: theme.label,
                                light: CouncilPalette(theme.palette(.light)),
                                dark: CouncilPalette(theme.palette(.dark)),
                                selected: store.themeID == theme.id
                            ) {
                                store.themeID = theme.id
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Theme")
        .councilScreenBackground(grouped: true)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

private struct SectionHeader: View {
    @Environment(\.councilPalette) private var palette
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(palette.secondaryLabel)
            .padding(.leading, 4)
    }
}

/// One theme: its light and dark previews side by side, the name, and a check
/// when chosen. The card itself sits on the *current* theme's surface, so the
/// grid reads as part of the screen while the previews show the candidates.
private struct ThemeCard: View {
    @Environment(\.councilPalette) private var palette
    let label: String
    let light: CouncilPalette
    let dark: CouncilPalette
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ThemeSwatch(palette: light)
                    ThemeSwatch(palette: dark)
                }
                .accessibilityHidden(true)

                HStack(spacing: 6) {
                    Text(label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? palette.accent : palette.secondaryLabel)
                        .imageScale(.large)
                }
            }
            .padding(10)
            .background(palette.surface, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? palette.accent : palette.separator, lineWidth: selected ? 2 : 0.5)
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A miniature screen in one variant: the page, a card on it with a line of
/// body text and a line of secondary text, and the accent as a swatch and a
/// button. Default's system colours are dynamic, so the swatch pins its own
/// colour scheme to show each variant whatever the window is in.
private struct ThemeSwatch: View {
    let palette: CouncilPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(palette.text).frame(height: 4)
                    .padding(.trailing, 14)
                Capsule().fill(palette.secondaryLabel).frame(width: 30, height: 4)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(palette.separator, lineWidth: 0.5)
            }

            HStack(spacing: 4) {
                Circle().fill(palette.accent).frame(width: 10, height: 10)
                Spacer(minLength: 0)
                Capsule().fill(palette.accent).frame(width: 22, height: 10)
                    .overlay(Capsule().fill(palette.onAccent).frame(width: 10, height: 2))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .top)
        .background(palette.background, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .environment(\.colorScheme, palette.brightness.colorScheme)
    }
}

#Preview("Default") {
    NavigationStack {
        ThemePickerView()
    }
    .councilTheme(.preview())
}

#Preview("Catppuccin, dark") {
    NavigationStack {
        ThemePickerView()
    }
    .councilTheme(.preview(themeID: "catppuccin", mode: .dark))
}

#Preview("Solarized Light, light") {
    NavigationStack {
        ThemePickerView()
    }
    .councilTheme(.preview(themeID: "solarized-light", mode: .light))
}
