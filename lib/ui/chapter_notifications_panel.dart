import 'package:flutter/material.dart';
import '../data/chapter_alert_preferences.dart';
import '../data/chapter_background_scheduler.dart';
import '../data/chapter_notification_service.dart';

class ChapterNotificationsPanel extends StatefulWidget {
  const ChapterNotificationsPanel({super.key});
  @override State<ChapterNotificationsPanel> createState() =>
      _ChapterNotificationsPanelState();
}

class _ChapterNotificationsPanelState extends State<ChapterNotificationsPanel> {
  bool loading = true;
  bool enabled = false;
  int minutes = 60;
  String? message;

  @override void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = ChapterAlertPreferences();
    final newEnabled = await prefs.enabled();
    final newMinutes = await prefs.intervalMinutes();
    if (!mounted) return;
    setState(() {
      enabled = newEnabled;
      minutes = newMinutes;
      loading = false;
    });
  }

  Future<void> _toggle(bool next) async {
    setState(() { loading = true; message = null; });
    final prefs = ChapterAlertPreferences();
    try {
      if (next && !await ChapterNotificationService.instance.askPermission()) {
        if (mounted) setState(() {
          loading = false;
          message = 'Разреши уведомления SenReader в настройках Android.';
        });
        return;
      }
      await prefs.setEnabled(next);
      await ChapterBackgroundScheduler.sync();
      if (mounted) setState(() { enabled = next; loading = false; });
    } catch (_) {
      // Fail closed when the Android scheduler is unavailable.
      await prefs.setEnabled(false);
      if (mounted) setState(() {
        enabled = false;
        loading = false;
        message = 'Не удалось включить фоновую проверку на этом устройстве.';
      });
    }
  }

  Future<void> _interval(int next) async {
    setState(() => loading = true);
    try {
      await ChapterAlertPreferences().setIntervalMinutes(next);
      await ChapterBackgroundScheduler.sync();
      if (mounted) setState(() { minutes = next; loading = false; });
    } catch (_) {
      if (mounted) setState(() {
        loading = false;
        message = 'Не удалось изменить период фоновой проверки.';
      });
    }
  }

  @override Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Уведомлять о новых главах'),
            subtitle: const Text('Senkuro · ReadManga · ReManga'),
            value: enabled,
            onChanged: loading ? null : _toggle,
          ),
          Row(children: [
            const Expanded(child: Text('Проверять примерно каждые',
                style: TextStyle(color: Colors.white70))),
            DropdownButton<int>(
              value: minutes,
              onChanged: loading ? null : (value) {
                if (value != null) _interval(value);
              },
              items: const [
                DropdownMenuItem(value: 30, child: Text('30 мин')),
                DropdownMenuItem(value: 60, child: Text('1 час')),
                DropdownMenuItem(value: 180, child: Text('3 часа')),
                DropdownMenuItem(value: 360, child: Text('6 часов')),
              ],
            ),
          ]),
          const Text(
            'Android может задерживать проверки. Первое сканирование сохраняет '
            'исходный список без уведомлений; мгновенная доставка не гарантируется.',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
          if (message != null) Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(message!, style: const TextStyle(color: Color(0xFFFFBE80))),
          ),
        ]),
      ),
    );
  }
}
