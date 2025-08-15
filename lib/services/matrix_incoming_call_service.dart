import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:qalqan_dsm/services/auth_data.dart';
import '../main.dart' show navigatorKey;
import 'package:flutter/material.dart';
import '../ui/incoming_audio_call_page.dart';

class MatrixCallService {
  final Client client;
  final String currentUserId;
  StreamSubscription<Event>? _subInvite;
  StreamSubscription<Event>? _subHangup;

  final Map<String, String> _pendingRooms = {};
  final Map<String, Map<String, dynamic>> _pendingOffers = {};
  final Map<String, String> _pendingCallerNames = {};

  MatrixCallService(this.client, this.currentUserId);

  void start() {
    client.backgroundSync = true;
    client.sync();
    _subInvite = client.onTimelineEvent.stream
        .where((e) => e.type == 'm.call.invite')
        .listen(_onInvite);

    _subHangup = client.onTimelineEvent.stream
        .where((e) => e.type == 'm.call.hangup')
        .listen(_onHangup, onError: (e) => debugPrint('Hangup err: $e'));
  }

  Future<void> _onHangup(Event e) async {
    final content = e.content as Map<String, dynamic>?;
    final callId = content?['call_id'] as String?;
    if (callId == null) return;

    await FlutterCallkitIncoming.endCall(callId);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigatorKey.currentState?.maybePop();
    });
  }

  Future<void> _onInvite(Event e) async {
    final content = e.content as Map<String, dynamic>?;
    if (content == null) return;

    final callId = content['call_id'] as String?;
    if (callId == null) return;

    if (AuthDataCall.instance.outgoingCallIds.remove(callId)) {
      return;
    }

    final offer = content['offer'] as Map<String, dynamic>?;
    if (offer == null) return;

    final displayName = _extractLocalpart((e.sender as User).id);

    _pendingRooms[callId] = e.room.id;
    _pendingOffers[callId] = offer;
    _pendingCallerNames[callId] = displayName;

    await FlutterCallkitIncoming.showCallkitIncoming(
      CallKitParams(
        id: callId,
        nameCaller: displayName,
        appName: 'QalqanDSM',
        type: 0,
        textAccept: 'Accept',
        textDecline: 'Decline',
        extra: {'call_id': callId},
      ),
    );
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
  }

  String _extractLocalpart(String senderId) {
    var userAndDomain = senderId.split(':').first;
    if (userAndDomain.startsWith('@')) {
      userAndDomain = userAndDomain.substring(1);
    }
    return userAndDomain;
  }
}