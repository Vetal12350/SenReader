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

  static const readChapterAction = 'read_chapter';

  static String? routePayload(String? payload, String? actionId) {
    final fields = decodePayload(payload);
    if (fields == null) return null;
    fields['action'] = actionId == readChapterAction ? 'chapter' : 'title';
    return jsonEncode(fields);
  }

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _launchInspected = false;
  final ValueNotifier<String?> openedPayload = ValueNotifier<String?>(null);

  Future<void> initialize({bool captureTaps = true}) async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('senreader_launcher_monochrome'),
      ),
      // Android may run WorkManager on the Activity's engine. Reinitializing
      // delivery must retain its tap handler on that engine as well.
      onDidReceiveNotificationResponse: (response) =>
          openedPayload.value = routePayload(response.payload, response.actionId),
    );
    await _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);

    if (captureTaps && !_launchInspected) {
      _launchInspected = true;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        openedPayload.value = routePayload(launch?.notificationResponse?.payload,
          launch?.notificationResponse?.actionId);
      }
    }
  }

  Future<bool> hasPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? false;
  }

  Future<bool> channelEnabled() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final channels = await android?.getNotificationChannels();
    return channels?.every((item) =>
        item.id != channel.id || item.importance != Importance.none) ?? true;
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
    'titleId': discovery.book.entries[discovery.sourceKey]!.id,
    'canonical': discovery.canonicalKey,
    if (discovery.profileId != null) 'profile': discovery.profileId,
  });

  static Map<String, String>? decodePayload(String? payload) {
    if (payload == null || payload.length > 4096) return null;
    try {
      final raw = jsonDecode(payload);
      if (raw is! Map || raw.keys.any((key) =>
          !const {'book', 'source', 'chapter', 'canonical', 'profile', 'titleId', 'action'}.contains(key))) return null;
      final fields = <String, String>{};
      for (final key in ['book', 'source', 'chapter', 'canonical']) {
        final value = raw[key];
        if (value is! String || value.isEmpty || value.length > 512) return null;
        fields[key] = value;
      }
      for (final key in ['titleId', 'action']) {
        if (!raw.containsKey(key)) continue;
        final value = raw[key];
        if (value is! String || value.isEmpty || value.length > 512) return null;
        if (key == 'action' && value != 'title' && value != 'chapter') return null;
        fields[key] = value;
      }
      if (raw.containsKey('profile')) {
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

  /// One stable Android ID per source/title/chapter in this profile.
  static int notificationId(ChapterDiscovery discovery) => _hash(
      jsonEncode([discovery.profileId ?? '', discovery.sourceKey,
        discovery.book.entries[discovery.sourceKey]?.id ?? normalizedTitle(discovery.book.title),
        discovery.chapter.id]));

  static int legacyNotificationId(ChapterDiscovery discovery) => _hash(
      (discovery.profileId?.isNotEmpty == true ? '${discovery.profileId}:' : '') +
      normalizedTitle(discovery.book.title) + ':' + discovery.canonicalKey);

  static int _hash(String input) {
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
        canPostSystemNotification = permissionCheck != null
            ? await permissionCheck()
            : await hasPermission() && await channelEnabled();
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
    final pending = <(InboxEntry, ChapterDiscovery)>[];
    // Discoveries may be empty after restart: the inbox is the durable outbox.
    for (final entry in await inbox.pendingSystemNotifications(limit: null)) {
      if (entry.hidden || entry.read || entry.deleted) continue;
      final saved = books[entry.bookKey];
      if (saved == null || saved.status != 'reading' ||
          !saved.entries.containsKey(entry.source) ||
          (entry.sourceId.isNotEmpty && saved.entries[entry.source]!.id != entry.sourceId)) {
        await inbox.retireSystemDelivery(entry);
        continue;
      }
      final chapter = Chapter(id: entry.chapterId, name: entry.chapterName);
      final release = ChapterDiscovery(book: saved.toUnified(), sourceKey: entry.source,
          chapter: chapter, canonicalKey: canonicalChapterKey(chapter) ?? entry.chapterId,
          profileId: profile);
      if (active.contains(legacyNotificationId(release))) {
        if (!await stillActive()) return posted;
        final token = await inbox.beginSystemDelivery(entry);
        if (token != null) await inbox.finishSystemDelivery(entry, token, delivered: true);
        continue;
      }
      pending.add((entry, release));
    }
    for (final (entry, release) in pending.take(10)) {
      if (!await stillActive()) break;
      final token = await inbox.beginSystemDelivery(entry);
      if (token == null) continue;
      final claimed = [(entry, token)];
      var acknowledged = false;
      try {
        if (!await stillActive()) continue;
        // Commit before crossing into Android. A killed process can miss an OS
        // alert in this window, but it cannot replay an alert already shown.
        acknowledged = await inbox.acknowledgeSystemBatch(claimed);
        if (!acknowledged) continue;
        try {
          if (!await stillActive()) {
            for (final (entry, token) in claimed) {
              await inbox.retryFailedSystemDelivery(entry, token);
            }
            break;
          }
          await (sendNotification ?? _show)(release);
          posted++;
        } catch (_) {
          for (final (entry, token) in claimed) {
            await inbox.retryFailedSystemDelivery(entry, token);
          }
        }
      } finally {
        if (!acknowledged) {
          for (final (entry, token) in claimed) {
            await inbox.finishSystemDelivery(entry, token, delivered: false);
          }
        }
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
              priority: Priority.defaultPriority,
              actions: [AndroidNotificationAction(readChapterAction, 'Читать главу',
                showsUserInterface: true)],
            ),
          ),
          payload: encodePayload(release),
        );
  }

}


