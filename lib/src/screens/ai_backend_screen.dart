import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/inference/cloud_backend.dart';
import '../services/inference/inference_provider.dart';
import '../services/device_storage.dart';
import '../services/inference/local_model_backend.dart';
import '../services/inference/platform_llm_backend.dart';
import '../services/ollama_service.dart';
import '../theme/glass_controls.dart';

/// Choose and configure how answers are generated.
///
/// The app is offline-first, so the default is no AI at all and every option
/// states plainly whether it sends anything off the device.
class AiBackendScreen extends StatelessWidget {
  const AiBackendScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final inference = context.watch<InferenceProvider>();
    final top = MediaQuery.of(context).padding.top;

    // Full-bleed like the Settings screen it is pushed from: a scrolling large
    // title with a floating round back button rather than a solid app bar.
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.only(
                  bottom: 16 + MediaQuery.of(context).padding.bottom),
              children: [
                const LargeTitle('AI Backend'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _StatusBanner(inference: inference),
                      const SizedBox(height: 16),

                      // First when the device has one. It needs no host, no
                      // key and no download, so for a reader who qualifies it
                      // is the shortest route from "no AI" to a grounded
                      // answer — and it is the only generating backend that
                      // keeps the app's own privacy claim intact.
                      if (inference.offersPlatformLlm) ...[
                        _Option(
                          id: PlatformLlmBackend.backendId,
                          title: const PlatformLlmBackend().displayName,
                          subtitle: const PlatformLlmBackend().description,
                          icon: Icons.auto_awesome_outlined,
                          selected: inference.backendId ==
                              PlatformLlmBackend.backendId,
                        ),
                        if (!inference.platformLlmReady)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: _PlatformLlmNotice(inference: inference),
                          ),
                        const SizedBox(height: 12),
                      ],

                      _Option(
                        id: 'none',
                        title: 'No AI — search only',
                        subtitle:
                            'Browse and search the library. Nothing is '
                            'generated and nothing leaves your device.',
                        icon: Icons.menu_book_outlined,
                        selected: inference.backendId == 'none',
                      ),
                      const SizedBox(height: 12),

                      // Offered wherever the engine runs, built-in model or
                      // not: Apple Intelligence is a reason to default to it,
                      // not a reason to withhold a model the reader may prefer.
                      if (inference.offersLocalModel) ...[
                        _Option(
                          id: LocalModelBackend.backendId,
                          title: 'Download a local model',
                          subtitle:
                              'A one-time download that then runs entirely on '
                              'this device, with no account and no key. You '
                              'choose the size — from '
                              '${inference.localModel.approximateSize} upward.',
                          icon: Icons.download_outlined,
                          selected: inference.backendId ==
                              LocalModelBackend.backendId,
                        ),
                        if (inference.backendId == LocalModelBackend.backendId)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: _LocalModelSettings(),
                          ),
                        const SizedBox(height: 12),
                      ],

