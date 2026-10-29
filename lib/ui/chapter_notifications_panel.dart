import 'package:flutter/material.dart';
import '../data/chapter_alert_controller.dart';

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

  @override void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = widget.alerts.preferences;
    final newEnabled = await prefs.enabled();
    await prefs.intervalMinutes();
    if (!mounted) return;
    setState(() {
      enabled = newEnabled;
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
            subtitle: const Text('Только выбранный источник каждой книги'),
            value: enabled,
            onChanged: loading ? null : _toggle,
          ),
          const Text(
            'Проверки раз в 15 минут — по возможности Android: Doze и экономия батареи '
            'могут задерживать их. Первое сканирование сохраняет '
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
