import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/biofeedback_model.dart';
import '../models/vitals_point.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  String? _bearerToken;

  void setBearerToken(String? token) {
    _bearerToken = token;
  }

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };

    if (_bearerToken != null && _bearerToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_bearerToken';
    }

    return headers;
  }

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

  Future<Map<String, dynamic>?> postPointsRealtime({
    required String deviceId,
    required int seqNo,
    required String idempotencyKey,
    required List<VitalsPoint> points,
  }) async {
    try {
      final body = jsonEncode({
        'device_id': deviceId,
        'mode': 'realtime',
        'seq_no': seqNo,
        'schema_version': 1,
        'idempotency_key': idempotencyKey,
        'points': points.map((p) => p.toJson()).toList(),
      });

      final resp = await http
          .post(_u('/v1/ingest/realtime'), headers: _headers, body: body)
          .timeout(const Duration(seconds: AppConstants.httpTimeoutSec));

      return {
        'status': resp.statusCode,
        'json': resp.body.isNotEmpty ? jsonDecode(resp.body) : {},
      };
    } catch (e) {
      return {'status': 0, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>?> postPointsBatch({
    required String deviceId,
    required int seqNo,
    required String idempotencyKey,
    required List<VitalsPoint> points,
  }) async {
    try {
      final body = jsonEncode({
        'device_id': deviceId,
        'mode': 'batch',
        'seq_no': seqNo,
        'schema_version': 1,
        'idempotency_key': idempotencyKey,
        'points': points.map((p) => p.toJson()).toList(),
      });

      final resp = await http
          .post(_u('/v1/ingest/batch'), headers: _headers, body: body)
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