import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
      'Accept': 'application/json',
    };
    if (_bearerToken != null && _bearerToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_bearerToken';
    }
    return headers;
  }

  Uri _u(String path) {
    final base = AppConstants.apiBaseUrl.trim();
    final p = path.startsWith('/') ? path : '/$path';
    final full = '$base$p';
    if (kDebugMode) {
      debugPrint('[API] URL => $full');
    }
    return Uri.parse(full);
  }

  Future<bool> _refreshAuth() async {
    try {
      return await AuthService().refreshTokenIfNeeded();
    } catch (e) {
      if (kDebugMode) debugPrint('[API] refresh auth failed: $e');
      return false;
    }
  }

  bool _isTransientNetworkError(Object e) {
    return e is SocketException || e is TimeoutException || e is HttpException;
  }

  Future<http.Response> _sendWithRetry(
    Future<http.Response> Function() request, {
    bool allowAuthRefresh = true,
    int networkRetries = 1,
  }) async {
    int attempt = 0;
    while (true) {
      attempt++;
      try {
        var resp = await request();

        if (allowAuthRefresh && resp.statusCode == 401) {
          final ok = await _refreshAuth();
          if (ok) {
            resp = await request();
          }
        }
        return resp;
      } catch (e) {
        if (attempt <= networkRetries && _isTransientNetworkError(e)) {
          if (kDebugMode) {
            debugPrint('[API] transient error, retrying attempt=$attempt err=$e');
          }
          await Future.delayed(const Duration(milliseconds: 250));
          continue;
        }
        rethrow;
      }
    }
  }

  Future<Map<String, dynamic>> pingHealth() async {
    final uri = _u('/healthz');
    try {
      final resp = await _sendWithRetry(
        () => http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 6)),
        allowAuthRefresh: false,
        networkRetries: 1,
      );

      final body = resp.body.isNotEmpty
          ? (jsonDecode(resp.body) as Map<String, dynamic>)
          : <String, dynamic>{};

      return {
        'ok': resp.statusCode == 200,
        'status': resp.statusCode,
        'body': body,
      };
    } on TimeoutException {
      return {
        'ok': false,
        'status': 0,
        'error': 'health_timeout',
      };
    } on SocketException catch (e) {
      return {
        'ok': false,
        'status': 0,
        'error': 'health_socket',
        'detail': e.message,
      };
    } catch (e) {
      return {
        'ok': false,
        'status': 0,
        'error': 'health_unknown',
        'detail': e.toString(),
      };
    }
  }

  Future<BiofeedbackStatus?> fetchStatus() async {
    final uri = _u('/v1/status');
    try {
      final resp = await _sendWithRetry(
        () => http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: AppConstants.httpTimeoutSec)),
        allowAuthRefresh: true,
        networkRetries: 1,
      );

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        return BiofeedbackStatus.fromJson(json);
      }

      if (kDebugMode) {
        debugPrint('[API] status failed: ${resp.statusCode} ${resp.body}');
      }
      return null;
    } on TimeoutException {
      if (kDebugMode) debugPrint('[API] status timeout');
      return null;
    } on SocketException catch (e) {
      if (kDebugMode) debugPrint('[API] status socket: ${e.message}');
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[API] status error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> fireTrigger({
    String triggerType = 'manual',
    int streamDurationSec = AppConstants.triggerStreamDurationSec,
  }) async {
    // Production guard: preflight health to avoid long user-facing hangs
    final health = await pingHealth();
    if (health['ok'] != true) {
      return {
        'ok': false,
        'error': 'backend_unreachable',
        'detail': health,
      };
    }

    final uri = _u('/v1/events/trigger');
    final body = jsonEncode({
      'trigger_type': triggerType,
      'stream_duration_sec': streamDurationSec,
    });

    try {
      final resp = await _sendWithRetry(
        () => http
            .post(uri, headers: _headers, body: body)
            .timeout(const Duration(seconds: 8)),
        allowAuthRefresh: true,
        networkRetries: 1,
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
    } on TimeoutException {
      return {
        'ok': false,
        'error': 'trigger_timeout',
      };
    } on SocketException catch (e) {
      return {
        'ok': false,
        'error': 'trigger_socket',
        'detail': e.message,
      };
    } catch (e) {
      return {
        'ok': false,
        'error': 'trigger_unknown',
        'detail': e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>?> postPointsBatch({
    required String deviceId,
    required int seqNo,
    required int schemaVersion,
    required String idempotencyKey,
    required List<VitalsPoint> points,
  }) async {
    final uri = _u('/v1/ingest/batch');
    final payload = {
      'device_id': deviceId,
      'mode': 'batch',
      'seq_no': seqNo,
      'schema_version': schemaVersion,
      'idempotency_key': idempotencyKey,
      'points': points.map((p) => p.toJson()).toList(),
    };

    try {
      final resp = await _sendWithRetry(
        () => http
            .post(uri, headers: _headers, body: jsonEncode(payload))
            .timeout(const Duration(seconds: AppConstants.httpTimeoutSec)),
        allowAuthRefresh: true,
        networkRetries: 1,
      );

      return {
        'status': resp.statusCode,
        'json': resp.body.isNotEmpty ? jsonDecode(resp.body) : {},
      };
    } on TimeoutException {
      return {'status': 0, 'error': 'batch_timeout'};
    } on SocketException catch (e) {
      return {'status': 0, 'error': 'batch_socket', 'detail': e.message};
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
    final uri = _u('/v1/ingest/realtime');
    final payload = {
      'device_id': deviceId,
      'mode': 'realtime',
      'seq_no': seqNo,
      'schema_version': schemaVersion,
      'idempotency_key': idempotencyKey,
      'points': points.map((p) => p.toJson()).toList(),
    };

    try {
      final resp = await _sendWithRetry(
        () => http
            .post(uri, headers: _headers, body: jsonEncode(payload))
            .timeout(const Duration(seconds: AppConstants.httpTimeoutSec)),
        allowAuthRefresh: true,
        networkRetries: 1,
      );

      return {
        'status': resp.statusCode,
        'json': resp.body.isNotEmpty ? jsonDecode(resp.body) : {},
      };
    } on TimeoutException {
      return {'status': 0, 'error': 'realtime_timeout'};
    } on SocketException catch (e) {
      return {'status': 0, 'error': 'realtime_socket', 'detail': e.message};
    } catch (e) {
      return {'status': 0, 'error': e.toString()};
    }
  }
}