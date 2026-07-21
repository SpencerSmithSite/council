import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/inference/cloud_backend.dart';
import '../services/inference/inference_provider.dart';

/// Choose and configure how answers are generated.
///
/// The app is offline-first, so the default is no AI at all and every option
/// states plainly whether it sends anything off the device.
class AiBackendScreen extends StatelessWidget {
  const AiBackendScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final inference = context.watch<InferenceProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('AI Backend')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusBanner(inference: inference),
          const SizedBox(height: 16),

          _Option(
            id: 'none',
            title: 'No AI — search only',
            subtitle:
                'Browse and search the library. Nothing is generated and '
                'nothing leaves your device.',
            icon: Icons.menu_book_outlined,
            selected: inference.backendId == 'none',
          ),
          _Option(
            id: 'ollama',
            title: 'Ollama',
            subtitle:
                'A model running on this machine, or on another one you can '
                'reach over your network or VPN.',
            icon: Icons.dns_outlined,
            selected: inference.backendId == 'ollama',
          ),
          if (inference.backendId == 'ollama') const _OllamaSettings(),

          _Option(
            id: 'cloud',
            title: 'Your own API key',
            subtitle:
                'Claude, ChatGPT, Gemini or Grok, billed to your own account.',
            icon: Icons.vpn_key_outlined,
            selected: inference.backendId == 'cloud',
          ),
          if (inference.backendId == 'cloud') const _CloudSettings(),

          const SizedBox(height: 24),
          const _PlatformModelsNote(),
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

  @override
  Widget build(BuildContext context) {
    final inference = context.read<InferenceProvider>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'Host',
              helperText: 'e.g. http://localhost:11434, or a machine on your '
                  'network or VPN',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => inference.setOllama(host: value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            decoration: const InputDecoration(
              labelText: 'Model',
              helperText: 'A model you have pulled, e.g. llama3.2',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => inference.setOllama(model: value),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () => inference.setOllama(
              host: _host.text,
              model: _model.text,
            ),
            child: const Text('Save and test connection'),
          ),
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
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<CloudProvider>(
            segments: CloudProvider.values
                .map((p) => ButtonSegment(value: p, label: Text(p.label)))
                .toList(),
            selected: {provider},
            onSelectionChanged: (selection) =>
                context.read<InferenceProvider>()
                    .setCloudProvider(selection.first),
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

class _PlatformModelsNote extends StatelessWidget {
  const _PlatformModelsNote();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Coming: on-device models',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Apple Foundation Models (iPhone 15 Pro or later, M-series Mac) '
              'and Gemini Nano on recent flagship Android phones will run '
              'entirely on-device with no key and no download. Council will '
              'never ship a language model of its own — that would cost '
              'gigabytes and perform worse than any option above.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
