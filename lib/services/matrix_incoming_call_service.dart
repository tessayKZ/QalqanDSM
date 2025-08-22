import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:qalqan_dsm/services/auth_data.dart';
import '../main.dart' show navigatorKey;
import '../ui/incoming_audio_call_page.dart';
import 'package:qalqan_dsm/services/call_store.dart';
import 'package:uuid/uuid.dart';

class MatrixCallService {

  MatrixCallService._(this.client, this.currentUserId);
  static MatrixCallService? _instance;

  static MatrixCallService init(Client client, String userId) {
    _instance?.dispose();
    _instance = MatrixCallService._(client, userId)..start();
    return _instance!;
  }

  static MatrixCallService get I {
    if (_instance == null) {
      throw StateError('MatrixCallService is not initialized. Call init() after login.');
    }
    return _instance!;
  }


  final Client client;
  final String currentUserId;

  StreamSubscription<Event>? _subInvite;
  StreamSubscription<Event>? _subHangup;

  final Map<String, String> _pendingRooms = {};
  final Map<String, Map<String, dynamic>> _pendingOffers = {};
  final Map<String, String> _pendingCallerNames = {};

  final Set<String> _handledCallIds = <String>{};

  void start() {
    _subInvite?.cancel();
    _subHangup?.cancel();

    _subInvite = client.onTimelineEvent.stream
        .where((e) => e.type == 'm.call.invite')
        .listen(_onInvite, onError: (e, st) {
      debugPrint('Invite err: $e\n$st');
    });

    _subHangup = client.onTimelineEvent.stream
        .where((e) => e.type == 'm.call.hangup')
        .listen(_onHangup, onError: (e, st) {
      debugPrint('Hangup err: $e\n$st');
    });

    debugPrint('MatrixCallService: listeners attached');
  }

  Future<void> _onHangup(Event e) async {
    final content = e.content as Map<String, dynamic>?;
    final callId = content?['call_id'] as String?;
    if (callId == null || callId.isEmpty) return;

    final uuid = await CallStore.uuidForCallId(callId) ?? callId;
    try {
      await FlutterCallkitIncoming.endCall(uuid);
    } catch (err, st) {
      debugPrint('CallKit end error: $err\n$st');
    }
    await CallStore.unmapCallId(callId);
    await CallStore.clear(callId);

    _handledCallIds.add(callId);
    _pendingRooms.remove(callId);
    _pendingOffers.remove(callId);
    _pendingCallerNames.remove(callId);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigatorKey.currentState?.maybePop();
    });
  }

  Future<void> _onInvite(Event e) async {
    final content = e.content as Map<String, dynamic>?;
    if (content == null) return;

    final callId = (content['call_id'] as String?)?.trim();
    if (callId == null || callId.isEmpty) return;

    if (AuthDataCall.instance.outgoingCallIds.remove(callId)) return;
    if (await CallStore.isOutgoing(callId)) return;
    if (await CallStore.alreadyShown(callId)) return;
    if (!_handledCallIds.add(callId)) return;

    final offer = content['offer'] as Map<String, dynamic>?;
    if (offer == null) return;

    String senderId = '';
    try { senderId = e.senderId ?? (e.sender as User?)?.id ?? ''; } catch (_) {}
    if (senderId.isEmpty) senderId = 'unknown@server';

    final displayName = _extractLocalpart(senderId);
    final roomId = e.room.id;

    _pendingRooms[callId] = roomId;
    _pendingOffers[callId] = offer;
    _pendingCallerNames[callId] = displayName;

    try {
      final uuid = const Uuid().v4();
      await CallStore.mapCallIdToUuid(callId, uuid);

      final active = await FlutterCallkitIncoming.activeCalls();
      if (active.any((c) => c['id'] == uuid)) return;

      await FlutterCallkitIncoming.showCallkitIncoming(
        CallKitParams(
          id: uuid,
          nameCaller: displayName,
          appName: 'QalqanDSM',
          type: 0,
          textAccept: 'Accept',
          textDecline: 'Decline',
          extra: {'call_id': callId, 'room_id': roomId, 'sender': senderId},
        ),
      );

      await CallStore.markShown(callId);
    } catch (err, st) {
      debugPrint('CallKit show error: $err\n$st');
    }
  }

  void handleCallkitAccept(String callId) {
    final roomId = _pendingRooms.remove(callId);
    final offer = _pendingOffers.remove(callId);
    final callerName = _pendingCallerNames.remove(callId) ?? 'Unknown';
    if (roomId == null || offer == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => AudioCallPage(
            roomId: roomId,
            isIncoming: true,
            callId: callId,
            offer: offer,
            callerName: callerName,
          ),
        ),
      );
    });
  }

  void dispose() {
    _subInvite?.cancel();
    _subHangup?.cancel();
    _subInvite = null;
    _subHangup = null;
  }

  String _extractLocalpart(String senderId) {
    var userAndDomain = senderId.split(':').first;
    if (userAndDomain.startsWith('@')) {
      userAndDomain = userAndDomain.substring(1);
    }
    return userAndDomain;
  }
}