import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../core/title_matching.dart';
import 'chapter_alert_preferences.dart';
import 'chapter_checker.dart';
import 'chapter_inbox_store.dart';
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

  Future<int> postNewChapters(List<ChapterDiscovery> releases,
      {ChapterAlertPreferences? preferences,
       Future<bool> Function()? permissionCheck}) async {
    final prefs = preferences ?? ChapterAlertPreferences();
    if (!await prefs.enabled()) return 0;
    // Internal storage is mandatory. Android permission only controls optional
    // system alerts and must never prevent delivery to the app's own inbox.
    var canPostSystemNotification = false;
    if (await prefs.systemNotificationsEnabled()) {
      try {
        canPostSystemNotification = await (permissionCheck ?? hasPermission)();
      } catch (_) {
        // Plugin/permission errors must not block internal updates.
      }
    }
    var posted = 0;
    for (final release in releases) {
      // A source may have changed while the checker or Android was waiting.
      final library = LibraryStore();
      await library.load();
      final saved = library.get(release.book);
      if (saved == null || saved.status != 'reading' ||
          !saved.entries.containsKey(release.sourceKey) ||
          (release.profileId != null && release.profileId != library.profileId) ||
          !await prefs.enabled()) continue;
      final inbox = ChapterInboxStore(profileId: library.profileId);
      await inbox.add(normalizedTitle(release.book.title),
        release.book.title, release.book.coverUrl,
        release.sourceKey, release.chapter);
      if (!canPostSystemNotification) continue;
      if (!await inbox.claimSystemNotification(normalizedTitle(release.book.title),
          release.chapter, release.sourceKey)) continue;
      try {
        await _plugin.show(
          id: notificationId(release),
          title: release.book.title,
          body: release.chapter.name,
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
      } catch (_) {
        // The chapter is already durably saved in the internal inbox.
      }
    }
    return posted;
  }
}

