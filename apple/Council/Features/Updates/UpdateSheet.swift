import CouncilCore
import SwiftUI

/// The offer of a newer Council, and the progress of accepting it. Mirrors
/// `UpdateSheet` in lib/src/widgets/update_sheet.dart.
///
/// A sheet rather than a banner because the whole flow lives in one place:
/// the offer, the download bar, and whatever is left to do afterwards. And
/// the download never starts by itself (the Dart's reasoning): checking is
/// automatic, downloading is one tap, because tens of megabytes on whatever
/// connection the reader happens to be on is their cost to agree to.
///
/// One addition to Flutter's sheet: the release notes from `updates.json`,
/// which the Dart parses but never shows.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var updates: UpdateModel { model.updates }
    private var flow: UpdateFlow { updates.flow }

    /// The scrolling part's natural height and the buttons', for the sheet's
    /// fitted detent.
    @State private var bodyHeight: CGFloat = 240
    @State private var actionsHeight: CGFloat = 80
    private var fittedHeight: CGFloat { bodyHeight + actionsHeight + 24 }

    var body: some View {
        Group {
            if let release = flow.release {
                content(release)
            } else {
                // Dismissed by whoever installed or cancelled: nothing left
                // to draw.
                Color.clear.onAppear { dismiss() }
            }
        }
        .councilScreenBackground()
        #if os(iOS)
        // As tall as what it says (measured below), never half a screen of
        // nothing; pull it up for long notes.
        .presentationDetents([.height(fittedHeight), .large])
        #else
        .frame(width: 440)
        #endif
    }

    private func content(_ release: PlatformRelease) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(release)
                    if let notes = flow.update?.notes {
                        Text(notes)
                            .foregroundStyle(palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    status(release)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            actions(release)
                .padding([.horizontal, .bottom], 24)
                .padding(.top, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionsHeight = $0 }
        }
    }

    private func header(_ release: PlatformRelease) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Council \(release.version.name) is available")
                .font(.title2.bold())
                .foregroundStyle(palette.text)
            Text("You have \(flow.currentVersion.name).")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryLabel)
            if release.bytes != nil {
                // Stated up front, before anything downloads.
                Label(UpdateFlow.sizeText(megabytes: release.megabytes), systemImage: "arrow.down.circle")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.top, 8)
            }
        }
    }

    /// The middle of the sheet: what is happening, or what will happen
    /// (Dart's `_Body`).
    @ViewBuilder
    private func status(_ release: PlatformRelease) -> some View {
        switch flow.stage {
        case .downloading:
            VStack(alignment: .leading, spacing: 8) {
                // Indeterminate while the size is unknown, never a full bar
                // standing in for one that hasn't started.
                if let progress = flow.progress {
                    ProgressView(value: progress)
                    Text("Downloading… \(Int((progress * 100).rounded()))%")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryLabel)
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text("Downloading…")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryLabel)
                }
            }
        case .ready:
            if installing {
                Label {
                    Text("Checking and installing…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(palette.text)
            } else {
                Text(readyText).foregroundStyle(palette.text)
            }
        case .failed:
            Text(flow.error ?? String(localized: "The update could not be downloaded."))
                .foregroundStyle(palette.error)
        case .handedOff:
            Text(handedOffText).foregroundStyle(palette.text)
        default:
            Text(offerText).foregroundStyle(palette.text)
        }
    }

    private var installing: Bool {
        #if os(macOS)
        updates.installing
        #else
        false
        #endif
    }

    private var offerText: String {
        if flow.goesToStore { return String(localized: "Updates for iPhone and iPad come through TestFlight.") }
        if updates.replacesInPlace {
            return String(localized: "Council will download the update, check that it is signed by its developer, and replace itself.")
        }
        return String(localized: "Council will download the update and hand it to the Finder to install.")
    }

    private var readyText: String {
        if updates.replacesInPlace {
            return String(localized: "Downloaded and verified. Council will replace itself with the new version and reopen.")
        }
        return String(localized: "Downloaded and verified. The disk image will open — drag Council to Applications, replacing the old copy.")
    }

    private var handedOffText: String {
        if flow.goesToStore { return String(localized: "TestFlight has been opened.") }
        #if os(macOS)
        if updates.relaunching { return String(localized: "Council is reopening with the new version.") }
        if let reason = updates.fallbackReason {
            return String(localized: "\(reason) The disk image is open instead: drag Council to Applications, replacing the old copy.")
        }
        #endif
        return String(localized: "The installer is open. Follow it to finish updating.")
    }

    /// Dart's `_Actions`.
    @ViewBuilder
    private func actions(_ release: PlatformRelease) -> some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            switch flow.stage {
            case .downloading:
                Button("Cancel", role: .cancel) { flow.cancelDownload() }
                    .buttonStyle(.glass)
            case .ready:
                Button("Later") { dismiss() }
                    .buttonStyle(.glass)
                    .disabled(installing)
                Button(updates.replacesInPlace ? "Install and Relaunch" : "Install") {
                    install()
                }
                .buttonStyle(.glassProminent)
                .disabled(installing)
            case .handedOff:
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
            default:
                Button("Not Now") {
                    flow.dismiss()
                    dismiss()
                }
                .buttonStyle(.glass)
                Button(primaryTitle) { primary(release) }
                    .buttonStyle(.glassProminent)
            }
        }
        .controlSize(.large)
    }

    private var primaryTitle: LocalizedStringKey {
        if flow.goesToStore { return "Open TestFlight" }
        return flow.stage == .failed ? "Try Again" : "Download"
    }

    private func primary(_ release: PlatformRelease) {
        if flow.goesToStore {
            openURL(release.url) { updates.storeOpened($0) }
        } else {
            Task { await flow.download() }
        }
    }

    private func install() {
        #if os(macOS)
        Task { await updates.install() }
        #endif
    }
}

extension View {
    /// The launch check and the sheet it raises: `RootView` carries this.
    func updateLaunchOffer() -> some View {
        modifier(UpdateLaunchOffer())
    }
}

/// Runs the once-per-launch check after the window appears and raises the
/// sheet if it finds something (Dart's `MainScreen` post-frame check).
///
/// Every Mac window runs this, so the first to appear claims the offer and
/// only that one raises the sheet.
private struct UpdateLaunchOffer: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .task {
                if model.updates.launchOfferOwner == nil { model.updates.launchOfferOwner = id }
                await model.updates.checkOnLaunch()
            }
            .sheet(isPresented: offerBinding) {
                UpdateSheet()
            }
    }

    private var offerBinding: Binding<Bool> {
        Binding {
            model.updates.showsLaunchOffer && model.updates.launchOfferOwner == id
        } set: { shown in
            if !shown { model.updates.showsLaunchOffer = false }
        }
    }
}
