import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:qalqan_dsm/services/auth_data.dart';
import '../main.dart';
import 'package:flutter/material.dart';
import '../ui/incoming_audio_call_page.dart';

class MatrixCallService {
  final Client client;
  final String currentUserId;
  StreamSubscription<Event>? _sub;

  final Map<String, String> _pendingRooms = {};
  final Map<String, Map<String, dynamic>> _pendingOffers = {};

  MatrixCallService(this.client, this.currentUserId);

  void start() {
    client.backgroundSync = true;
    client.sync();
    _sub = client.onTimelineEvent.stream
        .where((e) => e.type == 'm.call.invite')
        .listen(_onInvite, onError: (e) => debugPrint('CallService err: $e'));
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

    _pendingRooms[callId] = e.room.id;
    _pendingOffers[callId] = offer;

    final displayName = _extractLocalpart((e.sender as User).id);

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
    if (roomId == null || offer == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => AudioCallPage(
            roomId: roomId,
            isIncoming: true,
            callId: callId,
            offer: offer,
          ),
        ),
      );
    });
  }

  void dispose() {
    _sub?.cancel();
  }

  String _extractLocalpart(String senderId) {
    var userAndDomain = senderId.split(':').first;
    if (userAndDomain.startsWith('@')) {
      userAndDomain = userAndDomain.substring(1);
    }
    return userAndDomain;
  }
}