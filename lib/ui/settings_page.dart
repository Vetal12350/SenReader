import 'package:flutter/material.dart';
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
          SegmentedButton<ThemeMode>(
            key: const Key('theme-mode-selector'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_outlined),
                label: Text('Тёмная')),
              ButtonSegment(value: ThemeMode.light,
                icon: Icon(Icons.light_mode_outlined),
                label: Text('Светлая')),
              ButtonSegment(value: ThemeMode.system,
                icon: Icon(Icons.settings_brightness),
                label: Text('Системная')),
            ],
            selected: {controller.mode},
            onSelectionChanged: (mode) => controller.setMode(mode.first),
          ),
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
    ]),
  );
}
