import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Android "ignore battery optimizations" for background chapter checks.
/// The system shows its own dialog; nothing changes without the owner's tap.
class BatteryOptimizationAccess {
  const BatteryOptimizationAccess();
  Future<bool> isExempt() async =>
      await Permission.ignoreBatteryOptimizations.isGranted;
  Future<bool> request() async =>
      (await Permission.ignoreBatteryOptimizations.request()).isGranted;
}

/// Same idea as Mihon's onboarding step: without the exemption Android
/// may hold periodic checks for hours and refuse the foreground service.
class BatteryOptimizationTile extends StatefulWidget {
  const BatteryOptimizationTile({super.key,
    this.access = const BatteryOptimizationAccess(), this.androidOnly = true});
  final BatteryOptimizationAccess access;
  final bool androidOnly;
  @override State<BatteryOptimizationTile> createState() =>
      _BatteryOptimizationTileState();
}

class _BatteryOptimizationTileState extends State<BatteryOptimizationTile>
    with WidgetsBindingObserver {
  bool? exempt;
  bool busy = false;

  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The user may change it in system settings and come back.
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final value = await widget.access.isExempt();
      if (mounted) setState(() => exempt = value);
    } catch (_) {
      if (mounted) setState(() => exempt = null);
    }
  }

  Future<void> _request() async {
    setState(() => busy = true);
    try {
      final value = await widget.access.request();
      if (mounted) setState(() => exempt = value);
    } catch (_) {
      await _refresh();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override Widget build(BuildContext context) {
    if (widget.androidOnly && defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    final granted = exempt == true;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(granted ? Icons.battery_charging_full : Icons.battery_alert),
      title: const Text('Фоновые проверки без ограничений батареи'),
      subtitle: Text(granted
          ? 'Разрешено: Android не будет откладывать проверки новых глав'
          : 'Сейчас Android может откладывать проверки на часы. '
            'Разрешите работу в фоне, чтобы уведомления приходили вовремя'),
      trailing: granted ? const Icon(Icons.check_circle_outline) : FilledButton.tonal(
        onPressed: busy || exempt == null ? null : _request,
        child: const Text('Разрешить'),
      ),
    );
  }
}
