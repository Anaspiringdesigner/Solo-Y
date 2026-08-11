import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/biofeedback_model.dart';
import '../models/vitals_point.dart';
import '../services/api_service.dart';
import '../services/data_transfer_service.dart';
import '../constants.dart';
import '../services/mjpeg_server.dart';
import '../services/ring_ingest_service.dart';
import '../services/auth_service.dart';
import '../services/ring_ble_service.dart';
import '../services/ppg_feature_service.dart';

class BiofeedbackProvider extends ChangeNotifier {
  final ApiService _api = ApiService();
  final RingIngestService _ring = RingIngestService();
  final AuthService _auth = AuthService();
  final RingBleService _ble = RingBleService();
  final PpgFeatureService _ppg = PpgFeatureService();

  StreamSubscription? _blePktSub;
  StreamSubscription? _ppgPointSub;

  BiofeedbackStatus? status;
  bool isConnected = false;
  bool isTriggerLoading = false;
  bool isDataTransferActive = false;
  bool isSigningIn = false;
  bool isAuthenticated = false;
  bool isInitializing = true;
  String triggerMessage = '';
  String calendarMessage = '';
  String authMessage = '';
  String dataTransferStatus = 'Stopped';
  String startupError = '';

  double liveHr = 0;
  double liveHrv = 0;
  double liveBr = 0;

  final List<double> hrvHistory = [];
  final List<double> hrHistory = [];

  Timer? _statusTimer;
  Timer? _realtimeWatchdogTimer;

  Future<void> initializeAuth() async {
    isInitializing = true;
    isSigningIn = true;
    startupError = '';
    notifyListeners();

    try {
      await _ring.init();
      final ok = await _auth.tryRestoreSession();
      isAuthenticated = ok;
      authMessage = ok ? 'Signed in as ${_auth.currentUser?.email ?? 'user'}' : '';
      if (ok) {
        startPolling();
        await startRingBatchSync();
        await _startRingPipeline();
      }
    } catch (e) {
      startupError = 'Startup auth failed: $e';
      if (kDebugMode) {
        debugPrint('[BIO] initializeAuth error: $e');
      }
    } finally {
      isSigningIn = false;
      isInitializing = false;
      notifyListeners();
    }
  }

  Future<bool> signInWithGoogle() async {
    isSigningIn = true;
    authMessage = '';
    startupError = '';
    notifyListeners();

    final ok = await _auth.signIn();
    isAuthenticated = ok;
    isSigningIn = false;
    authMessage = ok
        ? 'Signed in as ${_auth.currentUser?.email ?? 'user'}'
        : 'Google sign-in failed';

    if (ok) {
      await _ring.init();
      startPolling();
      await startRingBatchSync();
      await _startRingPipeline();
    }

    notifyListeners();
    return ok;
  }

  Future<void> signOut() async {
    stopPolling();
    _ring.stopBatchSync();
    await _ring.stopRealtime();
    _realtimeWatchdogTimer?.cancel();
    await _stopRingPipeline();

    await _auth.signOut();
    isAuthenticated = false;
    authMessage = 'Signed out';
    status = null;
    isConnected = false;
    hrvHistory.clear();
    hrHistory.clear();
    liveHr = 0;
    liveHrv = 0;
    liveBr = 0;
    notifyListeners();
  }

  void startPolling() {
    _statusTimer?.cancel();
    if (!isAuthenticated) return;

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
    _ring.configure(deviceId: 'ringA', schemaVersion: 1);
    _ring.startBatchSync(interval: const Duration(minutes: AppConstants.batchUploadMinutes));
  }

  Future<void> _startRingPipeline() async {
    debugPrint('[BIO] Starting ring pipeline...');
    await _blePktSub?.cancel();
    await _ppgPointSub?.cancel();

    _blePktSub = _ble.packets.listen((pkt) {
      _ppg.addPacket(pkt);
    });

    _ppgPointSub = _ppg.points.listen((VitalsPoint pt) async {
      liveHr = pt.hr;
      liveHrv = pt.hrv;
      liveBr = pt.br;

      hrvHistory.add(pt.hrv);
      hrHistory.add(pt.hr);
      if (hrvHistory.length > 60) hrvHistory.removeAt(0);
      if (hrHistory.length > 60) hrHistory.removeAt(0);

      await _ring.ingestComputedPoint(pt);
      notifyListeners();
    });

    await _ble.start();
  }

