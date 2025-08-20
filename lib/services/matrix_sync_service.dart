import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;

class MatrixSyncService {
  MatrixSyncService._();
  static final MatrixSyncService instance = MatrixSyncService._();
  late mx.Client _client;
  final _events = StreamController<mx.Event>.broadcast();
  Stream<mx.Event> get events => _events.stream;
  Stream<mx.Event> roomEvents(String roomId) =>
      _events.stream.where((e) => (e.room?.id ?? e.roomId) == roomId);

  void attachClient(mx.Client client) {
    _client = client;
    _client.onEvent.stream.listen((upd) {
      final mx.Event? ev = (upd as dynamic).event as mx.Event?;
      if (ev != null) _events.add(ev);
    }, onError: (e, st) {
      debugPrint('MatrixSyncService onEvent error: $e\n$st');
    });
  }

  void start() {
    try {
      _client.backgroundSync = true;
      _client.sync();
    } catch (e, st) {
      debugPrint('MatrixSyncService start error: $e\n$st');
    }
  }

  void dispose() {
    _events.close();
  }
}
