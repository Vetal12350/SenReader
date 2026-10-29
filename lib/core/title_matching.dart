import 'models.dart';

// Deliberately conservative: NEVER merge unrelated series because of a fuzzy match.
// Different localized names are not merged automatically in version 0.1.
String normalizedTitle(String input) => input
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

List<UnifiedManga> mergeEntries(Iterable<MangaEntry> all) {
  final result = <String, UnifiedManga>{};
  for (final entry in all) {
    final key = normalizedTitle(entry.title);
    if (key.isEmpty) continue;
    final existing = result[key];
    if (existing == null) {
      result[key] = UnifiedManga(title: entry.title, entries: {entry.source: entry});
    } else {
      existing.entries.putIfAbsent(entry.source, () => entry);
    }
  }
  return result.values.toList()
    ..sort((a, b) {
      final aPrimary = a.entries.containsKey('senkuro') ? 0 : 1;
      final bPrimary = b.entries.containsKey('senkuro') ? 0 : 1;
      return aPrimary.compareTo(bPrimary);
    });
}
