import 'dart:async';
import 'package:flutter/foundation.dart';
import '../constants.dart';
import '../models/vitals_point.dart';
import 'api_service.dart';
import 'local_ring_store.dart';

class RingIngestService {
  static final RingIngestService _instance = RingIngestService._internal();
  factory RingIngestService() => _instance;
  RingIngestService._internal();

  final ApiService _api = ApiService();
  final LocalRingStore _store = LocalRingStore();

  String _deviceId = 'ringA';
  int _schemaVersion = 1;

  Timer? _batchTimer;
  Timer? _realtimeTimer;

  bool _isRealtimeActive = false;
  final List<VitalsPoint> _realtimeWindow = [];

  void configure({
    required String deviceId,
    int schemaVersion = 1,
  }) {
    _deviceId = deviceId;
    _schemaVersion = schemaVersion;
  }

  bool get isRealtimeActive => _isRealtimeActive;

  Future<void> init() async {
    await _store.init();
    _isRealtimeActive = await _store.getRealtimeActive();
  }

  Future<void> ingestComputedPoint(VitalsPoint p) async {
    await _store.appendPoint(p);
    if (_isRealtimeActive) {
      _realtimeWindow.add(p);
    }
  }

  void startBatchSync({Duration interval = const Duration(minutes: AppConstants.batchUploadMinutes)}) {
    _batchTimer?.cancel();
    _batchTimer = Timer.periodic(interval, (_) async {
      await sendBatchNow();
    });
  }

  void stopBatchSync() {
    _batchTimer?.cancel();
    _batchTimer = null;
  }

  Future<void> startRealtime({Duration interval = const Duration(seconds: AppConstants.realtimeUploadSeconds)}) async {
    _realtimeTimer?.cancel();
    _isRealtimeActive = true;
    _realtimeWindow.clear();
    await _store.setRealtimeActive(true);

    _realtimeTimer = Timer.periodic(interval, (_) async {
      await _sendRealtimeChunk();
    });
  }

  Future<void> stopRealtime() async {
    _realtimeTimer?.cancel();
    _realtimeTimer = null;
    _isRealtimeActive = false;
    await _store.setRealtimeActive(false);
    await _sendRealtimeChunk();
  }

  Future<void> sendBatchNow() async {
    final pending = await _store.getPendingBatchPoints();
    if (pending.isEmpty) return;

    final seq = await _store.nextSequence();
    final points = pending.map((e) => e.point).toList();
    final res = await _api.postPointsBatch(
      deviceId: _deviceId,
      seqNo: seq,
      schemaVersion: _schemaVersion,
      idempotencyKey: _idempotencyKey(seq),
      points: points,
    );

    final status = res?['status'] ?? 0;
    if (status == 200) {
      await _store.markBatchUploaded(pending.map((e) => e.key).toList());
    }

    debugPrint('[RING][BATCH] seq=$seq points=${points.length} -> $res');
  }

  Future<void> _sendRealtimeChunk() async {
    if (_realtimeWindow.isEmpty) return;

    final points = List<VitalsPoint>.from(_realtimeWindow);
    _realtimeWindow.clear();

    final seq = await _store.nextSequence();
    final res = await _api.postPointsRealtime(
      deviceId: _deviceId,
      seqNo: seq,
      schemaVersion: _schemaVersion,
      idempotencyKey: _idempotencyKey(seq),
      points: points,
    );

    debugPrint('[RING][REALTIME] seq=$seq points=${points.length} -> $res');
  }

  String _idempotencyKey(int seq) {
    final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    return '${_deviceId}_${day}_$seq';
  }
}