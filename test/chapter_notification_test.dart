import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/chapter_alert_preferences.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:senreader/data/chapter_checker.dart';

ChapterDiscovery discovery(String title, String source, String key, String chapterId) {
  return ChapterDiscovery(
    book: UnifiedManga(title: title, entries: {
      source: MangaEntry(source: source, id: 'manga', title: title),
    }),
    sourceKey: source,
    chapter: Chapter(id: chapterId, name: 'Глава 3.5'),
    canonicalKey: key,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('payload encodes title and chapter without private URLs or tokens', () {
    final item = discovery('Example', 'remanga', 'v0:c3.5', '321');
    final encoded = ChapterNotificationService.encodePayload(item);
    final decoded = ChapterNotificationService.decodePayload(encoded)!;
    expect(decoded, {
      'book': 'example', 'source': 'remanga',
      'chapter': '321', 'canonical': 'v0:c3.5', 'titleId': 'manga',
    });
    expect(jsonDecode(encoded), isA<Map>());
    expect(encoded, isNot(contains('http')));
  });

  test('invalid payloads do not navigate to arbitrary content', () {
    for (final payload in [
      null, '', 'not json', '{}', '[1]', '{"source":"remanga"}',
      '{"book":"x","source":"remanga","chapter":"3","canonical":"v0:c3","extra":"oops"}',
      '{broken',
    ]) {
      expect(ChapterNotificationService.decodePayload(payload), isNull);
    }
  });

  test('different source chapter identities get independent notification ids', () {
    final first = discovery('Example', 'senkuro', 'v0:c3', 'first');
    final second = discovery('Example', 'remanga', 'v0:c3', 'second');
    expect(ChapterNotificationService.notificationId(first),
        isNot(ChapterNotificationService.notificationId(second)));
    expect(ChapterNotificationService.notificationId(first),
        isNot(ChapterNotificationService.notificationId(
          discovery('Different', 'remanga', 'v0:c3', 'third'),
        )));
  });

  test('periodic interval is fixed at WorkManager minimum', () {
    expect(ChapterAlertPreferences.availableIntervals, [15]);
  });
}
