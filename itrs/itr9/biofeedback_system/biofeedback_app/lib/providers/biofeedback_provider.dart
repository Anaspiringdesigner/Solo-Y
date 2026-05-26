// lib/providers/biofeedback_provider.dart

import 'dart:async';
import 'package:flutter/material.dart';
import '../models/biofeedback_model.dart';
import '../services/api_service.dart';
import '../constants.dart';

class BiofeedbackProvider extends ChangeNotifier {
  final ApiService _api = ApiService();

  // ── State ─────────────────────────────────────────────────
  BiofeedbackStatus? status;
  bool   isConnected      = false;
  bool   isTriggerLoading = false;
  String triggerMessage   = '';
  String calendarMessage  = '';

  // History for chart (last 60 readings)
  final List<double> hrvHistory = [];
  final List<double> hrHistory  = [];

  Timer? _statusTimer;

  // ── Start Polling ─────────────────────────────────────────
  void startPolling() {
    _statusTimer = Timer.periodic(
      Const Duration(milliseconds: AppConstants.statusPollMs),
      (_) => _fetchStatus(),
    );
    _fetchStatus();
  }

  void stopPolling() {
    _statusTimer?.cancel();
  }

  // ── Fetch Status ──────────────────────────────────────────
  Future<void> _fetchStatus() async {
    final result = await _api.fetchStatus();
    if (result != null) {
      status      = result;
      isConnected = true;

      hrvHistory.add(result.avgHrv);
      hrHistory.add(result.avgHr);
      if (hrvHistory.length > 60) hrvHistory.removeAt(0);
      if (hrHistory.length  > 60) hrHistory.removeAt(0);
    } else {
      isConnected = false;
    }
    notifyListeners();
  }

  // ── Manual Trigger ────────────────────────────────────────
  Future<void> fireManualTrigger() async {
    isTriggerLoading = true;
    triggerMessage   = '';
    notifyListeners();

    final result = await _api.fireTrigger(triggerType: 2);

    isTriggerLoading = false;

    if (result != null && result['ok'] == true) {
      triggerMessage = '✅ ${result['name']} selected';
    } else if (result != null && result['ok'] == false) {
      triggerMessage = result['reason'] ?? '⚠️ Could not trigger';
    } else {
      triggerMessage = '❌ Server not reachable';
    }

    notifyListeners();

    // Clear message after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      triggerMessage = '';
      notifyListeners();
    });
  }

  // ── Calendar Trigger ──────────────────────────────────────
  Future<void> fireCalendarTrigger(String eventName) async {
    await _api.fireCalendarTrigger();
    calendarMessage = '📅 $eventName — interaction selected';
    notifyListeners();

    Future.delayed(const Duration(seconds: 5), () {
      calendarMessage = '';
      notifyListeners();
    });
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}