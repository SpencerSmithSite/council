import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import 'random_passage_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic>? _stats;
  bool _isLoading = true;
  
  @override
  void initState() {
    super.initState();
    _loadStats();
  }
  
  Future<void> _loadStats() async {
    final dbService = context.read<DatabaseService>();
    final stats = await dbService.getStats();
    
    if (mounted) {
      setState(() {
        _stats = stats;
        _isLoading = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Theology App'),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(),
    );
  }
  
  Widget _buildContent() {
    if (_stats == null) {
      return const Center(child: Text('Unable to load database'));
    }
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Welcome card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Christian Theology Research',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Explore church fathers, councils, and confessions of faith from across Christian traditions. Ask questions and get AI-powered answers with citations.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Stats
          Text(
            'Database Contents',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.book,
                  label: 'Sources',
                  value: '${_stats!['sources']}',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  icon: Icons.article,
                  label: 'Content Units',
                  value: '${_stats!['content_units']}',
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 12),
          
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.account_balance,
                  label: 'Traditions',
                  value: '${_stats!['traditions']}',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  icon: Icons.local_offer,
                  label: 'Tags',
                  value: '${_stats!['tags']}',
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 24),
          
          // Quick actions
          Text(
            'Quick Actions',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          
          _QuickActionCard(
            icon: Icons.search,
            title: 'Search',
            subtitle: 'Find content across all sources',
            onTap: () {
              // Will navigate via DefaultTabController - but we removed it
              // For now, this just shows the card - navigation is via bottom nav
            },
          ),
          
          const SizedBox(height: 8),
          
          _QuickActionCard(
            icon: Icons.chat,
            title: 'Ask AI',
            subtitle: 'Query theological content with AI',
            onTap: () {
              // Will navigate via bottom nav
            },
          ),
          
          const SizedBox(height: 8),
          
          _QuickActionCard(
            icon: Icons.casino,
            title: 'Random Passage',
            subtitle: 'Discover something new',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const RandomPassageScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
  });
  
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  
  const _QuickActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}