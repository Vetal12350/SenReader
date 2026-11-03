import '../core/chapter_identity.dart';
import '../core/models.dart';
import '../data/chapter_inbox_store.dart';

/// Presentation-only grouping: each chapter remains a separate SQLite record.
class InboxChapterGroup {
  InboxChapterGroup(Iterable<InboxEntry> chapters)
      : entries = List<InboxEntry>.unmodifiable(
          chapters.toList()..sort(_newestChapterFirst));

  final List<InboxEntry> entries;

  InboxEntry get latest => entries.first;
  int get newestAt => entries.fold<int>(0,
      (value, entry) => entry.createdAt > value ? entry.createdAt : value);
  int get newestHiddenAt => entries.fold<int>(0,
      (value, entry) => entry.hiddenAt > value ? entry.hiddenAt : value);

  String get chapterLabel {
    if (entries.length == 1) return displayChapterName(latest.chapterName);

    // Show compact, accurate ranges when chapter labels are consecutive.
    final numbers = <String>[];
    final pattern = RegExp(
        r'^(?:глава|chapter|ch\.?)\s*(\d+(?:[.,]\d+)?)\s*$',
        caseSensitive: false);
    for (final entry in entries.reversed) {
      final match = pattern.firstMatch(displayChapterName(entry.chapterName));
      if (match == null) break;
      numbers.add(match.group(1)!.replaceAll(',', '.'));
    }
    if (numbers.length == entries.length) {
      final integers = numbers.every((value) => RegExp(r'^\d+$').hasMatch(value));
      if (integers && numbers.toSet().length == numbers.length) {
        final first = BigInt.parse(numbers.first);
        final consecutive = [
          for (var i = 0; i < numbers.length; i++)
            BigInt.parse(numbers[i]) == first + BigInt.from(i),
        ].every((value) => value);
        if (consecutive) return 'Главы ' + numbers.first + '–' + numbers.last;
      }
      if (numbers.length <= 3) return 'Главы ' + numbers.join(', ');
      return 'Новых глав: ' + numbers.length.toString() +
          ' · ' + numbers.first + '–' + numbers.last;
    }
    return 'Новых глав: ' + entries.length.toString() +
        ' · ' + displayChapterName(latest.chapterName);
  }
}

int _newestChapterFirst(InboxEntry a, InboxEntry b) {
  final order = compareChapterChronology(
    Chapter(id: a.chapterId, name: a.chapterName),
    Chapter(id: b.chapterId, name: b.chapterName),
  );
  if (order != null && order != 0) return -order;
  final created = b.createdAt.compareTo(a.createdAt);
  return created != 0 ? created : a.key.compareTo(b.key);
}

/// Keep visible and hidden groups independent; never group across book keys.
List<InboxChapterGroup> groupInboxChapters(
    Iterable<InboxEntry> rows, {required bool hidden}) {
  final groups = <String, List<InboxEntry>>{};
  for (final entry in rows) {
    if (entry.hidden != hidden) continue;
    groups.putIfAbsent(entry.bookKey, () => []).add(entry);
  }
  return groups.values.map(InboxChapterGroup.new).toList()
    ..sort((a, b) {
      final dateOrder = hidden
          ? b.newestHiddenAt.compareTo(a.newestHiddenAt)
          : b.newestAt.compareTo(a.newestAt);
      return dateOrder != 0 ? dateOrder :
          a.latest.title.compareTo(b.latest.title);
    });
}
