import 'package:flutter/material.dart';
import '../data/chapter_alert_controller.dart';
import '../data/chapter_scan_schedule.dart';
import '../data/library_store.dart';

class ChapterNotificationsPanel extends StatefulWidget {
  const ChapterNotificationsPanel({super.key, required this.alerts});
  final ChapterAlertController alerts;
  @override State<ChapterNotificationsPanel> createState() =>
      _ChapterNotificationsPanelState();
}

class _ChapterNotificationsPanelState extends State<ChapterNotificationsPanel> {
  bool loading = true;
  bool enabled = false;
  String? message;
  ChapterBackgroundScanSummary? lastRun;

  @override void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = widget.alerts.preferences;
    final newEnabled = await prefs.enabled();
    await prefs.intervalMinutes();
    final library = LibraryStore();
    await library.load();
    final last = await ChapterScanScheduleStore().lastRun(library.profileId);
    if (!mounted) return;
    setState(() {
      enabled = newEnabled;
      lastRun = last;
      loading = false;
    });
  }

  Future<void> _toggle(bool next) async {
    setState(() { loading = true; message = null; });
    try {
      final allowed = await widget.alerts.setEnabled(next);
      if (mounted) setState(() {
        enabled = allowed;
        loading = false;
        if (next && !allowed) message = 'Разреши уведомления SenReader в настройках Android.';
      });
    } catch (_) {
      if (mounted) setState(() {
        enabled = false;
        loading = false;
        message = 'Не удалось изменить фоновую проверку на этом устройстве.';
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
            subtitle: const Text('Автопроверка только произведений в разделе «Читаю»'),
            value: enabled,
            onChanged: loading ? null : _toggle,
          ),
          Text(
            'Проверки раз в 15 минут — по возможности Android: Doze и экономия батареи '
            'могут задерживать их. За один запуск проверяется до 12 источников; '
            'при большой библиотеке очередь занимает несколько запусков. '
            'Только книги со статусом «Читаю» проверяются не чаще '
            'раза в 30 минут. «В планах» и «Прочитано» '
            'не проверяются даже при ручном обновлении уведомлений. '
            'При открытии приложения пропущенные проверки выполняются автоматически. '
            'Мгновенная доставка не гарантируется.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          if (lastRun != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Последняя фоновая попытка: '
              '${lastRun!.at.day.toString().padLeft(2, '0')}.'
              '${lastRun!.at.month.toString().padLeft(2, '0')} '
              '${lastRun!.at.hour.toString().padLeft(2, '0')}:'
              '${lastRun!.at.minute.toString().padLeft(2, '0')}. '
              'Источников проверено: ${lastRun!.checkedSources}, '
              'отложено (интервал или очередь): ${lastRun!.skippedSources}, '
              'найдено глав: ${lastRun!.foundChapters}.',
              style: TextStyle(fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
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
