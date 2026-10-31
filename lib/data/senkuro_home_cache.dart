import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';

/// One-day device cache for Senkuro home rows. A manual refresh bypasses TTL.
/// Bad or old data never masquerades as a fresh server response.
class SenkuroHomeCache {
  static const maxAge = Duration(hours: 24);
  static const prefix = 'senreader.senkuro.home.v1.';
  Future<List<MangaEntry>?> load(String category, {DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefix + category);
    if (raw == null || raw.length > 250000) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final timestamp = decoded['at'];
      final data = decoded['items'];
      if (timestamp is! int || data is! List) return null;
      final age = (now ?? DateTime.now()).millisecondsSinceEpoch - timestamp;
      if (age < 0 || age >= maxAge.inMilliseconds) return null;
      return data.whereType<Map>().map((record) =>
        MangaEntry.fromJson(Map<String, dynamic>.from(record))).toList();
    } catch (_) { return null; }
  }

  Future<void> save(String category, List<MangaEntry> entries,
      {DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefix + category, jsonEncode({
      'at': (now ?? DateTime.now()).millisecondsSinceEpoch,
      'items': entries.take(30).map((entry) => entry.toJson()).toList(),
    }));
  }
}
