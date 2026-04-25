import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class RecentlyViewedService {
  static const String _key = 'recently_viewed';
  static const int _maxItems = 50;
  
  Future<SharedPreferences> get _prefs async => await SharedPreferences.getInstance();
  
  /// Get recently viewed items (newest first)
  Future<List<RecentlyViewedItem>> getRecent() async {
    final prefs = await _prefs;
    final json = prefs.getString(_key);
    if (json == null) return [];
    
    try {
      final List<dynamic> decoded = jsonDecode(json);
      return decoded.map((d) => RecentlyViewedItem.fromJson(d)).toList();
    } catch (_) {
      return [];
    }
  }
  
  /// Add a viewed item
  Future<void> addViewed(int contentId, String title, String source) async {
    final recent = await getRecent();
    
    // Remove if already exists
    recent.removeWhere((r) => r.contentId == contentId);
    
    // Add new at beginning
    recent.insert(0, RecentlyViewedItem(
      contentId: contentId,
      title: title,
      source: source,
      viewedAt: DateTime.now(),
    ));
    
    // Trim to max
    while (recent.length > _maxItems) {
      recent.removeLast();
    }
    
    await _save(recent);
  }
  
  /// Clear all
  Future<void> clear() async {
    final prefs = await _prefs;
    await prefs.remove(_key);
  }
  
  Future<void> _save(List<RecentlyViewedItem> items) async {
    final prefs = await _prefs;
    final json = jsonEncode(items.map((i) => i.toJson()).toList());
    await prefs.setString(_key, json);
  }
}

class RecentlyViewedItem {
  final int contentId;
  final String title;
  final String source;
  final DateTime viewedAt;
  
  RecentlyViewedItem({
    required this.contentId,
    required this.title,
    required this.source,
    required this.viewedAt,
  });
  
  factory RecentlyViewedItem.fromJson(Map<String, dynamic> json) {
    return RecentlyViewedItem(
      contentId: json['contentId'] as int,
      title: json['title'] as String,
      source: json['source'] as String,
      viewedAt: DateTime.parse(json['viewedAt'] as String),
    );
  }
  
  Map<String, dynamic> toJson() {
    return {
      'contentId': contentId,
      'title': title,
      'source': source,
      'viewedAt': viewedAt.toIso8601String(),
    };
  }
}
