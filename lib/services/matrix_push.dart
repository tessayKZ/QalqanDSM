import 'dart:convert';
import 'package:http/http.dart' as http;
import 'matrix_auth.dart';

class MatrixPush {
  static Future<void> registerPusher({
    required String fcmToken,
    required String deviceDisplayName,
  }) async {
    final uri = Uri.parse('https://webqalqan.com/_matrix/client/v3/pushers/set');

    final body = {
      'kind': 'http',
      'app_id': 'com.mycompany.qalqan_dsm',
      'pushkey': fcmToken,
      'app_display_name': 'QalqanDSM',
      'device_display_name': deviceDisplayName,
      'lang': 'en',
      'data': {
        'url': 'https://webqalqan.com/_matrix/push/v1/notify',
      }
    };

    await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer ${AuthService.accessToken}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
  }
}