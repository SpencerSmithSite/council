# Golden update-check fixture

`updates.json` records what the Flutter app's `lib/src/services/updates/`
(`app_version.dart`, `release_manifest.dart`) makes of:

- **versions**: version strings, with and without an explicit build, parsed by
  `AppVersion.tryParse` (`result` is null when it refuses one);
- **comparisons**: pairs of versions, their ordering and equality;
- **fileNames**: download URLs and the staging file name `PlatformRelease.fileName`
  makes of each;
- **manifests**: whole `updates.json` bodies (as strings, so `7` and `7.0` stay
  distinct) and what `ReleaseManifest.fromJson` makes of them, or null where
  `UpdateService.fetchManifest` would give up (not an object, or `fromJson`
  threw). The first case is the live manifest as of 2026-11-04.

The SwiftUI app in `apple/` ports both files to `CouncilCore/Updates/` and has to
reproduce this file exactly (`UpdatesGoldenTests`). The Flutter side is held to
it by `test/updates_golden_test.dart`, which writes the outputs and runs in the
ordinary `flutter test` suite.

Both apps read the one `updates.json` on the site, so they must agree on which
release it offers. The cases pin the Dart behaviour that is easy to get wrong
elsewhere: `int.tryParse` trimming whitespace and reading `0x1A` as hex, the
text being split at the *first* `+`, `is int` ignoring `7.0`, `as String?`
failing the whole manifest (not just the entry) when a field has the wrong
type, and `Uri.parse` lower-casing the scheme and host.

## Regenerating and verifying

The inputs are written by hand: add a case by adding an entry with its input
fields only (`raw`/`build`, `a`/`b`, `url`, or `id`/`json`), then run the update
test to fill in the outputs. Never edit an output by hand.

```sh
flutter test test/updates_golden_test.dart                                   # verify
flutter test test/updates_golden_test.dart --dart-define=UPDATE_GOLDENS=true # rewrite outputs
```

Use the CI-pinned Flutter (`~/development/flutter-3.44.8/bin/flutter`). Its
`pub get` rewrites `pubspec.lock`; restore that with `git checkout pubspec.lock`
before committing. After an intended change to the Dart, regenerate and make the
Swift port follow.