                      _Option(
                        id: 'ollama',
                        title: 'Ollama',
                        subtitle:
                            'A model running on this machine, or on another '
                            'one you can reach over your network or VPN.',
                        icon: Icons.dns_outlined,
                        selected: inference.backendId == 'ollama',
                      ),
                      if (inference.backendId == 'ollama')
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: _OllamaSettings(),
                        ),
                      const SizedBox(height: 12),

                      _Option(
                        id: 'cloud',
                        title: 'Your own API key',
                        subtitle: 'Claude, ChatGPT, Gemini or Grok, billed to '
                            'your own account.',
                        icon: Icons.vpn_key_outlined,
                        selected: inference.backendId == 'cloud',
                      ),
                      if (inference.backendId == 'cloud')
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: _CloudSettings(),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: top + 8,
            left: AppleMetrics.edgeInset,
            child: GlassBubble(
              icon: AppIcons.back,
              tooltip: 'Back',
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final InferenceProvider inference;

  const _StatusBanner({required this.inference});

  @override
  Widget build(BuildContext context) {
    final status = inference.status;
    if (status == null) return const SizedBox.shrink();

    final ok = status.available;
    final scheme = Theme.of(context).colorScheme;

    // The tint carries the state and the theme; the icon and the hairline carry
    // the attention. Filling the card with saturated red read as an alert
    // pasted over the chosen theme rather than part of it — and every one of
    // these is a condition the reader can fix, not a failure.
    final accent = ok ? scheme.primary : scheme.error;
    return Card(
      color: ok ? scheme.secondaryContainer : scheme.errorContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: accent.withValues(alpha: 0.45)),
      ),
      child: ListTile(
        leading: Icon(ok ? Icons.check_circle : Icons.error_outline,
            color: accent),
        title: Text(
          status.detail ?? (ok ? 'Ready' : 'Not available'),
          style: TextStyle(
            color: ok ? scheme.onSecondaryContainer : scheme.onErrorContainer,
          ),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          color: accent,
          tooltip: 'Re-check',
          onPressed: inference.refreshStatus,
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;

  const _Option({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        onTap: () => context.read<InferenceProvider>().setBackend(id),
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        isThreeLine: true,
        trailing: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
    );
  }
}

class _OllamaSettings extends StatefulWidget {
  const _OllamaSettings();

  @override
  State<_OllamaSettings> createState() => _OllamaSettingsState();
}

class _OllamaSettingsState extends State<_OllamaSettings> {
  late final TextEditingController _host;
  late final TextEditingController _model;

  /// Models the host reported on the last successful test, or null before a
  /// test has run. Once populated, the free-text model field is replaced by a
  /// dropdown of exactly what the server actually has pulled — no more guessing
  /// the name and getting a silent "model not found".
  List<String>? _models;
  bool _testing = false;
  String? _testMessage;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    final inference = context.read<InferenceProvider>();
    _host = TextEditingController(text: inference.ollamaHost);
    _model = TextEditingController(text: inference.ollamaModel);
  }

  @override
  void dispose() {
    _host.dispose();
    _model.dispose();
    super.dispose();
  }

  /// Verify the host and pull its list of models, then hand the choice to a
  /// dropdown. Persists the host so a warm-up and status check run against it.
  Future<void> _test() async {
    final inference = context.read<InferenceProvider>();
    final host = _host.text.trim();

    setState(() {
      _testing = true;
      _testMessage = null;
    });

    // Persist the typed host before probing, so the rest of the app (status
    // banner, warm-up) is testing the same address the user just entered.
    await inference.setOllama(host: host);

    final service = OllamaService(baseUrl: host);
    final reachable = await service.isAvailable();
    final models = reachable ? await service.getModels() : <String>[];

    if (!mounted) return;

    if (!reachable) {
      setState(() {
        _testing = false;
        _testOk = false;
        _models = null;
        _testMessage =
            'Could not reach Ollama at $host. Check it is running and the '
            'address is correct.';
      });
      return;
    }

    if (models.isEmpty) {
      setState(() {
        _testing = false;
        _testOk = false;
        _models = const [];
        _testMessage = 'Connected, but no models are installed. Pull one, e.g. '
            '"ollama pull llama3.2".';
      });
      return;
    }

    // Keep the current model if the server actually has it (matching the exact
    // tag, or a bare name like "llama3.2" against "llama3.2:latest").
    //
    // Otherwise leave it unset rather than selecting the first one for them.
    // Picking a model on someone's behalf is how the old default caused
    // trouble: the app looks configured, and the choice that decides the
    // quality of every answer was made by a sort order.
    final current = _model.text.trim();
    final chosen = current.isEmpty
        ? null
        : models.contains(current)
            ? current
            : models.firstWhere((m) => m.startsWith(current),
                orElse: () => '');

    if (chosen != null && chosen.isNotEmpty) {
      _model.text = chosen;
      await inference.setOllama(model: chosen);
    } else {
      _model.clear();
      await inference.setOllama(model: '');
    }

    setState(() {
      _testing = false;
      _testOk = true;
      _models = models;
      _testMessage = chosen != null && chosen.isNotEmpty
          ? 'Connected — ${models.length} '
              'model${models.length == 1 ? '' : 's'} available.'
          : 'Connected — ${models.length} '
              'model${models.length == 1 ? '' : 's'} found. Now choose one '
              'below.';
    });
  }

  /// Guidance for the host field, which differs by platform for a reason the
  /// user cannot be expected to infer.
  ///
  /// Apple's transport security permits cleartext HTTP to the local network and
  /// to domains named in the app's exception list, but exceptions match domain
  /// names, not IP literals. So a Tailscale MagicDNS name works on iOS while
  /// the same machine's 100.x address is refused — and refused as a plain
  /// connection failure, which reads as "Ollama is down" rather than "use the
  /// other address". Saying so here is cheaper than the user debugging it.
  String get _hostHelp {
    const base = 'e.g. http://localhost:11434, or a machine on your network '
        'or VPN.';
    if (Platform.isIOS) {
      return '$base On iPhone and iPad, use a Tailscale name like '
          'http://desktop.tailnet.ts.net:11434 rather than a 100.x address.';
    }
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final inference = context.watch<InferenceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final models = _models;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _host,
            decoration: InputDecoration(
              labelText: 'Host',
              helperText: _hostHelp,
              helperMaxLines: 4,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _test(),
          ),
          const SizedBox(height: 12),

          // Before a successful test the model is free text — you may know the
          // name before the host is reachable. After a test it becomes a
          // dropdown of exactly what the server reported.
          if (models != null && models.isNotEmpty)
            DropdownButtonFormField<String>(
              // Unset until the reader picks, unless a previous choice is
              // still installed. An empty dropdown is the honest state after a
              // first connection, and it is what makes the next step obvious.
              initialValue: models.contains(inference.ollamaModel)
                  ? inference.ollamaModel
                  : null,
              hint: const Text('Choose a model'),
              decoration: const InputDecoration(
                labelText: 'Model',
                helperText: 'Models installed on this host.',
                border: OutlineInputBorder(),
              ),
              items: models
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (value) {
                if (value != null) inference.setOllama(model: value);
              },
            )
          else
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                labelText: 'Model',
                helperText: 'Leave this blank — connect first, then pick from '
                    'the models the host reports.',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => inference.setOllama(model: value),
            ),
          const SizedBox(height: 12),

          FilledButton.tonal(
            onPressed: _testing ? null : _test,
            child: _testing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                // Named for both halves of what it does: the button is the
                // step between typing a host and having a model to choose, and
                // calling it only "test" hid that the list comes from here.
                : const Text('Test Connection + Pull models'),
          ),

          if (_testMessage != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _testOk ? Icons.check_circle : Icons.error_outline,
                  size: 18,
                  color: _testOk ? scheme.primary : scheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _testMessage!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _testOk ? scheme.onSurface : scheme.error,
                        ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CloudSettings extends StatefulWidget {
  const _CloudSettings();

  @override
  State<_CloudSettings> createState() => _CloudSettingsState();
}

class _CloudSettingsState extends State<_CloudSettings> {
  final _key = TextEditingController();
  bool _obscured = true;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inference = context.watch<InferenceProvider>();
    final provider = inference.cloudProvider;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<CloudProvider>(
              // The selected-segment checkmark ate enough width to wrap the
              // longest label ("ChatGPT") onto a second line; drop it, keep the
              // labels to one line, and give them a size that fits four across.
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                textStyle: const TextStyle(fontSize: 13),
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              segments: CloudProvider.values
                  .map((p) => ButtonSegment(
                        value: p,
                        label: Text(p.label,
                            maxLines: 1, softWrap: false),
                      ))
                  .toList(),
              selected: {provider},
              onSelectionChanged: (selection) => context
                  .read<InferenceProvider>()
                  .setCloudProvider(selection.first),
            ),
          ),
          const SizedBox(height: 16),

          DropdownButtonFormField<String>(
            initialValue: provider.models.contains(inference.cloudModel)
                ? inference.cloudModel
                : provider.defaultModel,
            decoration: const InputDecoration(
              labelText: 'Model',
              border: OutlineInputBorder(),
            ),
            items: provider.models
                .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                .toList(),
            onChanged: (value) {
              if (value != null) {
                context.read<InferenceProvider>().setCloudModel(value);
              }
            },
          ),
          const SizedBox(height: 16),

          TextField(
            controller: _key,
            obscureText: _obscured,
            decoration: InputDecoration(
              labelText: inference.hasCloudKey
                  ? '${provider.label} key saved — enter a new one to replace'
                  : '${provider.label} API key',
              helperText: 'Stored in your device keychain, never in the app '
                  'database or in plain text.',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscured ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () => setState(() => _obscured = !_obscured),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a key at ${provider.keyUrl}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              FilledButton.tonal(
                onPressed: () {
                  context.read<InferenceProvider>().setCloudKey(_key.text);
                  _key.clear();
                  FocusScope.of(context).unfocus();
                },
                child: const Text('Save key'),
              ),
              if (inference.hasCloudKey) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () =>
                      context.read<InferenceProvider>().setCloudKey(''),
                  child: const Text('Remove'),
                ),
              ],
            ],
          ),

          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            // Kept in the error tone because it is the one option that sends a
            // reader's questions off the device, which is the app's central
            // promise reversed. Tinted rather than filled, so it reads as a
            // standing caution to be read once — not as something broken.
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .error
                    .withValues(alpha: 0.45),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.cloud_upload,
                      size: 20, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'With a cloud key, your questions and the passages '
                      'retrieved for them are sent to that provider. Every '
                      'other option keeps them on your device.\n\n'
                      'What happens to them after that is governed by that '
                      "provider's privacy policy and data-retention terms, "
                      'not by this app. Depending on your account and their '
                      'current terms, they may retain your questions, have '
                      'staff review them, or use them to train models. '
                      'Council cannot see, control, or undo any of that — '
                      'check the terms of whichever provider you use.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the device supports the built-in model but cannot use it yet —
/// Apple Intelligence switched off, or its model still downloading.
///
/// Both are the reader's to fix and neither is permanent, which is why the row
/// stays selectable and this explains rather than disables. Hardware that can
/// never run it does not reach here: the option is not offered at all.
class _PlatformLlmNotice extends StatelessWidget {
  final InferenceProvider inference;

  const _PlatformLlmNotice({required this.inference});

  @override
  Widget build(BuildContext context) {
    final report = inference.platformLlm;
    if (report == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(report.detail,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                // The reader fixes this in iOS Settings and comes back; without
                // a way to re-ask, the app would still be showing the stale
                // answer it cached at launch.
                TextButton(
                  onPressed: () => inference.refreshPlatformLlm(),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Check again'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Choose which small model to download, and download it.
///
/// Shows RAM rather than only disk, because RAM is what decides whether it
/// runs: the corpus vector index is already resident and the model has to fit
/// beside it.
class _LocalModelSettings extends StatefulWidget {
  const _LocalModelSettings();

  @override
  State<_LocalModelSettings> createState() => _LocalModelSettingsState();
}

class _LocalModelSettingsState extends State<_LocalModelSettings> {
  StreamSubscription<int>? _install;
  int? _progress;
  String? _error;

  /// Bumped whenever the weights appear or disappear, to re-run the
  /// installed-check that decides which buttons this card shows.
  int _installChanged = 0;

  /// Held in a field rather than created in `build`, so the memory check runs
  /// once instead of on every rebuild — and, more importantly, so a rebuild
  /// mid-download does not restart it and flash the list back to a spinner.
  late final Future<List<({LocalModelTier tier, LocalModelChoice model})>>
      _tiers = LocalModelChoice.tiersHere();

  @override
  void dispose() {
    _install?.cancel();
    super.dispose();
  }

  /// Free space, and whether this model fits in it.
  ///
  /// Not cached across rebuilds the way the memory probe is: free space is the
  /// one device fact that changes while the app is open — often because the
  /// reader has just gone to make room — so a stale answer would tell them
  /// their effort had not worked.
  Future<({bool room, int? freeMb})> _diskFor(LocalModelChoice choice) async {
    final free = await DeviceStorage.freeMb();
    return (room: await choice.fitsOnDisk(), freeMb: free);
  }

  static String _gb(int mb) => mb >= 1024
      ? '${(mb / 1024).toStringAsFixed(1)} GB'
      : '$mb MB';

  Future<void> _download(LocalModelChoice choice) async {
    // Checked here as well as shown above, so the refusal holds however the
    // button was reached — and checked at the moment of pressing, because the
    // reader may have freed space since the screen was drawn.
    if (!await choice.fitsOnDisk()) {
      final free = await DeviceStorage.freeMb();
      if (!mounted) return;
      setState(() => _error =
          'Not enough free space for ${choice.name}. It needs '
          '${choice.approximateSize}'
          '${free == null ? '' : ' and this device has ${_gb(free)} free'}.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _progress = 0;
      _error = null;
    });
    _install?.cancel();
    _install = choice.install().listen(
      (p) => setState(() => _progress = p),
      onError: (Object e) => setState(() {
        _error = e.toString();
        _progress = null;
      }),
      onDone: () {
        if (!mounted) return;
        setState(() {
          _progress = null;
          _installChanged++;
        });
        context.read<InferenceProvider>().refreshStatus();
      },
    );
  }

  /// Delete the weights, after asking.
  ///
  /// Confirmed rather than immediate because it is not undoable in any cheap
  /// sense: getting the model back means downloading it again, which is the
  /// half-gigabyte the reader was trying to reclaim.
  Future<void> _remove(LocalModelChoice choice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${choice.name}?'),
        content: Text(
          'This frees about ${choice.approximateSize} on this device. '
          'Council will fall back to search-only answers until you choose '
          'another option, and getting the model back means downloading it '
          'again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await choice.uninstall();
      if (!mounted) return;
      setState(() {
        _installChanged++;
        _error = null;
      });
      context.read<InferenceProvider>().refreshStatus();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not remove ${choice.name}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final inference = context.watch<InferenceProvider>();
    final selected = inference.localModel;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Two or three models, labelled by how they fit *this* device
            // rather than listed by size. Everything that fits is not a useful
            // list — on a workstation that is four entries an order of
            // magnitude apart with nothing saying which to pick.
            FutureBuilder<List<({LocalModelTier tier, LocalModelChoice model})>>(
              future: _tiers,
              builder: (context, snap) {
                final tiers = snap.data;
                if (tiers == null) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  );
                }
                // A radio group of one is a control that cannot be operated,
                // so a single choice is described rather than offered.
                if (tiers.length == 1) {
                  final only = tiers.first.model;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${only.name} · ${only.approximateSize}',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(only.note,
                          style: Theme.of(context).textTheme.bodyMedium),
                    ],
                  );
                }
                return RadioGroup<String>(
                  groupValue: selected.id,
                  // Not disabled by passing null — RadioGroup requires a
                  // handler — so the guard is inside: swapping models
                  // mid-download would leave the finished file attached to the
                  // wrong choice.
                  onChanged: (v) {
                    if (_progress != null) return;
                    context
                        .read<InferenceProvider>()
                        .setLocalModel(v ?? selected.id);
                  },
                  child: Column(
                    children: [
                      for (final entry in tiers)
                        RadioListTile<String>(
                          value: entry.model.id,
                          contentPadding: EdgeInsets.zero,
                          title: TierTitle(
                              tier: entry.tier, model: entry.model),
                          subtitle: Text(entry.tier.rationale),
                          isThreeLine: true,
                        ),
                    ],
                  ),
                );
              },
            ),
            // Said plainly rather than by hiding the card: a reader whose
            // phone is under the floor should know that is why, not be left
            // with a download that fails later.
            FutureBuilder<bool>(
              future: selected.fitsThisDevice(),
              builder: (context, snap) {
                if (snap.data != false) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${selected.name} asks for more memory than this device '
                    'has. It would download and then fail to load — Ollama or '
                    'an API key will work here instead.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error),
                  ),
                );
              },
            ),
            // Disk is checked separately from memory and treated differently:
            // a reader can free space and try again, so the model stays
            // offered with its download blocked and the numbers shown, rather
            // than disappearing the way one that cannot fit in memory does.
            FutureBuilder<({bool room, int? freeMb})>(
              key: ValueKey('disk-${selected.id}-$_installChanged'),
              future: _diskFor(selected),
              builder: (context, snap) {
                final disk = snap.data;
                if (disk == null || disk.room) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Not enough free space for ${selected.name}: it needs '
                    '${selected.approximateSize} and this device has '
                    '${disk.freeMb == null ? "less" : _gb(disk.freeMb!)} '
                    'free. Free some up, or choose a smaller model.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            if (_progress != null) ...[
              LinearProgressIndicator(value: _progress! / 100),
              const SizedBox(height: 8),
              Text('Downloading ${selected.name}… $_progress%',
                  style: Theme.of(context).textTheme.bodySmall),
            ] else
              FutureBuilder<bool>(
                // Keyed on the removal counter so deleting the weights
                // re-runs the check; without it the button would keep
                // reporting the model as installed until the screen is left.
                key: ValueKey('${selected.id}-$_installChanged'),
                future: selected.isInstalled(),
                builder: (context, snap) {
                  final installed = snap.data ?? false;
                  // Wrap, not Row: "Qwen 3 0.6B installed" beside "Remove"
                  // is wider than a narrow phone gives this card.
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed:
                            installed ? null : () => _download(selected),
                        icon: Icon(installed
                            ? Icons.check
                            : Icons.download_outlined),
                        label: Text(installed
                            ? '${selected.name} installed'
                            : 'Download ${selected.approximateSize}'),
                      ),
                      // Only once there is something to remove. Half a
                      // gigabyte the reader cannot account for or reclaim is
                      // not a reasonable thing to leave on their device.
                      if (installed)
                        TextButton.icon(
                          onPressed: () => _remove(selected),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Remove'),
                        ),
                    ],
                  );
                },
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The title line of a tier row: what it is for, then which model and how big.
///
/// The tier leads because it is the thing the reader is choosing between — a
/// parameter count is not a decision anyone can make unaided, and the same
/// weights are the "best answers" option on a phone and the "smaller and
/// faster" one on a workstation.
class TierTitle extends StatelessWidget {
  final LocalModelTier tier;
  final LocalModelChoice model;

  const TierTitle({super.key, required this.tier, required this.model});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlight = tier == LocalModelTier.recommended;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                tier.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: highlight ? theme.colorScheme.primary : null,
                  fontWeight: highlight ? FontWeight.w600 : null,
                ),
              ),
            ),
          ],
        ),
        Text('${model.name} · ${model.approximateSize}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
