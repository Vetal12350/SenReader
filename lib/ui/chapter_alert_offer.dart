import 'package:flutter/material.dart';
import '../data/chapter_alert_controller.dart';

Future<void> offerChapterAlerts(BuildContext context, ChapterAlertController alerts) async {
  if (!await alerts.claimOffer() || !context.mounted) return;
  final enable = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
    title: const Text('Включить уведомления о новых главах?'),
    content: const Text('Проверяем только выбранный источник каждой книги. '
        'Уведомления можно изменить в настройках.'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Не сейчас')),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Включить')),
    ],
  ));
  if (enable != true) return;
  try {
    final enabled = await alerts.setEnabled(true);
    if (!enabled && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Уведомления выключены. Их можно включить в настройках.')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Не удалось включить уведомления. Попробуй в настройках.')));
    }
  }
}
