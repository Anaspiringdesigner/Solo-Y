import 'dart:async';
import 'package:flutter/material.dart';
import '../models/biofeedback_model.dart';
import '../services/api_service.dart';
import '../services/data_transfer_service.dart';
import '../constants.dart';
import '../services/mjpeg_server.dart';

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
    // Immediate first fetch
    _fetchStatus();

    _statusTimer = Timer.periodic(
      const Duration(
          milliseconds:
              AppConstants.statusPollMs),
      (_) => _fetchStatus(),
    );
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
      final prevInteraction =
          status?.activeInteraction ?? -1;
      final newInteraction =
          result.activeInteraction;

      status      = result;
      isConnected = true;

      // ── Auto camera control ─────────────
      if (newInteraction == 3 &&
          prevInteraction != 3) {
        // Switched TO Video Ripples
        debugPrint('[APP] Interaction 3 '
            'active — starting camera');
        _startCamera();
      } else if (newInteraction != 3 &&
                 prevInteraction == 3) {
        // Switched AWAY from Video Ripples
        debugPrint('[APP] Left interaction 3 '
            '— stopping camera');
        _stopCamera();
      }

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

  // ── Camera Control ──────────────────────────
  Future<void> _startCamera() async {
    final server = MjpegServer();
    if (!server.isRunning) {
      await server.initCamera();
      await server.startServer();
    }
    if (!server.isStreaming) {
      await server.startStreaming();
      debugPrint('[APP] Camera streaming → '
          '${server.streamUrl}');
    }
  }

  Future<void> _stopCamera() async {
    final server = MjpegServer();
    if (server.isStreaming) {
      await server.stopStreaming();
      debugPrint('[APP] Camera stopped');
    }
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