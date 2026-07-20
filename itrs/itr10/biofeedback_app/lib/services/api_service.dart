import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/biofeedback_model.dart';

class ApiService {
  static final ApiService _instance =
      ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  // ── Fetch Status ──────────────────────────────
  Future<BiofeedbackStatus?> fetchStatus()
      async {
    try {
      debugPrint('[API] GET '
          '${AppConstants.serverBase}/status');

      final resp = await http
          .get(
            Uri.parse(
                '${AppConstants.serverBase}'
                '/status'),
            headers: {
              'Content-Type':
                  'application/json',
            },
          )
          .timeout(
              const Duration(seconds: 10));

      debugPrint('[API] Status response: '
          '${resp.statusCode}');

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body)
            as Map<String, dynamic>;
        return BiofeedbackStatus
            .fromJson(json);
      }
    } catch (e) {
      debugPrint('[API] Status error: $e');
    }
    return null;
  }

  // ── Fire Trigger ──────────────────────────────
  Future<Map<String, dynamic>?> fireTrigger({
    int triggerType = 2,
  }) async {
    try {
      final url =
          '${AppConstants.serverBase}/trigger';
      debugPrint('[API] POST $url');
      debugPrint('[API] trigger_type='
          '$triggerType');

      final resp = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type':
                  'application/json',
            },
            body: jsonEncode(
                {'trigger_type': triggerType}),
          )
          .timeout(
              const Duration(seconds: 15));

      debugPrint('[API] Trigger response: '
          '${resp.statusCode} ${resp.body}');

      if (resp.statusCode == 200) {
        return jsonDecode(resp.body)
            as Map<String, dynamic>;
      }

      return {
        'ok':    false,
        'reason': 'HTTP ${resp.statusCode}',
      };

    } catch (e) {
      debugPrint('[API] Trigger error: $e');
      return {
        'ok':    false,
        'error': e.toString(),
      };
    }
  }

  // ── Fire Calendar Trigger ─────────────────────
  Future<void> fireCalendarTrigger() async {
    await fireTrigger(triggerType: 0);
  }
}