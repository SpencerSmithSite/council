import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/inference/cloud_backend.dart';
import '../services/inference/inference_provider.dart';
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

    return Card(
      color: ok ? scheme.secondaryContainer : scheme.errorContainer,
      child: ListTile(
        leading: Icon(ok ? Icons.check_circle : Icons.error_outline),
        title: Text(status.detail ?? (ok ? 'Ready' : 'Not available')),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
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
    // tag, or a bare name like "llama3.2" against "llama3.2:latest"); otherwise
    // select the first, so the dropdown never shows a model that isn't there.
    final current = _model.text.trim();
    final chosen = models.contains(current)
        ? current
        : models.firstWhere((m) => m.startsWith(current),
            orElse: () => models.first);
    _model.text = chosen;
    await inference.setOllama(model: chosen);

    setState(() {
      _testing = false;
      _testOk = true;
      _models = models;
      _testMessage = 'Connected — ${models.length} '
          'model${models.length == 1 ? '' : 's'} available.';
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
              initialValue: models.contains(inference.ollamaModel)
                  ? inference.ollamaModel
                  : models.first,
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
                helperText: 'A model you have pulled, e.g. llama3.2 — or test '
                    'the connection to choose from a list.',
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
                : const Text('Test connection'),
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
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.cloud_upload, size: 20),
                  SizedBox(width: 12),
                  Expanded(
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
