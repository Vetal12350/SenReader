import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'library_store.dart';
import 'cloud_library_sync.dart';

/// Public Firebase client identifiers; no admin key or service-account
/// credentials are ever embedded in the Android application.
class SenReaderFirebaseConfig {
  static const apiKey = String.fromEnvironment('SENREADER_FIREBASE_API_KEY');
  static const appId = String.fromEnvironment('SENREADER_FIREBASE_APP_ID');
  static const projectId = String.fromEnvironment('SENREADER_FIREBASE_PROJECT_ID');
  static const senderId = String.fromEnvironment('SENREADER_FIREBASE_SENDER_ID');
  static const webClientId =
      String.fromEnvironment('SENREADER_GOOGLE_WEB_CLIENT_ID');

  static bool get configured => apiKey.isNotEmpty && appId.isNotEmpty &&
      projectId.isNotEmpty && senderId.isNotEmpty;

  static FirebaseOptions get options => const FirebaseOptions(
    apiKey: apiKey, appId: appId, projectId: projectId,
    messagingSenderId: senderId,
  );
}

class FirebaseAccountService extends ChangeNotifier {
  FirebaseAccountService(this.library);
  final LibraryStore library;
  FirebaseAuth? _auth;
  CloudLibrarySync? cloud;
  StreamSubscription<User?>? _authListener;
  Future<void>? _googleInit;
  User? user;
  bool busy = false;
  bool ready = false;
  String? error;
  int _generation = 0;

  bool get configured => SenReaderFirebaseConfig.configured;
  bool get signedIn => user != null;
  bool get emailVerified => user?.emailVerified == true;
  bool get googleLinked => user?.providerData
      .any((provider) => provider.providerId == 'google.com') == true;

  Future<void> initialize() async {
    if (ready || busy) return;
    if (!configured) {
      await library.switchProfile(null);
      ready = true;
      notifyListeners();
      return;
    }
    busy = true;
    notifyListeners();
    try {
      await Firebase.initializeApp(options: SenReaderFirebaseConfig.options);
      _auth = FirebaseAuth.instance;
      cloud = CloudLibrarySync(library, FirebaseFirestore.instance);
      cloud!.addListener(notifyListeners);
      _authListener = _auth!.authStateChanges().listen(
          (next) => unawaited(_setUser(next)));
      ready = true;
      error = null;
    } catch (_) {
      error = 'Не удалось подключиться к Firebase.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _setUser(User? next) async {
    final generation = ++_generation;
    try {
      // User is not exposed to cloud sync until the email is verified.
      await cloud?.start(next?.emailVerified == true ? next?.uid : null);
      if (generation != _generation) return;
      user = next;
      error = null;
    } catch (_) {
      error = 'Ошибка переключения аккаунта';
    }
    notifyListeners();
  }

  Future<T> _perform<T>(Future<T> Function() action) async {
    if (_auth == null) throw StateError('Firebase is not configured');
    if (busy) throw StateError('Операция уже выполняется');
    busy = true;
    error = null;
    notifyListeners();
    try {
      return await action();
    } on FirebaseAuthException catch (e) {
      error = switch (e.code) {
        'wrong-password' || 'invalid-credential' || 'user-not-found' =>
          'Проверь адрес почты и пароль.',
        'email-already-in-use' => 'Эта почта уже зарегистрирована.',
        'weak-password' => 'Пароль слишком простой.',
        'invalid-email' => 'Неверный адрес электронной почты.',
        'too-many-requests' => 'Слишком много попыток. Попробуй позже.',
        'requires-recent-login' => 'Для этого действия войди заново.',
        'credential-already-in-use' => 'Google уже привязан к другому аккаунту.',
        'account-exists-with-different-credential' =>
          'Этот адрес уже используется. Войди прежним способом.',
        _ => 'Ошибка авторизации (${e.code}).',
      };
      rethrow;
    } catch (_) {
      error ??= 'Операция не выполнена. Проверь соединение.';
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> signInEmail(String email, String password) =>
      _perform(() async {
        await _auth!.signInWithEmailAndPassword(
          email: email.trim(), password: password);
      });

  Future<void> registerEmail(String email, String password) =>
      _perform(() async {
        final credential = await _auth!.createUserWithEmailAndPassword(
          email: email.trim(), password: password);
        await credential.user?.sendEmailVerification();
      });

  Future<void> resetPassword(String email) => _perform(() async {
    await _auth!.sendPasswordResetEmail(email: email.trim());
  });

  Future<void> resendVerification() => _perform(() async {
    await _auth!.currentUser?.sendEmailVerification();
  });

  Future<void> refreshVerification() => _perform(() async {
    await _auth!.currentUser?.reload();
    // Refresh the email_verified claim required by owner-only Firestore rules.
    await _auth!.currentUser?.getIdToken(true);
    await _setUser(_auth!.currentUser);
  });

  Future<void> updatePassword(String password) => _perform(() async {
    await _auth!.currentUser?.updatePassword(password);
  });

  Future<AuthCredential> _googleCredential() async {
    if (SenReaderFirebaseConfig.webClientId.isEmpty) {
      throw StateError('Не настроен Google Web OAuth Client ID');
    }
    _googleInit ??= GoogleSignIn.instance.initialize(
      serverClientId: SenReaderFirebaseConfig.webClientId);
    await _googleInit;
    final google = await GoogleSignIn.instance.authenticate();
    final idToken = google.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw StateError('Google не предоставил токен входа');
    }
    return GoogleAuthProvider.credential(idToken: idToken);
  }

  Future<void> signInGoogle() => _perform(() async {
    await _auth!.signInWithCredential(await _googleCredential());
  });

  Future<void> linkGoogle() => _perform(() async {
    final current = _auth!.currentUser;
    if (current == null) return;
    await current.linkWithCredential(await _googleCredential());
    await current.reload();
    await _setUser(_auth!.currentUser);
  });

  Future<void> signOut() => _perform(() async {
    // Switch to guest data before returning to the main reader.
    await cloud?.stop();
    user = null;
    await _auth!.signOut();
    notifyListeners();
  });

  Future<({int added, int skipped})> importGuest() async {
    if (user == null || !emailVerified) {
      throw StateError('Подтверди почту перед облачной синхронизацией');
    }
    final result = await library.importGuestLibrary();
    cloud?.refresh();
    return result;
  }

  @override void dispose() {
    unawaited(_authListener?.cancel());
    cloud?.removeListener(notifyListeners);
    cloud?.dispose();
    super.dispose();
  }
}
