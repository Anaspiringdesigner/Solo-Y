import 'package:hive_flutter/hive_flutter.dart';
import '../models/vitals_point.dart';

class LocalRingStore {
  static final LocalRingStore _instance = LocalRingStore._internal();
  factory LocalRingStore() => _instance;
  LocalRingStore._internal();

  static const String pointsBoxName = 'ring_points_box';
  static const String metaBoxName = 'ring_meta_box';

  Box<dynamic>? _pointsBox;
  Box<dynamic>? _metaBox;

  Future<void> init() async {
    await Hive.initFlutter();
    _pointsBox ??= await Hive.openBox(pointsBoxName);
    _metaBox ??= await Hive.openBox(metaBoxName);
  }

  Future<void> appendPoint(VitalsPoint point) async {
    await init();
    await _pointsBox!.add({
      'uploaded_batch': false,
      'ts': point.ts.toUtc().toIso8601String(),
      'hr': point.hr,
      'hrv': point.hrv,
      'br': point.br,
    });
  }

  Future<List<_StoredPoint>> getPendingBatchPoints() async {
    await init();
    final out = <_StoredPoint>[];
    for (final key in _pointsBox!.keys) {
      final raw = _pointsBox!.get(key);
      if (raw is Map && raw['uploaded_batch'] != true) {
        out.add(_StoredPoint(key: key, point: VitalsPoint.fromJson(raw.cast<dynamic, dynamic>())));
      }
    }
    return out;
  }

  Future<void> markBatchUploaded(List<dynamic> keys) async {
    await init();
    for (final key in keys) {
      final raw = _pointsBox!.get(key);
      if (raw is Map) {
        raw['uploaded_batch'] = true;
        await _pointsBox!.put(key, raw);
      }
    }
  }

  Future<int> nextSequence() async {
    await init();
    final curr = (_metaBox!.get('seq') ?? 0) as int;
    final next = curr + 1;
    await _metaBox!.put('seq', next);
    return next;
  }

  Future<void> setRealtimeActive(bool value) async {
    await init();
    await _metaBox!.put('realtime_active', value);
  }

  Future<bool> getRealtimeActive() async {
    await init();
    return (_metaBox!.get('realtime_active') ?? false) as bool;
  }
}

class _StoredPoint {
  final dynamic key;
  final VitalsPoint point;

  _StoredPoint({required this.key, required this.point});
}