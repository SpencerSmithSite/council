import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/updates/update_installer.dart';
import '../services/updates/update_provider.dart';
import '../services/updates/release_manifest.dart';

/// The offer of a newer Council, and the progress of accepting it.
///
/// A sheet rather than a banner because the whole flow lives in one place: the
/// offer, the download bar, and whatever is left for the reader to do
/// afterwards, which differs on every platform. A banner would have to hand off
/// to something like this the moment it was tapped anyway.
///
/// Deliberately *not* a download that starts on its own. The Android package is
/// nearly 200 MB, and beginning that unasked on whatever connection a phone
/// happens to be using — quite possibly metered, quite possibly abroad — is a
/// real cost taken without permission. So the check is automatic and the
/// download is one tap.
class UpdateSheet extends StatelessWidget {
  const UpdateSheet({super.key});

  /// Raises the sheet. Safe to call when nothing is available: it does nothing.
  static Future<void> show(BuildContext context) {
    final updates = context.read<UpdateProvider>();
    if (updates.release == null) return Future.value();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ChangeNotifierProvider<UpdateProvider>.value(
        value: updates,
        child: const UpdateSheet(),
      ),
    );
  }

  static String _size(int megabytes) =>
      megabytes >= 1024 ? '${(megabytes / 1024).toStringAsFixed(1)} GB'
                        : '$megabytes MB';

  @override
  Widget build(BuildContext context) {
    final updates = context.watch<UpdateProvider>();
    final release = updates.release;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // The sheet is dismissed by whoever installed or cancelled; if the release
    // has gone there is nothing left to draw.
    if (release == null) return const SizedBox.shrink();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          8,
          24,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Council ${release.version.name} is available',
                style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              updates.currentVersion == null
                  ? 'A newer version has been published.'
                  : 'You have ${updates.currentVersion!.name}.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (release.bytes != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.download_outlined,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(_size(release.megabytes),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ],
            const SizedBox(height: 16),
            _Body(release: release, updates: updates),
            const SizedBox(height: 20),
            _Actions(release: release, updates: updates),
          ],
        ),
      ),
    );
  }
}

/// The middle of the sheet: what is happening, or what will happen.
class _Body extends StatelessWidget {
  final PlatformRelease release;
  final UpdateProvider updates;

  const _Body({required this.release, required this.updates});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    switch (updates.stage) {
      case UpdateStage.downloading:
        final progress = updates.progress;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Null while the size is unknown, which draws the indeterminate
            // bar. A determinate bar with no value drawn full is how the model
            // download used to report a download that had not started.
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(
              progress == null
                  ? 'Downloading…'
                  : 'Downloading… ${(progress * 100).round()}%',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        );

      case UpdateStage.ready:
        return Text(
          _readyText,
          style: theme.textTheme.bodyMedium,
        );

      case UpdateStage.failed:
        return Text(
          updates.error ?? 'The update could not be downloaded.',
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
        );

      case UpdateStage.handedOff:
        return Text(_handedOffText, style: theme.textTheme.bodyMedium);

      default:
        return Text(
          updates.goesToStore
              ? 'Updates for iPhone and iPad come through TestFlight.'
              : 'Council will download the update and hand it to '
                  '${_installerName()} to install.',
          style: theme.textTheme.bodyMedium,
        );
    }
  }

  String _installerName() => switch (release.platform) {
        'android' => 'Android',
        'macos' => 'the Finder',
        'windows' => 'the installer',
        _ => 'your system',
      };

  String get _readyText => switch (release.platform) {
        'windows' =>
          'Downloaded and verified. Council has to close for the installer to '
              'replace it.',
        'linux' =>
          'Downloaded and verified. Council cannot replace a running AppImage, '
              'so the new one will be saved and its folder opened.',
        'macos' =>
          'Downloaded and verified. The disk image will open — drag Council to '
              'Applications, replacing the old copy.',
        _ => 'Downloaded and verified.',
      };

  String get _handedOffText => switch (release.platform) {
        'ios' => 'TestFlight has been opened.',
        'linux' =>
          'Saved to ${updates.downloadedFile?.path ?? "your updates folder"}. '
              'It is executable and ready to run.',
        _ => 'The installer is open. Follow it to finish updating.',
      };
}

class _Actions extends StatelessWidget {
  final PlatformRelease release;
  final UpdateProvider updates;

  const _Actions({required this.release, required this.updates});

  Future<void> _install(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final result = await updates.install();
    if (result == null) return;

    switch (result.outcome) {
      case InstallOutcome.needsPermission:
        messenger.showSnackBar(const SnackBar(
          content: Text(
            'Allow Council to install unknown apps, then tap Install again.',
          ),
        ));
      case InstallOutcome.saved:
        // Linux: nothing further happens on its own, so the sheet stays up
        // saying where the file is.
        break;
      case InstallOutcome.handedOff:
        navigator.pop();
        // Windows only, and not optional: the installer cannot overwrite
        // Council's executable while Council is running it. Inno Setup would
        // otherwise stop and ask the reader to close the app it was launched
        // from, which is a confusing thing to be asked by an updater. The
        // button that leads here says "Install and quit" for this reason.
        if (Platform.isWindows) exit(0);
      case InstallOutcome.failed:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final buttons = <Widget>[];

    switch (updates.stage) {
      case UpdateStage.downloading:
        buttons.add(TextButton(
          onPressed: updates.cancelDownload,
          child: const Text('Cancel'),
        ));

      case UpdateStage.ready:
        buttons.addAll([
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => _install(context),
            child: Text(release.platform == 'windows'
                ? 'Install and quit'
                : 'Install'),
          ),
        ]);

      case UpdateStage.handedOff:
        buttons.add(FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ));

      default:
        buttons.addAll([
          TextButton(
            onPressed: () {
              updates.dismiss();
              Navigator.of(context).pop();
            },
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () async {
              if (updates.goesToStore) {
                await updates.openStore();
              } else {
                await updates.download();
              }
            },
            child: Text(updates.goesToStore
                ? 'Open TestFlight'
                : updates.stage == UpdateStage.failed
                    ? 'Try again'
                    : 'Download'),
          ),
        ]);
    }

    // Wrap, not Row: "Install and quit" beside "Later" is wider than a narrow
    // phone gives a sheet once the text is scaled up.
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: buttons,
      ),
    );
  }
}
