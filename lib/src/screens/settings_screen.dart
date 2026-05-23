import 'package:flutter/material.dart';

import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _darkMode;
  double _fontSize = 1.0;
  bool _showCitations = true;
  bool _isLoading = true;
  
  final SettingsService _settings = SettingsService();
  
  @override
  void initState() {
    super.initState();
    _loadSettings();
  }
  
  Future<void> _loadSettings() async {
    final darkMode = await _settings.getDarkMode();
    final fontSize = await _settings.getFontSize();
    final showCitations = await _settings.getShowCitations();
    
    if (mounted) {
      setState(() {
        _darkMode = darkMode;
        _fontSize = fontSize;
        _showCitations = showCitations;
        _isLoading = false;
      });
    }
  }
  
  Future<void> _setDarkMode(bool? value) async {
    await _settings.setDarkMode(value);
    setState(() {
      _darkMode = value;
    });
  }
  
  Future<void> _setFontSize(double value) async {
    await _settings.setFontSize(value);
    setState(() {
      _fontSize = value;
    });
  }
  
  Future<void> _setShowCitations(bool value) async {
    await _settings.setShowCitations(value);
    setState(() {
      _showCitations = value;
    });
  }
  
  Future<void> _resetAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset All Settings?'),
        content: const Text('This will reset all preferences to defaults.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      await _settings.clearAll();
      _loadSettings();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(),
    );
  }
  
  Widget _buildContent() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Theme
        const _SectionTitle('Appearance'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.brightness_6),
                title: const Text('Dark Mode'),
                subtitle: const Text('Override system theme'),
                trailing: DropdownButton<bool?>(
                  value: _darkMode,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('System')),
                    DropdownMenuItem(value: true, child: Text('On')),
                    DropdownMenuItem(value: false, child: Text('Off')),
                  ],
                  onChanged: _setDarkMode,
                ),
              ),
            ],
          ),
        ),
        
        const SizedBox(height: 16),
        
        // Font Size
        const _SectionTitle('Reading'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.format_size),
                title: const Text('Font Size'),
                subtitle: Text('${_fontSize.toStringAsFixed(1)}x'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Slider(
                  value: _fontSize,
                  min: 0.8,
                  max: 1.5,
                  divisions: 7,
                  label: '${_fontSize.toStringAsFixed(1)}x',
                  onChanged: _setFontSize,
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
        
        const SizedBox(height: 16),
        
        // Citations
        const _SectionTitle('AI Chat'),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.format_quote),
            title: const Text('Show Citations'),
            subtitle: const Text('Display source citations in AI responses'),
            value: _showCitations,
            onChanged: _setShowCitations,
          ),
        ),
        
        const SizedBox(height: 24),
        
        // Reset
        FilledButton.tonalIcon(
          onPressed: _resetAll,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Reset All Settings'),
        ),
        
        const SizedBox(height: 32),
        
        // About
        Center(
          child: Column(
            children: [
              Text(
                'Council',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Christian Theology Research',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                'v1.0.0 • 523 Sources • 3,014 Passages',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  
  const _SectionTitle(this.text);
  
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
