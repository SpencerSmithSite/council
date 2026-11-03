import CouncilCore
import SwiftUI

/// The reader's "Aa" controls, as in Books: text size, theme, font, line
/// spacing, margins and justification. A sheet at a medium detent on iPhone
/// and a popover on iPad and Mac (see `SourceReaderView`), so the page shows
/// behind it and every change can be judged as it's made.
///
/// Writes the shared `ReaderStyle` and `ThemeStore`, so the change applies at
/// once in every window and persists (`ReaderPreferences`, `theme_id` /
/// `theme_mode`).
struct ReadingControlsView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.colorScheme) private var colorScheme

    /// The palette resolved here from the store, not taken from the
    /// environment: presented from a toolbar button, the sheet's inherited
    /// `councilPalette` lagged a theme change made in it (switching to
    /// Gruvbox and then to Dark left the rows on Gruvbox light's surface),
    /// and this sheet is where themes change.
    var body: some View {
        let palette = themes.palette(for: themes.preferredColorScheme ?? colorScheme)
        ReadingControlsForm()
            .environment(\.councilPalette, palette)
            .tint(palette.customTint)
    }
}

private struct ReadingControlsForm: View {
    @Environment(ReaderStyle.self) private var style
    @Environment(ThemeStore.self) private var themes
    @Environment(\.councilPalette) private var palette

    var body: some View {
        @Bindable var style = style
        @Bindable var themes = themes

        NavigationStack {
            Form {
                Section {
                    textSize
                    ThemeSwatches()
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    Picker("Appearance", selection: $themes.mode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .councilListRow()

                Section {
                    NavigationLink {
                        FontList()
                    } label: {
                        LabeledContent("Font") {
                            Text(style.font.label)
                                .font(style.font.previewFont)
                                .foregroundStyle(palette.secondaryLabel)
                        }
                        .foregroundStyle(palette.text)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Line Spacing")
                            .foregroundStyle(palette.text)
                        Slider(value: $style.lineSpacing, in: ReaderPreferences.lineSpacingRange, step: 0.1) {
                            Text("Line Spacing")
                        } minimumValueLabel: {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .accessibilityHidden(true)
                        } maximumValueLabel: {
                            Image(systemName: "text.line.last.and.arrowtriangle.forward")
                                .accessibilityHidden(true)
                        }
                        .accessibilityValue(Text(style.lineSpacing, format: .number.precision(.fractionLength(1))))
                    }

                    Picker("Margins", selection: $style.margins) {
                        ForEach(ReaderMargins.allCases) { margins in
                            Text(margins.label).tag(margins)
                        }
                    }
                    .foregroundStyle(palette.text)

                    Toggle("Justify Text", isOn: $style.justified)
                        .foregroundStyle(palette.text)
                }
                .councilListRow()
            }
            .formStyle(.grouped)
            .navigationTitle("Reading")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .councilScreenBackground(grouped: true)
        }
        #if os(macOS)
        .frame(width: 380, height: 460)
        #endif
    }

    /// Smaller and larger "A", as Books has them: steps of the size multiplier
    /// over the Dynamic Type body size.
    private var textSize: some View {
        HStack(spacing: 12) {
            Button {
                style.shrink()
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .disabled(!style.canShrink)
            .accessibilityLabel("Smaller Text")

            Text(style.fontSize, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryLabel)
                .frame(minWidth: 48)
                .accessibilityHidden(true)

            Button {
                style.grow()
            } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .disabled(!style.canGrow)
            .accessibilityLabel("Larger Text")
        }
        .buttonStyle(.bordered)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(style.fontSize, format: .percent.precision(.fractionLength(0))))
    }
}

/// The catalogue's themes as swatches in a row, Default first, as Books lays
/// out its themes: each a small page in the theme's own background with "Aa"
/// in its text colour, for the scheme in effect.
private struct ThemeSwatches: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.councilPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    swatch(id: ThemeCatalogue.defaultThemeID, label: "Default",
                           palette: .system(Brightness(colorScheme)), selected: themes.isDefault)
                    ForEach(ThemeCatalogue.named) { theme in
                        swatch(id: theme.id, label: theme.label,
                               palette: CouncilPalette(theme.palette(Brightness(colorScheme))),
                               selected: themes.themeID == theme.id)
                    }
                }
                .padding(.horizontal, 16)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(themes.isDefault ? ThemeCatalogue.defaultThemeID : themes.themeID, anchor: .center) }
        }
    }

    private func swatch(id: String, label: String, palette candidate: CouncilPalette, selected: Bool) -> some View {
        Button {
            themes.themeID = id
        } label: {
            VStack(spacing: 6) {
                Text("Aa")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(candidate.text)
                    .frame(width: 58, height: 58)
                    .background(candidate.isSystem ? AnyShapeStyle(.background) : AnyShapeStyle(candidate.background),
                                in: .rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(selected ? palette.accent : palette.separator, lineWidth: selected ? 2.5 : 0.5)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(candidate.accent).frame(width: 10, height: 10).padding(6)
                    }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(selected ? palette.text : palette.secondaryLabel)
                    .lineLimit(1)
                    .frame(width: 66)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .id(id)
    }
}

/// The faces, each name set in its own face, as Books' font list shows them.
private struct FontList: View {
    @Environment(ReaderStyle.self) private var style
    @Environment(\.councilPalette) private var palette

    var body: some View {
        List(ReaderFont.allCases) { font in
            Button {
                style.font = font
            } label: {
                HStack {
                    Text(font.label)
                        .font(font.previewFont)
                        .foregroundStyle(palette.text)
                    Spacer()
                    if style.font == font {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(style.font == font ? .isSelected : [])
            .councilListRow()
        }
        .navigationTitle("Font")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .councilScreenBackground(grouped: true)
    }
}

#Preview {
    Text("Behind").popover(isPresented: .constant(true)) {
        ReadingControlsView()
    }
    .environment(ReaderStyle.preview())
    .councilTheme(.preview())
}
