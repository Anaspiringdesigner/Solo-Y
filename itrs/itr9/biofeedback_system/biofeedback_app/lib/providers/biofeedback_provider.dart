import 'dart:async';
import 'package:flutter/material.dart';
import '../models/biofeedback_model.dart';
import '../services/api_service.dart';
import '../services/data_transfer_service.dart';
import '../constants.dart';

class BiofeedbackProvider
    extends ChangeNotifier {
  final ApiService _api = ApiService();

  // ── State ─────────────────────────────────────
  BiofeedbackStatus? status;
  bool   isConnected          = false;
  bool   isTriggerLoading     = false;
  bool   isDataTransferActive = false;
  String triggerMessage       = '';
  String calendarMessage      = '';
  String dataTransferStatus   = 'Stopped';

  final List<double> hrvHistory = [];
  final List<double> hrHistory  = [];

  Timer? _statusTimer;

  // ── Start Polling ─────────────────────────────
  void startPolling() {
    _statusTimer = Timer.periodic(
      const Duration(
          milliseconds:
              AppConstants.statusPollMs),
      (_) => _fetchStatus(),
    );
    _fetchStatus();
  }

  void stopPolling() {
    _statusTimer?.cancel();
  }

  // ── Data Transfer ─────────────────────────────
  Future<void> startDataTransfer() async {
    await DataTransferService.start();
    isDataTransferActive = true;
    dataTransferStatus   = 'Running';
    notifyListeners();
  }

  Future<void> stopDataTransfer() async {
    await DataTransferService.stop();
    isDataTransferActive = false;
    dataTransferStatus   = 'Stopped';
    notifyListeners();
  }

  Future<void> checkDataTransferStatus()
      async {
    final running =
        await DataTransferService.isRunning();
    isDataTransferActive = running;
    dataTransferStatus   =
        running ? 'Running' : 'Stopped';
    notifyListeners();
  }

  // ── Fetch Status ──────────────────────────────
  Future<void> _fetchStatus() async {
    final result = await _api.fetchStatus();
    if (result != null) {
      status      = result;
      isConnected = true;

      hrvHistory.add(result.avgHrv);
      hrHistory.add(result.avgHr);
      if (hrvHistory.length > 60) {
        hrvHistory.removeAt(0);
      }
      if (hrHistory.length > 60) {
        hrHistory.removeAt(0);
      }
    } else {
      isConnected = false;
    }
    notifyListeners();
  }

  // ── Manual Trigger ────────────────────────────
  Future<void> fireManualTrigger() async {
    isTriggerLoading = true;
    triggerMessage   = '';
    notifyListeners();

    debugPrint('[PROVIDER] Firing trigger '
        'to ${AppConstants.serverBase}');

    final result =
        await _api.fireTrigger(
            triggerType: 2);

    isTriggerLoading = false;

    if (result != null &&
        result['ok'] == true) {
      triggerMessage =
          '✅ ${result['name']} selected';
    } else if (result != null) {
      final reason =
          result['reason'] ??
          result['error']  ??
          'Unknown error';
      triggerMessage = '⚠️ $reason';
      debugPrint('[PROVIDER] Trigger failed: '
          '$reason');
    } else {
      triggerMessage =
          '❌ No response from server\n'
          '${AppConstants.serverBase}';
      debugPrint('[PROVIDER] No response '
          'from ${AppConstants.serverBase}');
    }

    notifyListeners();

    Future.delayed(
        const Duration(seconds: 5), () {
      triggerMessage = '';
      notifyListeners();
    });
  }

  // ── Calendar Trigger ──────────────────────────
  Future<void> fireCalendarTrigger(
      String eventName) async {
    await _api.fireCalendarTrigger();
    calendarMessage =
        '📅 $eventName — '
        'interaction selected';
    notifyListeners();

    Future.delayed(
        const Duration(seconds: 5), () {
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