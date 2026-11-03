# Council for Apple platforms

The native SwiftUI app for iPhone, iPad and Mac. Decisions, layout and phases
are in [PLAN.md](PLAN.md).

- `Council/`: the app target (one multiplatform target: iOS, iPadOS, macOS)
- `CouncilCore/`: local Swift package with no UI, where the shared logic lives
- `project.yml`: XcodeGen spec for `Council.xcodeproj`

## project.yml is the source of truth

`Council.xcodeproj` is generated from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen). It's committed so you can
open it in Xcode without installing anything. Don't change project settings in
Xcode's editor, though: the next regeneration overwrites them. Change
`project.yml` and regenerate:

```sh
brew install xcodegen   # once
cd apple && xcodegen
```

Regenerate after editing `project.yml` and after adding, moving or deleting
files under `Council/`. Commit the regenerated project with the change.
`Council/Info.plist` is also generated, from the `info:` block in `project.yml`.

The version is CalVer, as in `pubspec.yaml`: `MARKETING_VERSION` is the
release date and `CURRENT_PROJECT_VERSION` is a build counter that only goes
up. Both are in `project.yml`.

## Build and test

From the repo root:

```sh
# CouncilCore unit tests (Swift Testing)
(cd apple/CouncilCore && swift test)

# App, iOS Simulator
xcodebuild -project apple/Council.xcodeproj -scheme Council \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/.build/DerivedData build CODE_SIGNING_ALLOWED=NO

# App, Mac
xcodebuild -project apple/Council.xcodeproj -scheme Council \
  -destination 'platform=macOS' \
  -derivedDataPath apple/.build/DerivedData build CODE_SIGNING_ALLOWED=NO

# CouncilCore tests through the app scheme (what CI can run)
xcodebuild -project apple/Council.xcodeproj -scheme Council \
  -destination 'platform=macOS' \
  -derivedDataPath apple/.build/DerivedData test CODE_SIGNING_ALLOWED=NO
```

`-derivedDataPath apple/.build/DerivedData` keeps build output inside the
git-ignored `apple/.build/`. Leave it off to use Xcode's usual DerivedData.

## Signing

Team `Y2Q5JVG8X5`, automatic signing, bundle ID `site.spencersmith.council`,
the same as the Flutter app, so this ships as an update to it. The Mac build
uses the hardened runtime and no App Sandbox, because it ships as a notarised
Developer ID DMG and not through the Mac App Store.
