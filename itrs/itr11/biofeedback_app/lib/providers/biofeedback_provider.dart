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

  List<DashboardOption> dashboards = [];
  int? selectedDashboardId;
  bool isDashboardLoading = false;
  bool isConfirmingDashboard = false;
  String dashboardMessage = '';

  Timer? _statusTimer;

  void startPolling() {
    _fetchStatus();
    _fetchDashboards();

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

  Future<void> _fetchDashboards() async {
    dashboards = await _api.fetchDashboards();
    notifyListeners();
  }

  void selectDashboard(int id) {
    selectedDashboardId = id;
    notifyListeners();
  }

  Future<void> _fetchStatus() async {
    final result = await _api.fetchStatus();
    if (result != null) {
      final prevInteraction = status?.activeInteraction ?? -1;
      final newInteraction = result.activeInteraction;
      final hadPending = status?.hasPendingIntervention ?? false;

      status = result;
      isConnected = true;

      if (result.hasPendingIntervention) {
        selectedDashboardId ??= result.proposedDashboardId;
      } else if (hadPending && !result.hasPendingIntervention) {
        selectedDashboardId = null;
      }

      if (newInteraction == 3 && prevInteraction != 3) {
        _startCamera();
      } else if (newInteraction != 3 && prevInteraction == 3) {
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

  Future<void> createCustomDashboard(String instruction) async {
    final clean = instruction.trim();
    if (clean.isEmpty) {
      dashboardMessage = 'Enter an action first';
      notifyListeners();
      return;
    }

    isDashboardLoading = true;
    dashboardMessage = '';
    notifyListeners();

    final result = await _api.createDashboard(instruction: clean);
    isDashboardLoading = false;

    if (result != null && result['ok'] == true) {
      final dashboard = result['dashboard'] as Map<String, dynamic>?;
      if (dashboard != null) {
        final created = DashboardOption.fromJson(dashboard);
        final idx = dashboards.indexWhere((d) => d.id == created.id);
        if (idx >= 0) {
          dashboards[idx] = created;
        } else {
          dashboards.add(created);
          dashboards.sort((a, b) => a.id.compareTo(b.id));
        }
        selectedDashboardId = created.id;
      }
      dashboardMessage = result['duplicate'] == true
          ? 'Using existing dashboard'
          : 'Dashboard created';
    } else {
      dashboardMessage = result?['reason'] ?? result?['error'] ?? 'Failed to create dashboard';
    }

    notifyListeners();
  }

  Future<void> confirmSelectedDashboard() async {
    final id = selectedDashboardId ?? status?.proposedDashboardId;
    if (id == null) return;

    isConfirmingDashboard = true;
    dashboardMessage = '';
    notifyListeners();

    final result = await _api.confirmAction(executedDashboardId: id);
    isConfirmingDashboard = false;

    if (result != null && result['ok'] == true) {
      dashboardMessage = 'Action confirmed';
      await _fetchStatus();
    } else {
      dashboardMessage = result?['reason'] ?? result?['error'] ?? 'Confirmation failed';
      notifyListeners();
    }
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
      await _fetchStatus();
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