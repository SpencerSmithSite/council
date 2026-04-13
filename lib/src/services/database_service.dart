import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class DatabaseService {
  Database? _database;
  
  /// Initialize database from bundled asset
  Future<void> initialize() async {
    final databasesPath = await getDatabasesPath();
    final dbPath = p.join(databasesPath, 'theology.db');
    
    // Check if database exists
    final exists = await databaseExists(dbPath);
    
    if (!exists) {
      // Copy from asset
      await _copyDatabaseFromAsset(dbPath);
    }
    
    // Open database
    _database = await openDatabase(
      dbPath,
      readOnly: true, // Read-only for bundled database
    );
  }
  
  /// Copy database from asset to device storage
  Future<void> _copyDatabaseFromAsset(String dbPath) async {
    // Create parent directory if needed
    final parent = p.dirname(dbPath);
    await Directory(parent).create(recursive: true);
    
    // Copy asset to file
    final data = await rootBundle.load('assets/theology.db');
    final bytes = data.buffer.asUint8List();
    await File(dbPath).writeAsBytes(bytes);
  }
  
  /// Get database instance
  Database get database {
    if (_database == null) {
      throw StateError('Database not initialized. Call initialize() first.');
    }
    return _database!;
  }
  
  /// Search content with FTS5 full-text search
  Future<List<Map<String, dynamic>>> search(String query, {int limit = 20}) async {
    // Use FTS5 for better relevance ranking
    final ftsQuery = query.replaceAll(RegExp(r'[^\w\s]'), '').trim();
    final ftsTerms = ftsQuery.split(RegExp(r'\s+')).map((t) => '$t*').join(' ');
    
    final results = await database.rawQuery('''
      SELECT 
        cu.id,
        cu.title,
        cu.content,
        cu.content_plain,
        s.title as source_title,
        s.date_composed,
        t.name as tradition,
        st.name as source_type,
        fts.rank
      FROM content_fts fts
      JOIN content_units cu ON fts.rowid = cu.id
      JOIN sources s ON cu.source_id = s.id
      LEFT JOIN traditions t ON s.tradition_id = t.id
      LEFT JOIN source_types st ON s.source_type_id = st.id
      WHERE content_fts MATCH ?
      ORDER BY fts.rank
      LIMIT ?
    ''', [ftsTerms, limit]);
    
    // If FTS5 returns no results, fall back to LIKE search
    if (results.isEmpty) {
      return await _searchLike(query, limit: limit);
    }
    
    return results;
  }
  
  /// Fallback LIKE search
  Future<List<Map<String, dynamic>>> _searchLike(String query, {int limit = 20}) async {
    final results = await database.rawQuery('''
      SELECT 
        cu.id,
        cu.title,
        cu.content,
        cu.content_plain,
        s.title as source_title,
        s.date_composed,
        t.name as tradition,
        st.name as source_type
      FROM content_units cu
      JOIN sources s ON cu.source_id = s.id
      LEFT JOIN traditions t ON s.tradition_id = t.id
      LEFT JOIN source_types st ON s.source_type_id = st.id
      WHERE cu.content_plain LIKE ?
      ORDER BY cu.sequence
      LIMIT ?
    ''', ['%$query%', limit]);
    
    return results;
  }
  
  /// Search by tags for better RAG retrieval
  Future<List<Map<String, dynamic>>> searchByTags(List<String> tags, {int limit = 20}) async {
    final placeholders = tags.map((_) => '?').join(',');
    final results = await database.rawQuery('''
      SELECT 
        cu.id,
        cu.title,
        cu.content,
        cu.content_plain,
        s.title as source_title,
        s.date_composed,
        t.name as tradition,
        st.name as source_type,
        COUNT(ct.tag_id) as tag_matches
      FROM content_units cu
      JOIN content_tags ct ON cu.id = ct.content_unit_id
      JOIN tags tg ON ct.tag_id = tg.id
      JOIN sources s ON cu.source_id = s.id
      LEFT JOIN traditions t ON s.tradition_id = t.id
      LEFT JOIN source_types st ON s.source_type_id = st.id
      WHERE tg.slug IN ($placeholders)
      GROUP BY cu.id
      ORDER BY tag_matches DESC
      LIMIT ?
    ''', [...tags.map((t) => t.toLowerCase().replaceAll(' ', '-')), limit]);
    
    return results;
  }
  
  /// Combined search: FTS5 + tag-based for best RAG results
  Future<List<Map<String, dynamic>>> searchForRAG(String query, {int limit = 5}) async {
    // Get FTS5 results
    final ftsResults = await search(query, limit: limit * 2);
    
    // Extract potential tags from query
    final queryTags = _extractTags(query);
    
    // Get tag-based results if we have tags
    List<Map<String, dynamic>> tagResults = [];
    if (queryTags.isNotEmpty) {
      tagResults = await searchByTags(queryTags, limit: limit);
    }
    
    // Merge and deduplicate by id, prioritizing FTS results
    final seen = <int>{};
    final combined = <Map<String, dynamic>>[];
    
    for (final r in ftsResults) {
      final id = r['id'] as int;
      if (seen.add(id)) combined.add(r);
    }
    
    for (final r in tagResults) {
      final id = r['id'] as int;
      if (seen.add(id)) combined.add(r);
    }
    
    return combined.take(limit).toList();
  }
  
  /// Extract potential tag slugs from a query
  List<String> _extractTags(String query) {
    // Map common theological terms to tag slugs
    final tagMap = {
      'trinity': 'trinity',
      'incarnation': 'incarnation',
      'christology': 'christology',
      'salvation': 'soteriology',
      'grace': 'grace',
      'baptism': 'baptism',
      'eucharist': 'eucharist',
      'sin': 'sin',
      'justification': 'justification',
      'faith': 'faith',
      'prayer': 'prayer',
      'resurrection': 'resurrection',
      'church': 'ecclesiology',
      'scripture': 'scripture',
      'creation': 'creation',
      'atonement': 'atonement',
      'holy spirit': 'pneumatology',
      'sacrament': 'sacraments',
      'predestination': 'predestination',
      'free will': 'free-will',
    };
    
    final lower = query.toLowerCase();
    return tagMap.entries
        .where((e) => lower.contains(e.key))
        .map((e) => e.value)
        .toList();
  }
  
  /// Get all traditions
  Future<List<Map<String, dynamic>>> getTraditions() async {
    return await database.query('traditions', orderBy: 'name');
  }
  
  /// Get all source types
  Future<List<Map<String, dynamic>>> getSourceTypes() async {
    return await database.query('source_types', orderBy: 'name');
  }
  
  /// Get sources by tradition
  Future<List<Map<String, dynamic>>> getSourcesByTradition(int traditionId) async {
    return await database.query(
      'sources',
      where: 'tradition_id = ?',
      whereArgs: [traditionId],
      orderBy: 'date_composed',
    );
  }
  
  /// Get sources by type
  Future<List<Map<String, dynamic>>> getSourcesByType(int typeId) async {
    return await database.query(
      'sources',
      where: 'source_type_id = ?',
      whereArgs: [typeId],
      orderBy: 'date_composed',
    );
  }
  
  /// Get content units for a source
  Future<List<Map<String, dynamic>>> getContentForSource(int sourceId) async {
    return await database.query(
      'content_units',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      orderBy: 'sequence',
    );
  }
  
  /// Get single content unit
  Future<Map<String, dynamic>?> getContentUnit(int id) async {
    final results = await database.query(
      'content_units',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }
  
  /// Get tags for content unit
  Future<List<Map<String, dynamic>>> getTagsForContent(int contentId) async {
    return await database.rawQuery('''
      SELECT t.id, t.name, t.slug, t.category
      FROM tags t
      JOIN content_tags ct ON t.id = ct.tag_id
      WHERE ct.content_unit_id = ?
      ORDER BY t.category, t.name
    ''', [contentId]);
  }
  
  /// Get database statistics
  Future<Map<String, dynamic>> getStats() async {
    final sources = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM sources')
    ) ?? 0;
    
    final content = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM content_units')
    ) ?? 0;
    
    final traditions = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM traditions')
    ) ?? 0;
    
    final tags = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM tags')
    ) ?? 0;
    
    return {
      'sources': sources,
      'content_units': content,
      'traditions': traditions,
      'tags': tags,
    };
  }
  
  /// Close database
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}