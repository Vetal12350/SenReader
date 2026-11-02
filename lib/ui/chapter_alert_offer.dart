import 'package:flutter/material.dart';
import '../data/chapter_alert_controller.dart';

Future<void> offerChapterAlerts(BuildContext context, ChapterAlertController alerts) async {
  if (!await alerts.claimOffer() || !context.mounted) return;
  final enable = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
    title: const Text('Включить фоновую проверку новых глав?'),
    content: const Text('Проверяем только книги из «Читаю», сохраняя главы внутри приложения. '
        'Уведомления Android включаются отдельно в настройках.'),
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
        content: Text('Фоновую проверку можно включить в настройках.')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Не удалось включить фоновую проверку. Попробуй в настройках.')));
    }
  }
}
