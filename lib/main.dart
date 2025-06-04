// lib/main.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:matrix/matrix.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const QalqnCallApp());
}

/// Класс для десериализации config.json
@immutable
class AppConfig {
  final String homeserver;
  final String username;
  final String password;
  final String roomId;

  const AppConfig({
    required this.homeserver,
    required this.username,
    required this.password,
    required this.roomId,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    return AppConfig(
      homeserver: json['homeserver'] as String,
      username: json['username'] as String,
      password: json['password'] as String,
      roomId: json['room_id'] as String,
    );
  }
}

/// Считывает config.json из корня проекта (согласно pubspec.yaml)
Future<AppConfig> loadConfig() async {
  try {
    final rawJson = await rootBundle.loadString('config.json');
    final Map<String, dynamic> decodedJson = json.decode(rawJson);
    return AppConfig.fromJson(decodedJson);
  } catch (e) {
    debugPrint('Error loading config: $e');
    rethrow;
  }
}

class QalqnCallApp extends StatelessWidget {
  const QalqnCallApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QalqanDSM',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const CallPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class CallPage extends StatefulWidget {
  const CallPage({Key? key}) : super(key: key);

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  bool _isCallInProgress = false;
  String _statusText = 'Нажмите кнопку, чтобы начать звонок.';

  Client? _matrixClient;
  String? _loggedInUserId;
  String? _callId;
  String? _partyId;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  final _iceCandidatesQueue = <RTCIceCandidate>[];

  /// Обновление UI
  void _updateState({bool inProgress = false, required String status}) {
    if (mounted) {
      setState(() {
        _isCallInProgress = inProgress;
        _statusText = status;
      });
    }
  }

  @override
  void dispose() {
    // При закрытии страницы пытаемся разлогиниться и освободить ресурсы
    _matrixClient
        ?.logout()
        .catchError((e) => debugPrint('Error during logout on dispose: $e'))
        .whenComplete(() {
      _matrixClient?.dispose();
      _matrixClient = null;
    });

    _peerConnection?.close();
    _localStream?.dispose();
    super.dispose();
  }

  /// Основной метод для инициализации звонка
  Future<void> _initiateCall() async {
    _updateState(inProgress: true, status: 'Загрузка конфигурации...');

    late AppConfig config;
    try {
      config = await loadConfig();
    } catch (e) {
      _updateState(status: 'Ошибка загрузки config.json: $e', inProgress: false);
      return;
    }

    _updateState(status: 'Инициализация Matrix клиента и вход...');

    // Если уже был старый клиент, разлогиним и удалим его
    if (_matrixClient != null) {
      try {
        await _matrixClient!.logout();
      } catch (_) {}
      _matrixClient!.dispose();
      _matrixClient = null;
    }

    // Проверим и запросим разрешения на микрофон
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _updateState(
        status: 'Необходимо разрешение на доступ к микрофону.',
        inProgress: false,
      );
      return;
    }

    // 1. Создаём экземпляр Client (matrix-dart-sdk)
    final client = Client('QalqnDSMClient');
    _matrixClient = client;

