import 'dart:async';
import 'package:flutter/material.dart';

import '../constants.dart';
import '../models/biofeedback_model.dart';
import '../models/dashboard_model.dart';
import '../services/api_service.dart';
import '../services/data_transfer_service.dart';
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
  int selectedDashboardId = 0;
  String customDashboardInstruction = '';
  bool isCreatingDashboard = false;
  bool isConfirmingDashboard = false;

  Timer? _statusTimer;

  void startPolling() {
    _pollAll();
    _statusTimer = Timer.periodic(
      const Duration(milliseconds: AppConstants.statusPollMs),
      (_) => _pollAll(),
    );
  }

  Future<void> _pollAll() async {
    await _fetchStatus();
    await _fetchDashboards();
  }

  void stopPolling() {
    _statusTimer?.cancel();
  }

  void selectDashboard(int id) {
    selectedDashboardId = id;
    notifyListeners();
  }

  void updateCustomDashboardInstruction(String value) {
    customDashboardInstruction = value;
    notifyListeners();
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

  Future<void> _fetchStatus() async {
    final result = await _api.fetchStatus();
    if (result != null) {
      final prevInteraction = status?.activeInteraction ?? -1;
      final newInteraction = result.activeInteraction;

      status = result;
      isConnected = true;

      if (newInteraction == 3 && prevInteraction != 3) {
        debugPrint('[APP] Interaction 3 active — starting camera');
        await _startCamera();
      } else if (newInteraction != 3 && prevInteraction == 3) {
        debugPrint('[APP] Left interaction 3 — stopping camera');
        await _stopCamera();
      }

      hrvHistory.add(result.avgHrv);
      hrHistory.add(result.avgHr);
      if (hrvHistory.length > 60) {
        hrvHistory.removeAt(0);
      }
      if (hrHistory.length > 60) {
        hrHistory.removeAt(0);
      }

      if (result.hasPendingIntervention &&
          result.interventionPhase == 'awaiting_confirmation') {
        selectedDashboardId = result.proposedDashboardId;
      }
    } else {
      isConnected = false;
    }
    notifyListeners();
  }

  Future<void> _fetchDashboards() async {
    final items = await _api.fetchDashboards();
    dashboards
      ..clear()
      ..addAll(items);

    if (dashboards.isNotEmpty &&
        !dashboards.any((d) => d.id == selectedDashboardId)) {
      selectedDashboardId = dashboards.first.id;
    }

    notifyListeners();
  }

  Future<void> createCustomDashboard() async {
    final instruction = customDashboardInstruction.trim();
    if (instruction.isEmpty) {
      triggerMessage = '⚠️ Enter a custom action first';
      notifyListeners();
      return;
    }

    isCreatingDashboard = true;
    notifyListeners();

    final result = await _api.createDashboard(instruction: instruction);

    isCreatingDashboard = false;

    if (result != null && result['ok'] == true) {
      final rawDashboard = result['dashboard'];
      if (rawDashboard is Map) {
        final created = DashboardOption.fromJson(
          Map<String, dynamic>.from(rawDashboard),
        );

        final existingIndex = dashboards.indexWhere((d) => d.id == created.id);
        if (existingIndex >= 0) {
          dashboards[existingIndex] = created;
        } else {
          dashboards.add(created);
          dashboards.sort((a, b) => a.id.compareTo(b.id));
        }

        selectedDashboardId = created.id;
      }

      triggerMessage = result['duplicate'] == true
          ? 'ℹ️ Existing dashboard selected'
          : '✅ Custom dashboard created';

      customDashboardInstruction = '';
      await _fetchDashboards();
    } else {
      triggerMessage =
          '❌ ${result?['reason'] ?? result?['error'] ?? 'Failed to create dashboard'}';
    }

    notifyListeners();
  }

  Future<void> confirmSelectedDashboard() async {
    isConfirmingDashboard = true;
    notifyListeners();

    final result = await _api.confirmAction(
      executedDashboardId: selectedDashboardId,
    );

    isConfirmingDashboard = false;

    if (result != null && result['ok'] == true) {
      triggerMessage = '✅ Action confirmed';
      await _fetchStatus();
    } else {
      triggerMessage =
          '❌ ${result?['reason'] ?? result?['error'] ?? 'Failed to confirm action'}';
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
      debugPrint('[APP] Camera streaming → ${server.streamUrl}');
    }
  }

  Future<void> _stopCamera() async {
    final server = MjpegServer();
    if (server.isStreaming) {
      await server.stopStreaming();
      debugPrint('[APP] Camera stopped');
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
      await _fetchDashboards();
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
    await _fetchStatus();
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