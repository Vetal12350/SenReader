import 'package:flutter/material.dart';
import '../data/firebase_account_service.dart';

/// Entirely optional: when Firebase is not provisioned SenReader stays local.
class CloudAccountPanel extends StatefulWidget {
  const CloudAccountPanel({super.key, required this.accounts});
  final FirebaseAccountService accounts;
  @override State<CloudAccountPanel> createState() => _CloudAccountPanelState();
}

class _CloudAccountPanelState extends State<CloudAccountPanel> {
  final email = TextEditingController();
  final password = TextEditingController();
  final newPassword = TextEditingController();
  bool showPassword = false;
  bool registration = false;
  String? info;

  @override void dispose() {
    email.dispose();
    password.dispose();
    newPassword.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() => info = null);
    try {
      await action();
      if (mounted && success != null) setState(() => info = success);
    } catch (_) {
      // The account controller presents a sanitized error.
      if (mounted) setState(() {});
    }
  }

  Future<void> _importGuest() async {
    final confirmed = await showDialog<bool>(context: context,
      builder: (context) => AlertDialog(
        title: const Text('Импортировать гостевую библиотеку?'),
        content: const Text(
          'Гостевые закладки останутся на устройстве. В аккаунт добавятся '
          'только отсутствующие тайтлы; существующие записи не заменяются.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
            child: const Text('Импортировать')),
        ],
      ));
    if (confirmed != true || !mounted) return;
    try {
      final report = await widget.accounts.importGuest();
      if (mounted) setState(() =>
        info = 'Добавлено: ${report.added}; уже есть: ${report.skipped}.');
    } catch (_) {
      if (mounted) setState(() => info = 'Не удалось импортировать библиотеку.');
    }
  }

  @override Widget build(BuildContext context) =>
    AnimatedBuilder(animation: widget.accounts, builder: (context, _) {
      final accounts = widget.accounts;
      final user = accounts.user;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Аккаунт и синхронизация', style: TextStyle(
          fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (!accounts.configured) const Text(
          'Облачный аккаунт пока не подключён администратором приложения. '
          'Читалка, закладки и резервное копирование работают локально.'),
        if (accounts.configured && !accounts.ready)
          const LinearProgressIndicator(),
        if (accounts.ready && user == null && accounts.configured) ...[
          const Text('Вход необязателен: без аккаунта можно читать как раньше. '
            'У каждого вошедшего пользователя отдельная библиотека.'),
          const SizedBox(height: 12),
          TextField(controller: email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Электронная почта', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: password,
            obscureText: !showPassword,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(labelText: 'Пароль',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: showPassword ? 'Скрыть пароль' : 'Показать пароль',
                onPressed: () => setState(() => showPassword = !showPassword),
                icon: Icon(showPassword ? Icons.visibility_off : Icons.visibility))),
          ),
          const SizedBox(height: 10),
          FilledButton(onPressed: accounts.busy ? null : () {
            if (email.text.trim().isEmpty || password.text.isEmpty) {
              setState(() => info = 'Укажи почту и пароль.');
              return;
            }
            _run(registration
                ? () => accounts.registerEmail(email.text, password.text)
                : () => accounts.signInEmail(email.text, password.text),
                success: registration
                  ? 'Письмо подтверждения отправлено на почту.' : null);
          }, child: Text(registration ? 'Зарегистрироваться' : 'Войти')),
          Wrap(spacing: 8, children: [
            TextButton(onPressed: accounts.busy ? null :
              () => setState(() => registration = !registration),
              child: Text(registration ? 'У меня уже есть аккаунт' : 'Регистрация')),
            TextButton(onPressed: accounts.busy ? null : () {
              if (email.text.trim().isEmpty) {
                setState(() => info = 'Введи почту для восстановления.');
                return;
              }
              _run(() => accounts.resetPassword(email.text),
                success: 'Если адрес зарегистрирован, придёт письмо с инструкцией.');
            }, child: const Text('Забыли пароль?')),
          ]),
          OutlinedButton.icon(
            onPressed: accounts.busy ? null :
              () => _run(accounts.signInGoogle),
            icon: const Icon(Icons.account_circle_outlined),
            label: const Text('Продолжить с Google')),
        ],
        if (user != null) ...[
          ListTile(contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(user.email ?? 'Аккаунт Firebase'),
            subtitle: Text(accounts.emailVerified
                ? 'Почта подтверждена' : 'Подтверди почту для синхронизации')),
          if (!accounts.emailVerified) ...[
            OutlinedButton(onPressed: accounts.busy ? null :
              () => _run(accounts.resendVerification,
                success: 'Письмо отправлено. Проверь почту.'),
              child: const Text('Отправить подтверждение')),
            TextButton(onPressed: accounts.busy ? null :
              () => _run(accounts.refreshVerification),
              child: const Text('Я подтвердил почту')),
          ] else ...[
            Text(accounts.cloud?.connected == true
                ? 'Облачная синхронизация активна'
                : 'Офлайн: данные остаются на устройстве'),
            if (accounts.cloud?.lastSynced != null)
              Text('Последнее соединение: ${accounts.cloud!.lastSynced}'),
            OutlinedButton.icon(
              onPressed: accounts.busy ? null : _importGuest,
              icon: const Icon(Icons.library_add_outlined),
              label: const Text('Импортировать гостевые закладки')),
            if (!accounts.googleLinked)
              OutlinedButton.icon(
                onPressed: accounts.busy ? null :
                  () => _run(accounts.linkGoogle),
                icon: const Icon(Icons.link),
                label: const Text('Привязать Google')),
            const SizedBox(height: 8),
            TextField(controller: newPassword, obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Новый пароль',
                border: OutlineInputBorder())),
            TextButton(onPressed: accounts.busy || newPassword.text.isEmpty
                ? null : () => _run(() => accounts.updatePassword(newPassword.text),
                  success: 'Пароль обновлён.'),
              child: const Text('Сменить пароль')),
          ],
          OutlinedButton(onPressed: accounts.busy ? null :
            () => _run(accounts.signOut),
            child: const Text('Выйти из аккаунта')),
        ],
        if (accounts.busy) const LinearProgressIndicator(),
        if (accounts.error != null) Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(accounts.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (accounts.cloud?.error != null) Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(accounts.cloud!.error!)),
        if (info != null) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(info!)),
      ]);
    });
}