    try {
      // 2. Инициализация SDK
      await client.init();

      // 3. Проверка homeserver и логин
      final homeserverUri = Uri.parse(config.homeserver);
      await client.checkHomeserver(homeserverUri);

      final loginResponse = await client.login(
        LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(user: config.username),
        password: config.password,
      );

      _loggedInUserId = loginResponse.userId;
      if (_loggedInUserId == null || _loggedInUserId!.isEmpty) {
        _updateState(
          status: 'Не удалось получить userId после входа.',
          inProgress: false,
        );
        return;
      }
      _updateState(status: 'Вход успешен: $_loggedInUserId');

      // 4. Запускаем бесконечный sync
      client.sync().catchError((e) => debugPrint('Sync failed: $e'));

      // 5. Подписываемся на события через onEvent.stream
      client.onEvent.stream.listen((EventUpdate update) {
        final raw = update.content as Map<String, dynamic>;
        final eventType = raw['type'] as String?;
        debugPrint('>>> raw["type"] = $eventType');

        if (eventType == 'm.call.answer') {
          _handleCallAnswer(raw);
        } else if (eventType == 'm.call.candidates') {
          _handleCallCandidates(raw);
        }
      });

      // 6. Проверяем, что комната существует
      final room = client.getRoomById(config.roomId);
      if (room == null) {
        _updateState(
          status: 'Комната ${config.roomId} не найдена.',
          inProgress: false,
        );
        return;
      }

      // 7. Создаём локальный медиа-поток (аудио)
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
        },
        'video': false,
      });

      // 8. Создаём RTCPeerConnection и добавляем локальный поток
      final configuration = <String, dynamic>{
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {
            'urls': 'turn:webqalqan.com:3478',
            'username': 'turnuser',
            'credential': 'turnpass',
          }
        ]
      };
      _peerConnection =
      await createPeerConnection(configuration, <String, dynamic>{});
      _localStream?.getTracks().forEach((track) {
        _peerConnection?.addTrack(track, _localStream!);
      });

      // 9. Генерация callId и partyId до создания offer
      _callId = 'call_${DateTime.now().millisecondsSinceEpoch}';
      _partyId =
      'flutter_${_loggedInUserId!.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}_${DateTime.now().millisecondsSinceEpoch}';

      // 10. Создаём SDP-предложение (offer)
      final offer = await _peerConnection!
          .createOffer(<String, dynamic>{'offerToReceiveAudio': 1});
      await _peerConnection!.setLocalDescription(offer);

      // 11. Только теперь устанавливаем onIceCandidate, чтобы callId/partyId уже были готовы
      _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate != null) {
          _sendIceCandidate(config.roomId, candidate);
        } else {
          debugPrint('ICE Gathering Complete');
        }
      };

      // 12. Формируем тело m.call.invite
      final inviteContent = <String, dynamic>{
        'call_id': _callId,
        'lifetime': 60000,
        'offer': {
          'type': 'offer',
          'sdp': offer.sdp,
        },
        'version': '1',
        'party_id': _partyId,
      };

      // 13. Отправляем m.call.invite через client.sendMessage
      final txnId = 'txn-${DateTime.now().millisecondsSinceEpoch}';
      await client.sendMessage(
        config.roomId,
        'm.call.invite',
        txnId,
        inviteContent,
      );

      _updateState(
        status: 'm.call.invite отправлен. Ожидание ответа...',
        inProgress: true,
      );
    } on MatrixException catch (e) {
      final errorMessage = e.toString();
      _updateState(
        status: 'MatrixException при логине/звонке: $errorMessage',
        inProgress: false,
      );
      debugPrint('MatrixException details: $e');
    } catch (e, st) {
      _updateState(
        status: 'Непредвиденная ошибка: $e',
        inProgress: false,
      );
      debugPrint('Generic error during login/call: $e\n$st');
    }
  }

  /// Обработка m.call.answer (содержит SDP-ответ от Element-приложения)
  Future<void> _handleCallAnswer(Map<String, dynamic> raw) async {
    try {
      final nested = raw['content'] as Map<String, dynamic>?;
      if (nested == null) return;

      final incomingCallId = nested['call_id'] as String?;
      if (incomingCallId != _callId) return; // чужой звонок отбрасываем

      final answerMap = nested['answer'] as Map<String, dynamic>?;
      if (answerMap == null) return;

      final sdp = answerMap['sdp'] as String?;
      final type = answerMap['type'] as String?;
      if (sdp == null || type == null) return;

      final remoteDesc = RTCSessionDescription(sdp, type);
      await _peerConnection?.setRemoteDescription(remoteDesc);

      // После установки remoteDescription пропускаем накопленные ICE-кандидаты
      for (final queued in _iceCandidatesQueue) {
        await _peerConnection?.addCandidate(queued);
      }
      _iceCandidatesQueue.clear();

      _updateState(
        status: 'Установлено соединение SDP. Ждём ICE.',
        inProgress: true,
      );
    } catch (e) {
      debugPrint('Error handling call answer: $e');
    }
  }

  /// Обработка m.call.candidates (содержит ICE-кандидаты от Element)
  Future<void> _handleCallCandidates(Map<String, dynamic> raw) async {
    try {
      final nested = raw['content'] as Map<String, dynamic>?;
      if (nested == null) return;

      final incomingCallId = nested['call_id'] as String?;
      if (incomingCallId != _callId) return; // чужие кандидаты отбрасываем

      final candidates = nested['candidates'] as List<dynamic>?;
      if (candidates == null) return;

      for (final it in candidates) {
        final m = it as Map<String, dynamic>;
        final cand = m['candidate'] as String?;
        final mid = m['sdpMid'] as String?;
        final mlineIndex = m['sdpMLineIndex'] as int?;
        if (cand == null || mid == null || mlineIndex == null) continue;

        final iceCandidate = RTCIceCandidate(cand, mid, mlineIndex);

        final currentRemote = await _peerConnection?.getRemoteDescription();
        if (currentRemote == null) {
          _iceCandidatesQueue.add(iceCandidate);
        } else {
          await _peerConnection?.addCandidate(iceCandidate);
        }
      }
    } catch (e) {
      debugPrint('Error handling call candidates: $e');
    }
  }

  /// Отправка ICE-кандидата в комнату через m.call.candidates
  Future<void> _sendIceCandidate(
      String roomId,
      RTCIceCandidate candidate,
      ) async {
    if (_matrixClient == null) return;
    if (_callId == null || _partyId == null) return;

    final client = _matrixClient!;

    final candidatesContent = <String, dynamic>{
      'call_id': _callId,
      'party_id': _partyId,
      'version': '1',
      'candidates': [
        {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        }
      ],
    };

    final txnId = 'txn-${DateTime.now().millisecondsSinceEpoch}';
    await client.sendMessage(
      roomId,
      'm.call.candidates',
      txnId,
      candidatesContent,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('QalqanDSM'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: cocnst EdgeInsets.symmetric(vertical: 16),
                  textStyle: const TextStyle(fontSize: 16),
                ),
                onPressed: _isCallInProgress ? null : _initiateCall,
                child: Text(
                  _isCallInProgress ? 'Выполняется...' : 'Позвонить',
                ),
              ),
              const SizedBox(height: 20),
              if (_isCallInProgress)
                const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              Text(
                _statusText,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}