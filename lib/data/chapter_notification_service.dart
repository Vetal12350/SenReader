import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../core/title_matching.dart';
import 'chapter_alert_preferences.dart';
import 'chapter_checker.dart';
import 'library_store.dart';

class ChapterNotificationService {
  ChapterNotificationService._();
  static final instance = ChapterNotificationService._();
  static const channel = AndroidNotificationChannel(
    'senreader_new_chapters', 'Новые главы',
    description: 'Новые доступные главы манги и манхвы из избранного',
    importance: Importance.defaultImportance,
  );

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  final ValueNotifier<String?> openedPayload = ValueNotifier<String?>(null);

  Future<void> initialize({bool captureTaps = true}) async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: captureTaps
          ? (response) => openedPayload.value = response.payload : null,
    );
    await _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);

    if (captureTaps) {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        openedPayload.value = launch?.notificationResponse?.payload;
      }
    }
  }

  Future<bool> hasPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? false;
  }

  Future<bool> askPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? false;
  }

  static String encodePayload(ChapterDiscovery discovery) => jsonEncode({
    'book': normalizedTitle(discovery.book.title),
    'source': discovery.sourceKey,
    'chapter': discovery.chapter.id,
    'canonical': discovery.canonicalKey,
  });

  static Map<String, String>? decodePayload(String? payload) {
    if (payload == null || payload.length > 4096) return null;
    try {
      final raw = jsonDecode(payload);
      if (raw is! Map || raw.length != 4) return null;
      final fields = <String, String>{};
      for (final key in ['book', 'source', 'chapter', 'canonical']) {
        final value = raw[key];
        if (value is! String || value.isEmpty || value.length > 512) return null;
        fields[key] = value;
      }
      return fields;
    } catch (_) {
      return null;
    }
  }

  /// Stable positive notification ID for this title+chapter across reboots.
  static int notificationId(ChapterDiscovery discovery) {
    final input = normalizedTitle(discovery.book.title) + ':' + discovery.canonicalKey;
    var value = 0x811c9dc5;
    for (final c in input.codeUnits) {
      value = ((value ^ c) * 0x01000193) & 0xffffffff;
    }
    return value & 0x7fffffff;
  }

  Future<int> postNewChapters(List<ChapterDiscovery> releases) async {
    if (!await ChapterAlertPreferences().enabled() || !await hasPermission()) {
      return 0;
    }
    var posted = 0;
    for (final release in releases) {
      // A source may have changed while the checker or Android was waiting.
      final library = LibraryStore();
      await library.load();
      if (library.get(release.book)?.preferredSource != release.sourceKey ||
          !await ChapterAlertPreferences().enabled()) continue;
      await _plugin.show(
        id: notificationId(release),
        title: release.book.title,
        body: release.chapter.name + ' · ' + release.sourceKey,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'senreader_new_chapters', 'Новые главы',
            channelDescription: 'Новые доступные главы манги и манхвы из избранного',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
        payload: encodePayload(release),
      );
      posted++;
    }
    return posted;
  }
}
