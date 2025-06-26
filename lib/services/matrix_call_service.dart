import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import '../main.dart';
import 'webrtc_helper.dart';
import 'matrix_chat_service.dart';
import 'package:flutter/material.dart';
import '../ui/audio_call_page.dart';

class MatrixCallService {
  final Client client;
  StreamSubscription<Event>? _sub;

  final Map<String, String> _pendingRoom  = {};
  final Map<String, Map<String, dynamic>> _pendingOffer = {};

  MatrixCallService(this.client);

  void start() {
    client.backgroundSync = true;
    client.sync();
    _sub = client.onTimelineEvent.stream
        .where((e) => e.type.startsWith('m.call.'))
        .listen(_onRoomEvent, onError: (e) => debugPrint('CallService err: $e'));
  }

  Future<void> _onRoomEvent(Event e) async {
    final roomId  = e.room.id;
    final content = e.content as Map<String, dynamic>?;
    if (content == null) return;

    switch (e.type) {
      case 'm.call.invite':
        final callId = content['call_id']  as String;
        final party  = content['party_id'] as String? ?? 'Unknown';
        final offer  = content['offer']    as Map<String, dynamic>;

        _pendingRoom[callId]  = roomId;
        _pendingOffer[callId] = offer;

        await FlutterCallkitIncoming.showCallkitIncoming(
          CallKitParams(
            id:         callId,
            nameCaller: party,
            appName:    'QalqanDSM',
            type:       0,
            textAccept: 'Принять',
            textDecline:'Отклонить',
            extra:      {'call_id': callId},
          ),
        );
        break;

      case 'm.call.answer':
      // TODO: при необходимости обрабатывать удалённый answer
        break;

      case 'm.call.candidates':
      // TODO: при необходимости обрабатывать удалённые кандидаты
        break;

      case 'm.call.hangup':
      // TODO: при необходимости обрабатывать сброс
        break;
    }
  }

  /// Вызывается из CallKit при нажатии «Принять»
  void handleCallkitAccept(String callId) {
    // 1) Логируем, что метод вызвался
    debugPrint('[CallService] accept called with callId=$callId');

    // 2) Достаём roomId и offer из pending
    final roomId = _pendingRoom.remove(callId);
    final offer  = _pendingOffer.remove(callId);

    debugPrint('[CallService] accept: callId=$callId -> roomId=$roomId');

    // 3) Навигация обязательно из UI-потока
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('[CallService] navigating to AudioCallPage with roomId=$roomId');

      if (roomId != null && offer != null) {
        navigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) => AudioCallPage(
              roomId:     roomId,
              isIncoming: true,
              offer:      offer,
              callId:     callId,
            ),
          ),
        );
      }
    });
  }

  Future<void> createCall({required String roomId}) async {
    final offer  = await WebRtcHelper.createOffer();
    final callId = UniqueKey().toString();

    await client.sendMessage(
      roomId,
      'm.call.invite',
      'txn_${DateTime.now().millisecondsSinceEpoch}',
      {
        'call_id':  callId,
        'version':  1,
        'party_id': MatrixService.userId ?? '',
        'offer':    offer,
      },
    );

    _pendingRoom[callId]  = roomId;
    _pendingOffer[callId] = offer;

    debugPrint('[CallService] invite: callId=$callId roomId=$roomId');

    await FlutterCallkitIncoming.showCallkitIncoming(
      CallKitParams(
        id:         callId,
        nameCaller: 'Me',
        appName:    'QalqanDSM',
        type:       0,
        textAccept: 'Отклонить',
        textDecline:'Завершить',
        extra:      {'call_id': callId},
      ),
    );
  }

  void dispose() => _sub?.cancel();
}
