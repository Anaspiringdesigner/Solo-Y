import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/vitals_point.dart';
import 'api_service.dart';

class RingIngestService {
  static final RingIngestService _instance = RingIngestService._internal();
  factory RingIngestService() => _instance;
  RingIngestService._internal();

  final ApiService _api = ApiService();

  int _seq = 0;
  String _deviceId = 'ringA';
  int _schemaVersion = 1;

  Timer? _batchTimer;
  Timer? _realtimeTimer;

  bool _isRealtimeActive = false;

  final List<VitalsPoint> _buffer = [];
  final List<VitalsPoint> _realtimeWindow = [];

  void configure({
    required String deviceId,
    int schemaVersion = 1,
    int startSeq = 0,
  }) {
    _deviceId = deviceId;
    _schemaVersion = schemaVersion;
    _seq = startSeq;
  }

  int get currentSeq => _seq;
  bool get isRealtimeActive => _isRealtimeActive;

  void ingestComputedPoint(VitalsPoint p) {
    _buffer.add(p);
    if (_isRealtimeActive) {
      _realtimeWindow.add(p);
    }
  }

  void startBatchSync({Duration interval = const Duration(minutes: 30)}) {
    _batchTimer?.cancel();
    _batchTimer = Timer.periodic(interval, (_) async {
      await _sendBatchChunk();
    });
  }

  void stopBatchSync() {
    _batchTimer?.cancel();
    _batchTimer = null;
  }

  void startRealtime({Duration interval = const Duration(seconds: 2)}) {
    _realtimeTimer?.cancel();
    _isRealtimeActive = true;
    _realtimeWindow.clear();

    _realtimeTimer = Timer.periodic(interval, (_) async {
      await _sendRealtimeChunk();
    });
  }

  Future<void> stopRealtime() async {
    _realtimeTimer?.cancel();
    _realtimeTimer = null;
    _isRealtimeActive = false;
    await _sendRealtimeChunk();
  }

  Future<void> _sendBatchChunk() async {
    if (_buffer.isEmpty) return;

    final points = List<VitalsPoint>.from(_buffer);
    _buffer.clear();

    final seq = ++_seq;
    final res = await _api.postPointsBatch(
      deviceId: _deviceId,
      seqNo: seq,
      schemaVersion: _schemaVersion,
      idempotencyKey: _idempotencyKey(seq),
      points: points,
    );

    debugPrint('[RING][BATCH] seq=$seq points=${points.length} -> $res');
  }

  Future<void> _sendRealtimeChunk() async {
    if (_realtimeWindow.isEmpty) return;

    final points = List<VitalsPoint>.from(_realtimeWindow);
    _realtimeWindow.clear();

    final seq = ++_seq;
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