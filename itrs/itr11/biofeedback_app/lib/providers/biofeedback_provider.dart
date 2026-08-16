import 'dart:async';
import 'package:flutter/material.dart';
import '../models/biofeedback_model.dart';
import '../models/dashboard_model.dart';
import '../services/api_service.dart';
import '../services/data_transfer_service.dart';
import '../constants.dart';
import '../services/mjpeg_server.dart';

class BiofeedbackProvider extends ChangeNotifier {
  final ApiService _api = ApiService();

  BiofeedbackStatus? status;
  bool isConnected = false;
  bool isTriggerLoading = false;
  bool isDataTransferActive = false;
  String triggerMessage = '';
  String calendarMessage = '';
  String dataTransferStatus = 'Stopped';

  final List<double> hrvHistory = [];
  final List<double> hrHistory = [];
  final List<DashboardOption> dashboards = [];

  bool isDashboardLoading = false;
  bool dashboardDialogOpen = false;
  int? selectedDashboardId;
  DateTime? dashboardDeadline;

  Timer? _statusTimer;

  void startPolling() {
    _fetchStatus();
    _statusTimer = Timer.periodic(
      const Duration(milliseconds: AppConstants.statusPollMs),
      (_) => _fetchStatus(),
    );
  }

  void stopPolling() {
    _statusTimer?.cancel();
  }

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

  Future<void> refreshDashboards() async {
    isDashboardLoading = true;
    notifyListeners();
    final items = await _api.fetchDashboards();
    dashboards
      ..clear()
      ..addAll(items.where((d) => d.active));
    isDashboardLoading = false;
    notifyListeners();
  }

  Future<Map<String, dynamic>?> createCustomDashboard(String instruction) async {
    final result = await _api.createDashboard(instruction: instruction);
    await refreshDashboards();
    return result;
  }

  Future<Map<String, dynamic>?> confirmExecutedDashboard(int dashboardId) async {
    final result = await _api.confirmAction(executedDashboardId: dashboardId);
    if (result != null && result['ok'] == true) {
      selectedDashboardId = dashboardId;
      dashboardDialogOpen = false;
    }
    await _fetchStatus();
    return result;
  }

  Future<void> _fetchStatus() async {
    final result = await _api.fetchStatus();
    if (result != null) {
      final prevInteraction = status?.activeInteraction ?? -1;
      final newInteraction = result.activeInteraction;
      final prevPending = status?.hasPendingIntervention ?? false;

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

      if (result.hasPendingIntervention && !prevPending) {
        await refreshDashboards();
        selectedDashboardId = result.proposedDashboardId;
        dashboardDeadline = DateTime.now().add(const Duration(minutes: 1));
      }
    } else {
      isConnected = false;
    }
    notifyListeners();
  }

  Duration get dashboardTimeRemaining {
    if (dashboardDeadline == null) return Duration.zero;
    final d = dashboardDeadline!.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  double get dashboardTimerProgress {
    if (dashboardDeadline == null) return 0.0;
    const total = 60;
    final left = dashboardTimeRemaining.inSeconds.clamp(0, total);
    return 1.0 - (left / total);
  }

  String get dashboardTimerLabel {
    final left = dashboardTimeRemaining.inSeconds;
    final m = left ~/ 60;
    final s = left % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
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

    final result = await _api.fireTrigger(triggerType: 2);
    isTriggerLoading = false;

    if (result != null && result['ok'] == true) {
      triggerMessage = '✅ ${result['name']} selected';
    } else if (result != null) {
      final reason = result['reason'] ?? result['error'] ?? 'Unknown error';
      triggerMessage = '⚠️ $reason';
    } else {
      triggerMessage = '❌ No response from server\n${AppConstants.serverBase}';
    }

    notifyListeners();
    Future.delayed(const Duration(seconds: 5), () {
      triggerMessage = '';
      notifyListeners();
    });
  }

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