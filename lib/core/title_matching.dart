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
  final groups = <String, Map<String, MangaEntry>>{};
  for (final entry in all) {
    final key = normalizedTitle(entry.title);
    if (key.isEmpty) continue;
    groups.putIfAbsent(key, () => {})['${entry.source}:${entry.id}'] = entry;
  }
  final result = <UnifiedManga>[];
  for (final group in groups.values) {
    final entries = group.values.toList();
    final providers = entries.map((e) => e.source).toSet();
    if (providers.length != entries.length) {
      // Same normalized label refers to several IDs on one site: keep every
      // candidate separate rather than arbitrarily linking the first result.
      result.addAll(entries.map((e) => UnifiedManga(title: e.title,
        entries: {e.source: e}, requiresLinkApproval: true)));
    } else {
      result.add(UnifiedManga(title: entries.first.title,
        entries: {for (final e in entries) e.source: e}));
    }
  }
  return result
    ..sort((a, b) {
      final aPrimary = a.entries.containsKey('senkuro') ? 0 : 1;
      final bPrimary = b.entries.containsKey('senkuro') ? 0 : 1;
      return aPrimary.compareTo(bPrimary);
    });
}