  Future<void> _stopRingPipeline() async {
    await _ble.stop();
    await _blePktSub?.cancel();
    await _ppgPointSub?.cancel();
    _blePktSub = null;
    _ppgPointSub = null;
  }

  Future<void> _fetchStatus() async {
    if (!isAuthenticated) {
      isConnected = false;
      notifyListeners();
      return;
    }

    final result = await _api.fetchStatus();
    if (result != null) {
      final prevInteraction = status?.activeInteraction ?? -1;
      final prevHolding = status?.isHolding ?? false;

      status = result;
      isConnected = true;

      if (result.isHolding && !_ring.isRealtimeActive) {
        await _ring.startRealtime(interval: const Duration(seconds: AppConstants.realtimeUploadSeconds));
        _startRealtimeWatchdog();
      } else if (!result.isHolding && _ring.isRealtimeActive) {
        await _ring.stopRealtime();
        _realtimeWatchdogTimer?.cancel();
      }

      final newInteraction = result.activeInteraction;
      if (AppConstants.enableCameraInteraction) {
        if (newInteraction == 4 && prevInteraction != 4) {
          _startCamera();
        } else if (newInteraction != 4 && prevInteraction == 4) {
          _stopCamera();
        }
      }

      if (prevHolding && !result.isHolding) {
        _realtimeWatchdogTimer?.cancel();
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

  void _startRealtimeWatchdog() {
    _realtimeWatchdogTimer?.cancel();
    _realtimeWatchdogTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final s = status;
      if (s == null || !s.isHolding) {
        await _ring.stopRealtime();
        _realtimeWatchdogTimer?.cancel();
      }
    });
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
    await _fireTrigger(triggerType: 'manual', label: 'Manual trigger fired');
  }

  Future<void> fireCalendarTrigger(String eventName) async {
    await _fireTrigger(triggerType: 'calendar', label: '📅 $eventName — trigger sent');
  }

  Future<void> _fireTrigger({required String triggerType, required String label}) async {
    if (!isAuthenticated) {
      triggerMessage = 'Please sign in first';
      notifyListeners();
      return;
    }

    isTriggerLoading = true;
    triggerMessage = '';
    notifyListeners();

    final result = await _api.fireTrigger(
      triggerType: triggerType,
      streamDurationSec: AppConstants.triggerStreamDurationSec,
    );

    isTriggerLoading = false;

    if (result != null && result['ok'] == true) {
      bool confirmed = false;
      for (int i = 0; i < 6; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        final s = await _api.fetchStatus();
        if (s != null) {
          status = s;
          if (s.isHolding) {
            confirmed = true;
            break;
          }
        }
      }

      if (confirmed) {
        triggerMessage = '✅ $label';
        await _ring.startRealtime(interval: const Duration(seconds: AppConstants.realtimeUploadSeconds));
        _startRealtimeWatchdog();
      } else {
        triggerMessage = '⚠️ Trigger acknowledged but hold not confirmed';
      }
    } else {
      final err = result?['error']?.toString() ?? '';
      if (err.contains('HTTP 401')) {
        await signOut();
        triggerMessage = 'Session expired. Please sign in again.';
      } else {
        final reason = result?['error'] ?? result?['reason'] ?? 'Unknown error';
        triggerMessage = '⚠️ $reason';
      }
    }

    notifyListeners();

    Future.delayed(const Duration(seconds: 5), () {
      triggerMessage = '';
      notifyListeners();
    });
  }

  @override
  void dispose() {
    stopPolling();
    _ring.stopBatchSync();
    _ring.stopRealtime();
    _realtimeWatchdogTimer?.cancel();
    _stopRingPipeline();
    _ppg.dispose();
    super.dispose();
  }
}