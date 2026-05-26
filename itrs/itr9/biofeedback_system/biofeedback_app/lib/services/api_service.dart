// lib/services/api_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/biofeedback_model.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  // ── Fetch Status ─────────────────────────────────────────
  Future<BiofeedbackStatus?> fetchStatus() async {
    try {
      final resp = await http
          .get(Uri.parse('${AppConstants.serverBase}/status'))
          .timeout(const Duration(seconds: 3));

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        return BiofeedbackStatus.fromJson(json);
      }
    } catch (e) {
      // Server not reachable
    }
    return null;
  }

  // ── Fire Manual Trigger ──────────────────────────────────
  Future<Map<String, dynamic>?> fireTrigger({
    int triggerType = 2,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse('${AppConstants.serverBase}/trigger'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'trigger_type': triggerType}),
          )
          .timeout(const Duration(seconds: 5));

      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
    return null;
  }

  // ── Fire Calendar Trigger ────────────────────────────────
  Future<void> fireCalendarTrigger() async {
    await fireTrigger(triggerType: 0);
  }
}