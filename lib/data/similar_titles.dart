import '../core/models.dart';
import '../core/title_matching.dart';

/// Source-backed similarity: rank catalog entries by shared labels only.
/// Never claim an official series relation, and do not invent votes/scores.
List<MangaEntry> similarBySourceTags(String currentTitle,
    Iterable<String> currentTags, Iterable<MangaEntry> candidates,
    {int limit = 8}) {
  String norm(String value) => value.trim().toLowerCase();
  final tags = currentTags.map(norm).where((tag) => tag.isNotEmpty).toSet();
  if (tags.isEmpty || limit <= 0) return const [];
  final scored = <(MangaEntry, int)>[];
  final seen = <String>{};
  for (final entry in candidates) {
    final key = normalizedTitle(entry.title);
    if (key.isEmpty || key == normalizedTitle(currentTitle) ||
        !seen.add(key)) continue;
    final overlap = entry.tags.map(norm).toSet().intersection(tags).length;
    if (overlap > 0) scored.add((entry, overlap));
  }
  scored.sort((a, b) {
    final score = b.$2.compareTo(a.$2);
    return score == 0 ? a.$1.title.compareTo(b.$1.title) : score;
  });
  return scored.take(limit).map((v) => v.$1).toList();
}
