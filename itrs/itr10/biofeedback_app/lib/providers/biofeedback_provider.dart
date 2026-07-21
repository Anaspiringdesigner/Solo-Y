import 'dart:async';
import 'package:flutter/material.dart';
import '../models/biofeedback_model.dart';
import '../services/api_service.dart';
import '../services/data_transfer_service.dart';
import '../constants.dart';
import '../services/mjpeg_server.dart';
import '../services/ring_ingest_service.dart';

class BiofeedbackProvider extends ChangeNotifier {
  final ApiService _api = ApiService();
  final RingIngestService _ring = RingIngestService();

  BiofeedbackStatus? status;
  bool isConnected = false;
  bool isTriggerLoading = false;
  bool isDataTransferActive = false;
  String triggerMessage = '';
  String calendarMessage = '';
  String dataTransferStatus = 'Stopped';

  final List<double> hrvHistory = [];
  final List<double> hrHistory = [];

  Timer? _statusTimer;

  void startPolling() {
    _fetchStatus();
    _statusTimer = Timer.periodic(
      const Duration(milliseconds: AppConstants.statusPollMs),
      (_) => _fetchStatus(),
    );
  }

  void stopPolling() => _statusTimer?.cancel();

  Future<void> startDataTransfer() async {
    await DataTransferService.start();
    isDataTransferActive = true;
    dataTransferStatus = 'Running';
    notifyListeners();
  }

  Future<void> stopDataTransfer() async {
    await DataTransferService.stop();
    isDataTransferActive = false;
    dataTransferStatus = 'Stopped';
    notifyListeners();
  }

  Future<void> checkDataTransferStatus() async {
    final running = await DataTransferService.isRunning();
    isDataTransferActive = running;
    dataTransferStatus = running ? 'Running' : 'Stopped';
    notifyListeners();
  }

  Future<void> startRingBatchSync() async {
    _ring.configure(deviceId: 'ringA', schemaVersion: '1');
    _ring.startBatchSync(interval: const Duration(seconds: 30));
  }

  Future<void> startRingRealtime() async {
    _ring.startRealtime(interval: const Duration(seconds: 2));
  }

  Future<void> stopRingRealtime() async {
    _ring.stopRealtime();
  }

  Future<void> _fetchStatus() async {
    final result = await _api.fetchStatus();
    if (result != null) {
      final prevInteraction = status?.activeInteraction ?? -1;
      final newInteraction = result.activeInteraction;

      status = result;
      isConnected = true;

      if (newInteraction == 3 && prevInteraction != 3) {
        _startCamera();
      } else if (newInteraction != 3 && prevInteraction == 3) {
        _stopCamera();
      }

      hrvHistory.add(result.avgHrv);
      hrHistory.add(result.avgHr);
      if (hrvHistory.length > 60) hrvHistory.removeAt(0);
      if (hrHistory.length > 60) hrHistory.removeAt(0);
    } else {
      isConnected = false;
    }
    notifyListeners();
  }

  Future<void> _startCamera() async {
    final server = MjpegServer();
    if (!server.isRunning) {
      await server.initCamera();
      await server.startServer();
    }
    if (!server.isStreaming) {
      await server.startStreaming();
    }
  }

  Future<void> _stopCamera() async {
    final server = MjpegServer();
    if (server.isStreaming) {
      await server.stopStreaming();
    }
  }

  Future<void> fireManualTrigger() async {
    isTriggerLoading = true;
    triggerMessage = '';
    notifyListeners();

    final result = await _api.fireTrigger(
      triggerType: 'manual',
      streamDurationSec: AppConstants.triggerStreamDurationSec,
    );

    isTriggerLoading = false;

    if (result != null && result['ok'] == true) {
      triggerMessage = '✅ Trigger fired (${result['state'] ?? 'EVENT_STREAMING'})';

      await startRingRealtime();
      Future.delayed(
        const Duration(seconds: AppConstants.triggerStreamDurationSec),
        () => stopRingRealtime(),
      );
    } else {
      final reason = result?['error'] ?? result?['reason'] ?? 'Unknown error';
      triggerMessage = '⚠️ $reason';
    }

    notifyListeners();

    Future.delayed(const Duration(seconds: 5), () {
      triggerMessage = '';
      notifyListeners();
    });
  }

  Future<void> fireCalendarTrigger(String eventName) async {
    await _api.fireTrigger(triggerType: 'calendar');
    calendarMessage = '📅 $eventName — trigger sent';
    notifyListeners();

    Future.delayed(const Duration(seconds: 5), () {
      calendarMessage = '';
      notifyListeners();
    });
  }

  @override
  void dispose() {
    stopPolling();
    _ring.stopBatchSync();
    _ring.stopRealtime();
    super.dispose();
  }
}