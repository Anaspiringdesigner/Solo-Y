import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/biofeedback_model.dart';
import '../models/vitals_point.dart';
import 'auth_service.dart';

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

  Future<bool> _refreshAuth() async {
    return AuthService().refreshTokenIfNeeded();
  }

  Future<http.Response> _getWith401Retry(Uri uri) async {
    var resp = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: AppConstants.httpTimeoutSec));

    if (resp.statusCode == 401) {
      final ok = await _refreshAuth();
      if (ok) {
        resp = await http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: AppConstants.httpTimeoutSec));
      }
    }
    return resp;
  }

  Future<http.Response> _postWith401Retry(Uri uri, {String? body}) async {
    var resp = await http
        .post(uri, headers: _headers, body: body)
        .timeout(const Duration(seconds: AppConstants.httpTimeoutSec));

    if (resp.statusCode == 401) {
      final ok = await _refreshAuth();
      if (ok) {
        resp = await http
            .post(uri, headers: _headers, body: body)
            .timeout(const Duration(seconds: AppConstants.httpTimeoutSec));
      }
    }
    return resp;
  }

  Future<BiofeedbackStatus?> fetchStatus() async {
    try {
      final resp = await _getWith401Retry(_u('/v1/status'));

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

      final resp = await _postWith401Retry(
        _u('/v1/events/trigger'),
        body: body,
      );

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

  Future<Map<String, dynamic>?> postPointsBatch({
    required String deviceId,
    required int seqNo,
    required int schemaVersion,
    required String idempotencyKey,
    required List<VitalsPoint> points,
  }) async {
    try {
      final payload = {
        'device_id': deviceId,
        'mode': 'batch',
        'seq_no': seqNo,
        'schema_version': schemaVersion,
        'idempotency_key': idempotencyKey,
        'points': points.map((p) => p.toJson()).toList(),
      };

      final resp = await _postWith401Retry(
        _u('/v1/ingest/batch'),
        body: jsonEncode(payload),
      );

      return {
        'status': resp.statusCode,
        'json': resp.body.isNotEmpty ? jsonDecode(resp.body) : {},
      };
    } catch (e) {
      return {'status': 0, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>?> postPointsRealtime({
    required String deviceId,
    required int seqNo,
    required int schemaVersion,
    required String idempotencyKey,
    required List<VitalsPoint> points,
  }) async {
    try {
      final payload = {
        'device_id': deviceId,
        'mode': 'realtime',
        'seq_no': seqNo,
        'schema_version': schemaVersion,
        'idempotency_key': idempotencyKey,
        'points': points.map((p) => p.toJson()).toList(),
      };

      final resp = await _postWith401Retry(
        _u('/v1/ingest/realtime'),
        body: jsonEncode(payload),
      );

      return {
        'status': resp.statusCode,
        'json': resp.body.isNotEmpty ? jsonDecode(resp.body) : {},
      };
    } catch (e) {
      return {'status': 0, 'error': e.toString()};
    }
  }
}