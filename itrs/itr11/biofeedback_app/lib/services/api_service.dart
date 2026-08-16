import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/biofeedback_model.dart';
import '../models/dashboard_model.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  Future<BiofeedbackStatus?> fetchStatus() async {
    try {
      final resp = await http
          .get(
            Uri.parse('${AppConstants.serverBase}/status'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        return BiofeedbackStatus.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
      }
    } catch (e) {
      debugPrint('[API] Status error: $e');
    }
    return null;
  }

  Future<List<DashboardOption>> fetchDashboards() async {
    try {
      final resp = await http
          .get(
            Uri.parse('${AppConstants.serverBase}/dashboards'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        final list = (json['dashboards'] ?? []) as List;
        return list
            .map((e) => DashboardOption.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('[API] Fetch dashboards error: $e');
    }
    return [];
  }

  Future<Map<String, dynamic>?> createDashboard({
    required String instruction,
    String? title,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse('${AppConstants.serverBase}/dashboards'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'instruction': instruction,
              if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
            }),
          )
          .timeout(const Duration(seconds: 15));

      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[API] Create dashboard error: $e');
      return {'ok': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>?> confirmAction({
    required int executedDashboardId,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse('${AppConstants.serverBase}/confirm_action'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'executed_dashboard_id': executedDashboardId}),
          )
          .timeout(const Duration(seconds: 15));

      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[API] Confirm action error: $e');
      return {'ok': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>?> fireTrigger({int triggerType = 2}) async {
    try {
      final resp = await http
          .post(
            Uri.parse('${AppConstants.serverBase}/trigger'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'trigger_type': triggerType}),
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
      return {'ok': false, 'reason': 'HTTP ${resp.statusCode}'};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  Future<void> fireCalendarTrigger() async {
    await fireTrigger(triggerType: 0);
  }
}