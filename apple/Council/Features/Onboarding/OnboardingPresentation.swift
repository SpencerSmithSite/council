import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// Presents onboarding over this view while `AppModel.onboarding` asks
    /// for it: a full-screen cover on iPhone, where Apple's own welcome flows
    /// take the whole screen, and a sheet on iPad and the Mac, sized like a
    /// window's modal rather than stretched across a large display.
    ///
    /// Apply once, to the root of each window (`RootView`). On the Mac every
    /// window shows it and all of them close together, since the gate is one
    /// per process.
    func onboardingPresentation() -> some View {
        modifier(OnboardingPresentation())
    }
}

private struct OnboardingPresentation: ViewModifier {
    @Environment(AppModel.self) private var model
    /// Optional so a preview without a theme (RootView's) still renders.
    @Environment(ThemeStore.self) private var themeStore: ThemeStore?

    func body(content: Content) -> some View {
        @Bindable var gate = model.onboarding
        #if os(iOS)
        // The idiom rather than the size class: an iPad resized into a narrow
        // split would otherwise tear down the sheet mid-setup to re-present
        // it as a cover, losing the reader's choices.
        if Self.isPhone {
            content.fullScreenCover(isPresented: $gate.isPresented) { onboarding }
        } else {
            content.sheet(isPresented: $gate.isPresented) { onboarding }
        }
        #else
        content.sheet(isPresented: $gate.isPresented) { onboarding }
        #endif
    }

    private var onboarding: some View {
        OnboardingView(onFinish: { model.onboarding.finish() })
            // Swiping it away would be a Skip nobody chose; Skip is on every
            // step.
            .interactiveDismissDisabled()
            // A presentation takes its colour scheme from its own content,
            // not the window's, so a forced light or dark theme is applied
            // again here.
            .preferredColorScheme(themeStore?.preferredColorScheme)
    }

    #if os(iOS)
    private static let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    #endif
}
