import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/catalog_repository.dart';
import '../data/chapter_alert_controller.dart';
import '../data/chapter_checker.dart';
import '../data/chapter_scan_runner.dart';
import '../data/library_store.dart';
import 'chapter_notifications_panel.dart';
import 'reader_page.dart';
import '../data/theme_controller.dart';
import '../data/firebase_account_service.dart';
import 'cloud_account_panel.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.repository, required this.library,
    required this.alerts, this.themes, this.accounts});
  final CatalogRepository repository;
  final LibraryStore library;
  final ChapterAlertController alerts;
  final ThemeController? themes;
  final FirebaseAccountService? accounts;
  @override State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _backupBusy = false;
  String? _backupResult;
  String? _lastBackupDigest;

  Future<void> _saveBackup() async {
    if (_backupBusy) return;
    setState(() => _backupBusy = true);
    try {
      final raw = await widget.library.exportBackup();
      final preview = widget.library.previewBackup(raw);
      final bytes = Uint8List.fromList(utf8.encode(raw));
      final digest = sha256.convert(bytes).toString();
      final result = await FilePicker.saveFile(
        dialogTitle: 'Сохранить резервную копию SenReader',
        fileName: 'senreader-backup-${DateTime.now().millisecondsSinceEpoch}.json',
        type: FileType.custom, allowedExtensions: ['json'], bytes: bytes);
      if (result == null || !mounted) return;
      setState(() {
        _lastBackupDigest = digest;
        _backupResult = 'Сохранение завершено: ${preview.books} произведений. '
            'Открой файл кнопкой «Проверить файл копии», чтобы проверить запись.\nSHA-256: $digest';
      });
    } catch (error) {
      debugPrint('SenReaderBackup stage=save status=error kind='
          '${error is PlatformException ? 'platform' : error is FormatException ? 'format' : 'other'}');
      if (mounted) setState(() => _backupResult =
        'Не удалось сохранить файл резервной копии. Выбери доступную папку и повтори.');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _verifyBackupFile() async {
    if (_backupBusy) return;
    setState(() => _backupBusy = true);
    try {
      final result = await FilePicker.pickFiles(type: FileType.custom,
        allowedExtensions: ['json'], withData: false);
      if (result == null) return;
      final selected = result.files.single;
      const maxBytes = 8 * 1024 * 1024;
      if (selected.path == null || selected.size > maxBytes) {
        throw const FormatException('Backup file unavailable or too large');
      }
      final file = File(selected.path!);
      if (await file.length() > maxBytes) throw const FormatException('Backup too large');
      final bytes = await file.readAsBytes();
      final preview = widget.library.previewBackup(utf8.decode(bytes));
      final digest = sha256.convert(bytes).toString();
      if (_lastBackupDigest != null && digest != _lastBackupDigest) {
        throw const FormatException('Backup differs from saved snapshot');
      }
      if (mounted) setState(() => _backupResult =
        'Файл проверен: ${preview.books} произведений. '
        'Совместимый формат, импорт не выполнялся.\nSHA-256: $digest');
    } catch (error) {
      debugPrint('SenReaderBackup stage=verify status=error kind='
          '${error is PlatformException ? 'platform' : error is FormatException ? 'format' : 'other'}');
      if (mounted) setState(() => _backupResult =
        'Файл не прошёл проверку. Выбери сохранённую копию SenReader.');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _pasteBackup() async {
    try {
      final raw = (await Clipboard.getData('text/plain'))?.text;
      if (raw == null || raw.isEmpty) throw const FormatException('Пустой буфер');
      final preview = widget.library.previewBackup(raw);
      if (!mounted) return;
      final approved = await showDialog<bool>(context: context,
        builder: (context) => AlertDialog(
          title: const Text('Восстановить библиотеку?'),
          content: Text('Найдено произведений: ${preview.books}. '
              'Существующие записи не заменяются и не удаляются. '
              'Импортируй только собственную сохранённую копию.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Импортировать')),
          ],
        ));
      if (approved != true || !mounted) return;
      final report = await widget.library.importBackup(raw);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Добавлено: ${report.added}; уже существовали: ${report.skipped}.')));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Резервная копия повреждена или не относится к SenReader.')));
    }
  }

  bool checking = false;
  ChapterScanReport? report;
  String? error;

  Future<void> _check() async {
    if (checking) return;
    setState(() { checking = true; error = null; });
    try {
      final next = await ChapterScanRunner(repository: widget.repository,
          library: widget.library, preferences: widget.alerts.preferences).checkManual();
      if (mounted) setState(() { report = next; checking = false; });
    } catch (_) {
      if (mounted) setState(() {
        checking = false;
        error = 'Не удалось завершить проверку глав. Попробуй позже.';
      });
    }
  }

  Future<void> _open(ChapterDiscovery discovery) async {
    final saved = widget.library.get(discovery.book);
    if (saved == null || !saved.entries.containsKey(discovery.sourceKey)) return;
    final source = widget.repository.sources[discovery.sourceKey];
    final entry = saved.entries[discovery.sourceKey];
    if (source == null || entry == null) return;
    try {
      final detail = await source.detail(entry);
      if (!mounted || !(widget.library.get(discovery.book)?.entries.containsKey(discovery.sourceKey) ?? false)) return;
      if (!detail.chapters.any((chapter) => chapter.id == discovery.chapter.id)) return;
      await Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderPage(
        book: saved.toUnified(), chapter: discovery.chapter,
        sourceKey: discovery.sourceKey, repository: widget.repository,
        library: widget.library, chapters: detail.chapters,
      )));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть главу.')));
    }
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Настройки')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      if (widget.accounts != null) ...[
        CloudAccountPanel(accounts: widget.accounts!),
        const SizedBox(height: 24),
      ],
      const Text('Оформление', style: TextStyle(
        fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      Builder(builder: (context) {
        final controller = widget.themes;
        if (controller == null) return const SizedBox.shrink();
        return AnimatedBuilder(animation: controller, builder: (context, _) =>
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final option in const [
              (ThemeMode.dark, 'Тёмная'),
              (ThemeMode.light, 'Светлая'),
              (ThemeMode.system, 'Системная'),
            ])
              ChoiceChip(
                key: ValueKey('theme-${option.$1.name}'),
                label: Text(option.$2),
                selected: controller.mode == option.$1,
                onSelected: (_) => controller.setMode(option.$1),
              ),
          ]),
        );
      }),
      const SizedBox(height: 24),
      const Text('Уведомления', style: TextStyle(
        fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      ChapterNotificationsPanel(alerts: widget.alerts),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: checking ? null : _check,
        icon: const Icon(Icons.refresh),
        label: Text(checking ? 'Проверяем источник…' : 'Проверить новые главы')),
      if (error != null) Text(error!),
      if (report != null) ...[
        const SizedBox(height: 12),
        Text('Проверено произведений: ${report!.checkedTitles}. '
            'Обновлено произведений: ${report!.updatedTitles}. '
            'Новых доступных глав: ${report!.discoveries.length}. '
            'Первая проверка источника сохраняет исходное состояние.'),
        for (final discovery in report!.discoveries)
          ListTile(title: Text(discovery.book.title),
            subtitle: Text('${discovery.chapter.name} · ${discovery.sourceKey}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(discovery)),
        for (final warning in report!.warnings.take(8))
          Padding(padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(warning, style: const TextStyle(color: Color(0xFFFFBE80)))),
      ],
      const Text('Резервная копия библиотеки', style: TextStyle(
        fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Text('Сохрани JSON-файл в отдельном надёжном месте и проверь его. '
          'Копия содержит книги, источники, избранное, историю и прогресс чтения. '
          'Уведомления, тема и авторизация в эту копию не входят.'),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          key: const Key('backup-save'),
          onPressed: _backupBusy ? null : _saveBackup,
          icon: const Icon(Icons.save_alt),
          label: const Text('Сохранить копию в файл')),
        OutlinedButton.icon(
          key: const Key('backup-verify'),
          onPressed: _backupBusy ? null : _verifyBackupFile,
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('Проверить файл копии')),
        OutlinedButton.icon(
          key: const Key('backup-restore'),
          onPressed: _backupBusy ? null : _pasteBackup,
          icon: const Icon(Icons.restore),
          label: const Text('Импорт из буфера')),
      ]),
      if (_backupResult != null) Padding(
        padding: const EdgeInsets.only(top: 12),
        child: SelectableText(_backupResult!)),
      const SizedBox(height: 24),
    ]),
  );
}
