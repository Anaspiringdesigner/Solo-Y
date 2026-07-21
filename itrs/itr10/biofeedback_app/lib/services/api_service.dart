import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/biofeedback_model.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-Gateway-Secret': AppConstants.gatewaySecret,
        'X-Verified-User-Id': AppConstants.verifiedUserId,
        'X-Auth-Issuer': AppConstants.authIssuer,
      };

  Uri _u(String path) => Uri.parse('${AppConstants.apiBaseUrl}$path');

  Future<BiofeedbackStatus?> fetchStatus() async {
    try {
      final resp = await http
          .get(_u('/v1/status'), headers: _headers)
          .timeout(const Duration(seconds: AppConstants.httpTimeoutSec));

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        return BiofeedbackStatus.fromJson(json);
      }

      debugPrint('[API] status failed: ${resp.statusCode} ${resp.body}');
    } catch (e) {
      debugPrint('[API] status error: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>?> fireTrigger({
    String triggerType = 'manual',
    int streamDurationSec = AppConstants.triggerStreamDurationSec,
  }) async {
    try {
      final body = jsonEncode({
        'trigger_type': triggerType,
        'stream_duration_sec': streamDurationSec,
      });

      final resp = await http
          .post(_u('/v1/events/trigger'), headers: _headers, body: body)
          .timeout(const Duration(seconds: AppConstants.httpTimeoutSec));

      final parsed = resp.body.isNotEmpty
          ? jsonDecode(resp.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (resp.statusCode == 200) return parsed;

      return {
        'ok': false,
        'error': 'HTTP ${resp.statusCode}',
        'body': parsed,
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // For ring periodic sync
  Future<Map<String, dynamic>?> postBatch(Map<String, dynamic> payload) async {
    try {
      final resp = await http
          .post(_u('/v1/ingest/batch'),
              headers: _headers, body: jsonEncode(payload))
          .timeout(const Duration(seconds: AppConstants.httpTimeoutSec));

      return {
        'status': resp.statusCode,
        'json': resp.body.isNotEmpty ? jsonDecode(resp.body) : {},
      };
    } catch (e) {
      return {'status': 0, 'error': e.toString()};
    }
  }

  // For event-time continuous streaming
  Future<Map<String, dynamic>?> postRealtime(
      Map<String, dynamic> payload) async {
    try {
      final resp = await http
          .post(_u('/v1/ingest/realtime'),
              headers: _headers, body: jsonEncode(payload))
          .timeout(const Duration(seconds: AppConstants.httpTimeoutSec));

      return {
        'status': resp.statusCode,
        'json': resp.body.isNotEmpty ? jsonDecode(resp.body) : {},
      };
    } catch (e) {
      return {'status': 0, 'error': e.toString()};
    }
  }
}