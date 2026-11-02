import 'package:shared_preferences/shared_preferences.dart';
import '../core/chapter_identity.dart';
import '../core/models.dart';
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
    if (discovery.profileId != null) 'profile': discovery.profileId,
  });

  static Map<String, String>? decodePayload(String? payload) {
    if (payload == null || payload.length > 4096) return null;
    try {
      final raw = jsonDecode(payload);
      if (raw is! Map || (raw.length != 4 && raw.length != 5)) return null;
      final fields = <String, String>{};
      for (final key in ['book', 'source', 'chapter', 'canonical']) {
        final value = raw[key];
        if (value is! String || value.isEmpty || value.length > 512) return null;
        fields[key] = value;
      }
      if (raw.length == 5) {
        final profile = raw['profile'];
        if (profile is! String ||
            (profile.isNotEmpty &&
             !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(profile))) {
          return null;
        }
        fields['profile'] = profile;
      }
      return fields;
    } catch (_) {
      return null;
    }
  }

  /// Stable positive notification ID for this title+chapter across reboots.
  static int notificationId(ChapterDiscovery discovery) {
    final input = (discovery.profileId?.isNotEmpty == true
        ? '${discovery.profileId}:' : '') +
        normalizedTitle(discovery.book.title) + ':' + discovery.canonicalKey;
    var value = 0x811c9dc5;
    for (final c in input.codeUnits) {
      value = ((value ^ c) * 0x01000193) & 0xffffffff;
    }
    return value & 0x7fffffff;
  }

  Future<int> postNewChapters(List<ChapterDiscovery> releases,
      {ChapterAlertPreferences? preferences,
       Future<bool> Function()? permissionCheck,
       Future<void> Function(ChapterDiscovery)? sendNotification,
       Future<Set<int>> Function()? activeNotificationIds,
       LibraryStore? libraryStore}) async {
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
    final library = libraryStore ?? LibraryStore();
    await library.load();
    final profile = library.profileId;
    final inbox = ChapterInboxStore(profileId: profile);
    final books = {for (final b in library.items) b.key: b};
    final settings = await SharedPreferences.getInstance();
    final libraryKey = profile.isEmpty ? LibraryStore.storageKey :
        '${LibraryStore.storageKey}.user.$profile';
    // Invalidate this batch on concurrent read/source/status changes without
    // decoding/reloading the whole library for each pending row.
    final librarySnapshot = settings.getString(libraryKey);
    Future<bool> stillActive() async {
      await settings.reload();
      return settings.getString(libraryKey) == librarySnapshot &&
          (settings.getString(LibraryStore.activeProfileKey) ?? '') == profile &&
          await prefs.enabled() && await prefs.systemNotificationsEnabled();
    }
    for (final release in releases) {
      if (release.profileId != null && release.profileId != profile) continue;
      final saved = library.get(release.book);
      if (saved == null || saved.status != 'reading' ||
          !saved.entries.containsKey(release.sourceKey)) continue;
      await inbox.add(normalizedTitle(release.book.title), release.book.title,
          release.book.coverUrl, release.sourceKey, release.chapter,
          sourceId: saved.entries[release.sourceKey]!.id,
          systemPending: await prefs.systemNotificationsEnabled());
    }
    if (!canPostSystemNotification) return 0;
    final active = activeNotificationIds != null
        ? await activeNotificationIds() : sendNotification != null
            ? <int>{} : await _activeIds();
    var posted = 0;
    // Discoveries may be empty after restart: the inbox is the durable outbox.
    for (final entry in await inbox.pendingSystemNotifications()) {
      if (entry.hidden) continue;
      if (!await stillActive()) break;
      final saved = books[entry.bookKey];
      if (saved == null || saved.status != 'reading' ||
          !saved.entries.containsKey(entry.source) ||
          (entry.sourceId.isNotEmpty && saved.entries[entry.source]!.id != entry.sourceId)) {
        await inbox.retireSystemDelivery(entry);
        continue;
      }
      final chapter = Chapter(id: entry.chapterId, name: entry.chapterName);
      if (library.isChapterRead(saved.toUnified(), chapter, entry.source)) {
        await inbox.hideChapter(entry.bookKey, chapter, entry.source);
        continue;
      }
      final token = await inbox.beginSystemDelivery(entry);
      if (token == null) continue;
      final release = ChapterDiscovery(book: saved.toUnified(), sourceKey: entry.source,
          chapter: chapter, canonicalKey: canonicalChapterKey(chapter) ?? entry.chapterId,
          profileId: profile);
      var delivered = false;
      try {
        if (!await stillActive() || !await inbox.systemDeliveryCurrent(entry, token)) continue;
        if (!active.contains(notificationId(release))) {
          await (sendNotification ?? _show)(release);
          active.add(notificationId(release));
          posted++;
        }
        delivered = true;
      } catch (_) {
        // Keep retryable on platform errors; inbox visibility is independent.
      } finally {
        await inbox.finishSystemDelivery(entry, token, delivered: delivered);
      }
    }
    return posted;
  }
  Future<Set<int>> _activeIds() async {
    try { return (await _plugin.getActiveNotifications())
        .map((n) => n.id).whereType<int>().toSet(); }
    catch (_) { return <int>{}; }
  }

  Future<void> _show(ChapterDiscovery release) async {
    await _plugin.show(
          id: notificationId(release),
          title: release.book.title,
          body: release.chapter.name,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'senreader_new_chapters', 'Новые главы',
              channelDescription: 'Новые доступные главы манги и манхвы из избранного',
              importance: Importance.defaultImportance,
              onlyAlertOnce: true,
              priority: Priority.defaultPriority,
            ),
          ),
          payload: encodePayload(release),
        );
  }

}


