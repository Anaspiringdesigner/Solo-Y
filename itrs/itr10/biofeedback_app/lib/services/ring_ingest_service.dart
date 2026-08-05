import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../constants.dart';
import 'api_service.dart';

class RingIngestService {
  static final RingIngestService _instance = RingIngestService._internal();
  factory RingIngestService() => _instance;
  RingIngestService._internal();

  final ApiService _api = ApiService();

  int _seq = 0;
  String _deviceId = 'ringA';
  String _schemaVersion = '1';

  Timer? _batchTimer;
  Timer? _realtimeTimer;

  bool _isRealtimeActive = false;

  void configure({
    required String deviceId,
    String schemaVersion = '1',
    int startSeq = 0,
  }) {
    _deviceId = deviceId;
    _schemaVersion = schemaVersion;
    _seq = startSeq;
  }

  int get currentSeq => _seq;
  bool get isRealtimeActive => _isRealtimeActive;

  void startBatchSync({Duration interval = const Duration(seconds: 30)}) {
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

    _realtimeTimer = Timer.periodic(interval, (_) async {
      await _sendRealtimeChunk();
    });
  }

  void stopRealtime() {
    _realtimeTimer?.cancel();
    _realtimeTimer = null;
    _isRealtimeActive = false;
  }

  Future<void> _sendBatchChunk() async {
    final payload = _buildPayload(mode: 'batch');
    final res = await _api.postBatch(payload);
    debugPrint('[RING][BATCH] seq=${payload['seq_no']} -> $res');
  }

  Future<void> _sendRealtimeChunk() async {
    final payload = _buildPayload(mode: 'realtime');
    final res = await _api.postRealtime(payload);
    debugPrint('[RING][REALTIME] seq=${payload['seq_no']} -> $res');
  }

  Map<String, dynamic> _buildPayload({required String mode}) {
    final now = DateTime.now().toUtc();
    final start = now.subtract(const Duration(seconds: 30));
    final seq = ++_seq;

    final samples = AppConstants.useMockRing
        ? _mockSamples()
        : _placeholderRealRingSamples();

    return {
      'device_id': _deviceId,
      'mode': mode,
      'start_ts': _iso(start),
      'end_ts': _iso(now),
      'seq_no': seq,
      'sample_rate_hz': 25.0,
      'hr': samples['hr'],
      'hrv': samples['hrv'],
      'br': samples['br'],
      'schema_version': int.parse(_schemaVersion),
      'idempotency_key': _idempotencyKey(seq),
    };
  }

  String _iso(DateTime dt) => dt.toIso8601String().split('.').first;

  String _idempotencyKey(int seq) {
    final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    return '${_deviceId}_$day_$seq';
  }

  Map<String, List<num>> _mockSamples() {
    final r = Random();
    final hr = List<num>.generate(12, (_) => 68 + r.nextInt(10));
    final hrv = List<num>.generate(12, (_) => 28 + r.nextDouble() * 12);
    final br = List<num>.generate(12, (_) => 11 + r.nextDouble() * 4);
    return {
      'hr': hr,
      'hrv': hrv,
      'br': br,
    };
  }

  Map<String, List<num>> _placeholderRealRingSamples() {
    debugPrint('[RING] Real ring sample source not implemented yet.');
    return {
      'hr': <num>[],
      'hrv': <num>[],
      'br': <num>[],
    };
  }
}