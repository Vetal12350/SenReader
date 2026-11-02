import 'dart:async';
import 'package:flutter/material.dart';
import '../data/chapter_alert_controller.dart';
import '../data/chapter_scan_schedule.dart';
import '../data/chapter_scan_runner.dart';
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
  bool systemEnabled = false;
  bool systemLoading = false;
  String? message;
  ChapterBackgroundScanSummary? lastRun;
  ChapterBackgroundScanSummary? lastWorkerRun;
  bool? registrationSucceeded;
  Timer? _diagnosticTimer;

  @override void initState() {
    super.initState();
    _load();
    _diagnosticTimer = Timer.periodic(const Duration(seconds: 8),
        (_) => unawaited(_refreshDiagnostics()));
  }

  @override void dispose() {
    _diagnosticTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshDiagnostics() async {
    final profile = await ChapterScanRunner.activeProfile();
    final store = ChapterScanScheduleStore();
    final last = await store.lastRun(profile);
    final worker = await store.lastRun(profile, workmanagerOnly: true);
    final registered = await store.registrationSucceeded(profile);
    if (!mounted || await ChapterScanRunner.activeProfile() != profile) return;
    setState(() {
      lastRun = last; lastWorkerRun = worker; registrationSucceeded = registered;
    });
  }

  Future<void> _load() async {
    final prefs = widget.alerts.preferences;
    final newEnabled = await prefs.enabled();
    final newSystemEnabled = await prefs.systemNotificationsEnabled();
    await prefs.intervalMinutes();
    final library = LibraryStore();
    await library.load();
    final last = await ChapterScanScheduleStore().lastRun(library.profileId);
    final worker = await ChapterScanScheduleStore().lastRun(library.profileId,
      workmanagerOnly: true);
    final registered = await ChapterScanScheduleStore().registrationSucceeded(library.profileId);
    if (!mounted) return;
    setState(() {
      enabled = newEnabled;
      systemEnabled = newSystemEnabled;
      lastRun = last;
      lastWorkerRun = worker;
      registrationSucceeded = registered;
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
        if (next && !allowed) message = 'Не удалось запустить автоматическую проверку.';
      });
    } catch (_) {
      if (mounted) setState(() {
        enabled = false;
        loading = false;
        message = 'Не удалось изменить фоновую проверку на этом устройстве.';
      });
    }
  }

  Future<void> _toggleSystem(bool next) async {
    setState(() { systemLoading = true; message = null; });
    try {
      final allowed = await widget.alerts.setSystemNotificationsEnabled(next);
      if (mounted) setState(() {
        systemEnabled = allowed;
        systemLoading = false;
        if (next && !allowed) {
          message = 'Разрешение Android не выдано. Внутренние обновления продолжают работать.';
        }
      });
    } catch (_) {
      if (mounted) setState(() {
        systemEnabled = false;
        systemLoading = false;
        message = 'Не удалось включить системные уведомления.';
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
            title: const Text('Автоматически искать новые главы'),
            subtitle: const Text('Новые главы сохраняются в приложении без разрешения Android'),
            value: enabled,
            onChanged: loading ? null : _toggle,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Системные уведомления Android'),
            subtitle: const Text('Необязательно: уведомления о новых главах на телефоне'),
            value: systemEnabled,
            onChanged: systemLoading ? null : _toggleSystem,
          ),
          Text(
            'Проверки раз в 15 минут — по возможности Android: Doze и экономия батареи '
            'могут задерживать их. Фоновая задача требует сети и достаточного заряда. '
            'За один запуск очередь обрабатывается до 2 минут; '
            'при большой библиотеке очередь занимает несколько запусков. '
            'Только книги со статусом «Читаю» проверяются не чаще '
            'раза в 30 минут после успешной проверки. «В планах» и «Прочитано» '
            'не проверяются даже при ручном обновлении уведомлений. '
            'При открытии приложения пропущенные проверки выполняются автоматически. '
            'Мгновенная доставка не гарантируется.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          ChapterScanDiagnostics(lastRun: lastRun,
            lastWorkerRun: lastWorkerRun,
            registrationSucceeded: registrationSucceeded),
          if (message != null) Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(message!, style: const TextStyle(color: Color(0xFFFFBE80))),
          ),
        ]),
      ),
    );
  }
}


/// Fixed, non-personal diagnostic codes are translated only at the UI boundary.
class ChapterScanDiagnostics extends StatelessWidget {
  const ChapterScanDiagnostics({super.key, this.lastRun, this.lastWorkerRun,
    this.registrationSucceeded});
  final ChapterBackgroundScanSummary? lastRun, lastWorkerRun;
  final bool? registrationSucceeded;

  static String date(DateTime value) {
    final d = value.toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${pad(d.day)}.${pad(d.month)}.${d.year} ${pad(d.hour)}:${pad(d.minute)}:${pad(d.second)}';
  }

  @override Widget build(BuildContext context) {
    final last = lastRun;
    final text = last == null
      ? 'Автоматическая проверка ещё не запускалась или её запуск не был сохранён.'
      : 'Последняя автоматическая попытка: ${date(last.at)} '
        '(${last.origin == 'app' ? 'при открытии приложения' : 'WorkManager'}). '
        '${last.resultText}. '
        '${last.reasonText.isEmpty ? '' : '${last.reasonText}. '}'
        'Источников проверено: ${last.checkedSources}, '
        'отложено: ${last.skippedSources}, найдено глав: ${last.foundChapters}. '
        '${last.nextEligibleAt == null ? '' : 'Не ранее: ${date(last.nextEligibleAt!)}. Это нижняя граница очереди, а не точное время запуска Android.'}';
    return Padding(padding: const EdgeInsets.only(top: 8),
      child: Text('$text\n${lastWorkerRun == null
        ? 'Запуск WorkManager ещё не подтверждён.'
        : 'Последняя задача WorkManager: ${date(lastWorkerRun!.at)}. ${lastWorkerRun!.resultText}. ${lastWorkerRun!.reasonText}'}\n${registrationSucceeded == false
        ? 'Не удалось зарегистрировать задачи Android. Проверка при открытии доступна; регистрация повторится при следующем открытии.'
        : registrationSucceeded == true ? 'Задачи Android зарегистрированы. Регистрация не подтверждает их фактический запуск.'
        : 'Подтверждения регистрации задач Android пока нет.'}',
        style: TextStyle(fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant)));
  }
}
