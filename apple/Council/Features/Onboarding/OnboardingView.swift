import SwiftUI

/// First-run setup. Mirrors `OnboardingScreen` in
/// lib/src/screens/onboarding_screen.dart. Calls `onFinish` once the reader
/// is through it; whoever presents it records `has_onboarded`.
struct OnboardingView: View {
    var onFinish: () -> Void

    var body: some View {
        // TODO(Phase 6): onboarding.
        ContentUnavailableView("Welcome to Council", systemImage: "books.vertical")
    }
}
