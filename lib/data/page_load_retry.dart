import 'dart:async';

import '../core/models.dart';
import '../core/source.dart';

/// A brief retry handles intermittent source timeouts without leaving the
/// chapter. Permanent access/authentication failures should not be hammered.
bool shouldRetryPageLoad(Object error) {
  final reason = error.toString().toLowerCase();
  if (RegExp(r'http\\s*(?:400|401|403|404|405|410|422|451)\\b')
      .hasMatch(reason)) return false;
  return ![
    'авторизац', 'оплат', 'закрыт', 'удален', 'удалён',
    'некорректный адрес', 'публичные страницы главы недоступны',
    'недоступна без', 'неизвестный адрес', 'нет в публичном доступе',
  ].any(reason.contains);
}

/// Retry only the failing page-list request, without repeating any saved
/// progress/marked-read actions. Delay duration is injectable for tests.
Future<List<PageImage>> loadChapterPagesWithRetry(
  MangaSource source,
  Chapter chapter, {
  List<Duration> backoffs = const [
    Duration(milliseconds: 450),
    Duration(milliseconds: 1100),
  ],
}) async {
  for (var attempt = 0;; attempt++) {
    try {
      final pages = await source.pages(chapter);
      if (pages.isNotEmpty || attempt >= backoffs.length) return pages;
    } catch (error) {
      if (!shouldRetryPageLoad(error) || attempt >= backoffs.length) rethrow;
    }
    await Future<void>.delayed(backoffs[attempt]);
  }
}
