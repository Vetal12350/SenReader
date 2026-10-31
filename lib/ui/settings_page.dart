import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/catalog_repository.dart';
import '../data/chapter_alert_controller.dart';
import '../data/chapter_checker.dart';
import '../data/library_store.dart';
import 'chapter_notifications_panel.dart';
import 'reader_page.dart';
import '../data/theme_controller.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.repository, required this.library,
    required this.alerts, this.themes});
  final CatalogRepository repository;
  final LibraryStore library;
  final ChapterAlertController alerts;
  final ThemeController? themes;
  @override State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Future<void> _copyBackup() async {
    try {
      final raw = await widget.library.exportBackup();
      await Clipboard.setData(ClipboardData(text: raw));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Копия скопирована. Сохрани текст в надёжном месте до удаления приложения.')));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Не удалось создать копию библиотеки.')));
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
      await widget.library.load();
      final next = await ChapterChecker(repository: widget.repository,
          library: widget.library).check();
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
    if (saved == null || saved.preferredSource != discovery.sourceKey) return;
    final source = widget.repository.sources[discovery.sourceKey];
    final entry = saved.entries[discovery.sourceKey];
    if (source == null || entry == null) return;
    try {
      final detail = await source.detail(entry);
      if (!mounted || widget.library.get(discovery.book)?.preferredSource != discovery.sourceKey) return;
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
      const Text('Перед переходом с debug APK на постоянную подпись '
          'скопируй резервную копию и обязательно сохрани текст '
          'в отдельном надёжном месте. Один буфер обмена ненадёжен. '
          'В копию входят книги, источники, избранное и история чтения. '
          'Уведомления и тема после переустановки настраиваются заново.'),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          key: const Key('backup-copy'),
          onPressed: _copyBackup,
          icon: const Icon(Icons.copy_outlined),
          label: const Text('Копировать библиотеку')),
        OutlinedButton.icon(
          key: const Key('backup-restore'),
          onPressed: _pasteBackup,
          icon: const Icon(Icons.restore),
          label: const Text('Импорт из буфера')),
      ]),
      const SizedBox(height: 24),
    ]),
  );
}
