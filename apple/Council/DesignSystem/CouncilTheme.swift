import CouncilCore
import SwiftUI

// How a theme reaches the screen.
//
// Glass rules (apple/PLAN.md, "Themes with real glass"):
//
// * Navigation bars, toolbars, the tab bar and the sidebar stay the system's
//   own Liquid Glass. Nothing here sets a toolbar background, a bar colour or
//   a UIKit appearance proxy. Glass samples whatever is beneath it, so over a
//   themed page it picks up that theme's colour by itself; painting a bar
//   opaque would throw that away.
// * A custom theme paints *content*: the page behind scroll views, the rows,
//   the separators, the tint. "Default" paints nothing at all: system
//   semantic colours, system tint, system backgrounds.
// * Reduce Transparency and Increase Contrast are left to the system. The
//   glass becomes frosted or solid by itself when asked to, and Default's
//   colours are the dynamic system ones, which follow Increase Contrast.
//   Nothing here reads those settings to second-guess them.

extension View {
    /// Applies the chosen theme to a whole window: the light/dark mode, the
    /// accent as tint, the palette behind scroll content, and the palette in
    /// the environment (`\.councilPalette`) along with the store itself, for
    /// `ThemePickerView`.
    ///
    /// Apply once per scene root (the main `WindowGroup`, and the Mac's
    /// `Settings` scene).
    func councilTheme(_ store: ThemeStore) -> some View {
        modifier(CouncilThemeModifier(store: store))
    }

    /// The themed page behind one screen's content. Use on the root view of a
    /// screen inside a `NavigationStack` (or a split view column): navigation
    /// containers draw their own background over anything set outside them,
    /// so the page colour has to be handed to each container from inside it.
    ///
    /// For Default it hands over the system's own page colour:
    /// `systemGroupedBackground` when `grouped` (cards or inset sections on a
    /// plain scroll view, which `List` and `Form` get by themselves), the plain
    /// system background otherwise.
    func councilScreenBackground(grouped: Bool = false) -> some View {
        modifier(ScreenBackground(grouped: grouped))
    }

    /// A themed list or form row: the palette's surface behind it and its
    /// separator between rows. Does nothing for Default.
    func councilListRow() -> some View {
        modifier(ListRowStyle())
    }
}

private struct CouncilThemeModifier: ViewModifier {
    let store: ThemeStore
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        // The forced scheme if there is one: the environment only catches up
        // with `.preferredColorScheme` after the window has switched.
        let scheme = store.preferredColorScheme ?? systemScheme
        let palette = store.palette(for: scheme)

        // No `if` on the theme anywhere in here: switching between Default
        // and a custom theme must not change the view's structure, or every
        // screen below would lose its state (and the theme picker would pop
        // itself) on each tap.
        content
            .environment(\.councilPalette, palette)
            .environment(store)
            .tint(palette.customTint)
            .scrollContentBackground(palette.isSystem ? .automatic : .hidden)
            .background {
                (palette.isSystem ? Color.clear : palette.background)
                    .ignoresSafeArea()
            }
            .preferredColorScheme(store.preferredColorScheme)
    }
}

private struct ScreenBackground: ViewModifier {
    let grouped: Bool
    @Environment(\.councilPalette) private var palette

    func body(content: Content) -> some View {
        // A style either way rather than an `if`, so switching theme keeps
        // the screen's identity (and its scroll position).
        #if os(macOS)
        // No `.navigation` container placement on the Mac; the page goes
        // behind the content instead, under the toolbar's glass too.
        content.background(style, ignoresSafeAreaEdges: .all)
        #else
        content.containerBackground(style, for: .navigation)
        #endif
    }

    private var style: AnyShapeStyle {
        if !palette.isSystem || grouped { return AnyShapeStyle(palette.background) }
        return AnyShapeStyle(.background)
    }
}

private struct ListRowStyle: ViewModifier {
    @Environment(\.councilPalette) private var palette

    func body(content: Content) -> some View {
        content
            .listRowBackground(palette.isSystem ? nil : palette.surface)
            .listRowSeparatorTint(palette.isSystem ? nil : palette.separator)
    }
}

// MARK: - Previews

/// A typical screen: a grouped list under a glass navigation bar and toolbar,
/// for checking a palette against real system chrome.
private struct ThemedSampleScreen: View {
    @Environment(\.councilPalette) private var palette

    var body: some View {
        NavigationStack {
            List {
                Section("Library") {
                    ForEach(["Augustine, Confessions", "Calvin, Institutes", "Aquinas, Summa"], id: \.self) { title in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).foregroundStyle(palette.text)
                            Text("Last read yesterday")
                                .font(.footnote)
                                .foregroundStyle(palette.secondaryLabel)
                        }
                        .councilListRow()
                    }
                }
                Section {
                    Label("The AI backend is offline", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.onErrorContainer)
                        .listRowBackground(palette.errorContainer)
                    Button("Open settings") {}
                        .councilListRow()
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") {}
                }
            }
            .councilScreenBackground()
        }
    }
}

#Preview("Default") {
    ThemedSampleScreen().councilTheme(.preview())
}

#Preview("Gruvbox, light") {
    ThemedSampleScreen().councilTheme(.preview(themeID: "gruvbox", mode: .light))
}

#Preview("Tokyo Night, dark") {
    ThemedSampleScreen().councilTheme(.preview(themeID: "tokyonight", mode: .dark))
}
