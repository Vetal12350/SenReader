import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'library_store.dart';
import 'reader_activity.dart';

/// Sync only a signed-in profile. No guest data is uploaded implicitly.
///
/// Each book (or deletion tombstone) is an independent Firestore document.
/// This keeps costs small and protects unrelated titles from whole-library
/// overwrites. Last-modified ordering applies per title, not per account.
class CloudLibrarySync extends ChangeNotifier {
  CloudLibrarySync(this.library, this.firestore);
  final LibraryStore library;
  final FirebaseFirestore firestore;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  Timer? _debounce;
  // Measured on Pixel: every progress save triggered a full collection fetch,
  // merge, export and an echo snapshot, all on the main thread the reader
  // shares (29-43 ms stalls every ~13 s). While reading, keep progress local
  // and sync once when the reader closes.
  final ReaderDeferral _whileReading = ReaderDeferral();
  Future<void> _chain = Future<void>.value();
  String _uid = '';
  int _generation = 0;
  bool _connected = false;
  bool _applying = false;
  String? error;
  DateTime? lastSynced;

  bool get active => _uid.isNotEmpty;
  bool get connected => _connected;
  CollectionReference<Map<String, dynamic>> get _collection =>
      firestore.collection('users').doc(_uid).collection('library');

  /// UTF8 hash avoids slashes, huge titles and invalid Firestore doc IDs.
  static String documentId(String bookKey) =>
      sha256.convert(utf8.encode(bookKey)).toString();

  Future<void> start(String? uid) async {
    final next = uid ?? '';
    if (_uid == next && library.profileId == next) return;
    await _subscription?.cancel();
    _subscription = null;
    library.removeListener(_onLocalLibraryChange);
    _debounce?.cancel();
    _connected = false;
    _uid = next;
    final session = ++_generation;
    // Wait for previous work before changing the physical preference key.
    await _chain.catchError((Object _) {});
    await library.switchProfile(next);
    if (session != _generation || next.isEmpty) {
      notifyListeners();
      return;
    }
    library.addListener(_onLocalLibraryChange);
    _subscription = _collection.snapshots(includeMetadataChanges: true)
        .listen((snapshot) {
      // hasPendingWrites: the echo of our own unacknowledged upload; the
      // server-confirmed snapshot follows and is the one worth merging.
      if (session != _generation || snapshot.metadata.isFromCache ||
          snapshot.metadata.hasPendingWrites) return;
      _connected = true;
      _whileReading.run('snapshot', () => _applySnapshot(snapshot, session));
    }, onError: (Object _) {
      if (session != _generation) return;
      _connected = false;
      error = 'Нет доступа к облачной библиотеке. Проверь правила Firestore.';
      notifyListeners();
    });
    notifyListeners();
  }

  void _applySnapshot(QuerySnapshot<Map<String, dynamic>> snapshot, int session) {
      if (session != _generation) return;
      _chain = _chain.catchError((Object _) {}).then((_) async {
        if (session != _generation) return;
        try {
          final cloud = <String, Map<String, dynamic>>{};
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final key = data['key'];
            if (key is! String || key.isEmpty ||
                documentId(key) != doc.id) continue;
            cloud[key] = data;
          }
          _applying = true;
          try {
            await library.mergeCloudRecords(cloud);
          } finally {
            _applying = false;
          }
          if (session != _generation) return;
          await _uploadNewer(cloud, session);
          error = null;
          lastSynced = DateTime.now();
        } catch (_) {
          error = 'Не удалось синхронизировать библиотеку';
        }
        notifyListeners();
      });
  }

  void _onLocalLibraryChange() {
    if (_applying || !_connected || _uid.isEmpty) return;
    if (_whileReading.reading) {
      _whileReading.run('local', _onLocalLibraryChange);
      return;
    }
    _debounce?.cancel();
    final session = _generation;
    _debounce = Timer(const Duration(milliseconds: 1000), () {
      _chain = _chain.catchError((Object _) {}).then((_) async {
        if (session != _generation || !_connected) return;
        try {
          final snapshot = await _collection.get(
              const GetOptions(source: Source.server));
          if (session != _generation) return;
          final cloud = <String, Map<String, dynamic>>{};
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final key = data['key'];
            if (key is String && documentId(key) == doc.id) {
              cloud[key] = data;
            }
          }
          _applying = true;
          try {
            await library.mergeCloudRecords(cloud);
          } finally {
            _applying = false;
          }
          await _uploadNewer(cloud, session);
          error = null;
          lastSynced = DateTime.now();
        } catch (_) {
          error = 'Нет соединения. Локальные изменения сохранены.';
        }
        notifyListeners();
      });
    });
  }

  Future<void> _uploadNewer(
      Map<String, Map<String, dynamic>> cloud, int session) async {
    final local = await library.exportCloudRecords();
    if (session != _generation) return;
    var batch = firestore.batch();
    var count = 0;
    Future<void> flush() async {
      if (count == 0) return;
      await batch.commit();
      batch = firestore.batch();
      count = 0;
    }
    for (final entry in local.entries) {
      if (session != _generation) return;
      final edited = (entry.value['editedAt'] as num?)?.toInt() ?? 0;
      final remoteEdited =
          (cloud[entry.key]?['editedAt'] as num?)?.toInt() ?? 0;
      if (edited <= remoteEdited) continue;
      batch.set(_collection.doc(documentId(entry.key)),
          {'key': entry.key, ...entry.value});
      count++;
      if (count >= 200) await flush();
    }
    await flush();
  }

  /// Reconcile on demand after the user explicitly imports guest titles.
  void refresh() => _onLocalLibraryChange();

  Future<void> stop() async {
    ++_generation;
    _debounce?.cancel();
    library.removeListener(_onLocalLibraryChange);
    await _subscription?.cancel();
    _subscription = null;
    await _chain.catchError((Object _) {}).timeout(
      const Duration(seconds: 3), onTimeout: () {});
    _uid = '';
    _connected = false;
    await library.switchProfile(null);
    notifyListeners();
  }

  @override void dispose() {
    _whileReading.dispose();
    _debounce?.cancel();
    library.removeListener(_onLocalLibraryChange);
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
