import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../constants.dart';
import '../models/ring_sample_packet.dart';
import 'ring_ble_service.dart';

void _log(String m) {
  if (AppConstants.verboseLogging || !kReleaseMode) debugPrint(m);
}

const String polarDir = '/sdcard/Download/Data_from_H10';
const String espLatestFile = '$polarDir/ESP_LATEST_esp.txt';
const String espRawFile = '$polarDir/ESP_raw.log';

const int kMinRRms = 300;
const int kMaxRRms = 2000;
const int kRefractoryMs = 300;
const int kProcessEverySeconds = 5;

class BleIngestService {
  static final BleIngestService _instance = BleIngestService._internal();
  factory BleIngestService() => _instance;
  BleIngestService._internal();

  StreamSubscription<RingSamplePacket>? _pktSub;
  Timer? _procTimer;

  final List<RingSamplePacket> _buf = [];
  final List<int> _beatTs = [];
  final List<String> _recentRows = [];

  int? _tsOffsetMs;
  bool _running = false;
  String? _lastWrittenRow;

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) {
      _log('[BLE INGEST] start ignored, already running');
      return;
    }

    _running = true;
    _tsOffsetMs = null;
    _lastWrittenRow = null;

    try {
      final dir = Directory(polarDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      _log('[BLE INGEST] could not create data dir: $e');
    }

    await RingBleService().start();

    _pktSub = RingBleService().packets.listen(
      _handlePacket,
      onError: (e) => _log('[BLE INGEST] packet stream error: $e'),
    );

    _procTimer = Timer.periodic(
      const Duration(seconds: kProcessEverySeconds),
      (_) async {
        try {
          await _processBuffer();
        } catch (e) {
          _log('[BLE INGEST] process error: $e');
        }
      },
    );

    _log('[BLE INGEST] started');
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _pktSub?.cancel();
    _pktSub = null;
    _procTimer?.cancel();
    _procTimer = null;
    await RingBleService().stop();
    _log('[BLE INGEST] stopped');
  }

  void _handlePacket(RingSamplePacket p) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _tsOffsetMs ??= now - p.tsMs;

    _buf.add(p);
    if (_buf.length > 20000) {
      _buf.removeRange(0, _buf.length - 20000);
    }

    unawaited(_appendRawLine(p));
  }

  Future<void> _appendRawLine(RingSamplePacket p) async {
    try {
      final epochMs = p.tsMs + (_tsOffsetMs ?? 0);
      final dt = DateTime.fromMillisecondsSinceEpoch(epochMs).toIso8601String();
      final line = '$dt;${p.ir};${p.red}\n';
      await File(espRawFile).writeAsString(line, mode: FileMode.append);
    } catch (e) {
      _log('[BLE INGEST] raw log write error: $e');
    }
  }

  Future<void> _processBuffer() async {
    if (_buf.isEmpty) return;

    final samples = List<RingSamplePacket>.from(_buf);
    final xs = <int>[];
    final ys = <double>[];

    for (final s in samples) {
      xs.add(s.tsMs + (_tsOffsetMs ?? 0));
      ys.add(s.ir.toDouble());
    }

    final detected = detectPeaksFromSamples(xs, ys);
    for (final t in detected) {
      if (_beatTs.isEmpty || (t - _beatTs.last) > kRefractoryMs) {
        _beatTs.add(t);
      }
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cutoff = nowMs - (30 * 60 * 1000);
    while (_beatTs.isNotEmpty && _beatTs.first < cutoff) {
      _beatTs.removeAt(0);
    }

    final rrs = <int>[];
    for (int i = 1; i < _beatTs.length; i++) {
      final rr = _beatTs[i] - _beatTs[i - 1];
      if (rr >= kMinRRms && rr <= kMaxRRms) {
        rrs.add(rr);
      }
    }

    if (rrs.length < 2) {
      _log('[BLE INGEST] insufficient RR intervals yet');
      return;
    }

    final window = min(rrs.length, 60);
    final recentRRs = rrs.sublist(rrs.length - window);

    final rmssd = _computeRmssd(recentRRs);
    final hr = 60000.0 / recentRRs.last;
    final br = _estimateBrFromHr(hr);
    final ts = DateTime.now().toIso8601String();

    if (hr.isNaN || hr < 30 || hr > 220) {
      _log('[BLE INGEST] invalid HR computed: $hr');
      return;
    }

    final row = '$ts;${hr.toStringAsFixed(1)};${rmssd.isNaN ? '' : rmssd.toStringAsFixed(1)};${br.toStringAsFixed(1)}';
    if (row == _lastWrittenRow) {
      return;
    }
    _lastWrittenRow = row;

    _recentRows.add(row);
    if (_recentRows.length > 600) {
      _recentRows.removeRange(0, _recentRows.length - 600);
    }

    await _flushEspFile();
  }

  double _computeRmssd(List<int> arr) {
    if (arr.length < 2) return double.nan;
    double sum = 0.0;
    for (int i = 1; i < arr.length; i++) {
      final d = arr[i] - arr[i - 1];
      sum += d * d;
    }
    return sqrt(sum / (arr.length - 1));
  }

  double _estimateBrFromHr(double hr) {
    return (10.0 + ((hr - 55.0) / 45.0) * 8.0).clamp(8.0, 22.0);
  }

  Future<void> _flushEspFile() async {
    if (_recentRows.isEmpty) return;

    final buffer = StringBuffer();
    buffer.writeln('timestamp;hr;hrv;br');
    for (final row in _recentRows) {
      buffer.writeln(row);
    }

    final tmpPath = '$espLatestFile.tmp';
    try {
      final tmp = File(tmpPath);
      await tmp.writeAsString(buffer.toString(), flush: true);
      try {
        final target = File(espLatestFile);
        if (await target.exists()) {
          await target.delete();
        }
      } catch (_) {}
      await tmp.rename(espLatestFile);
      _log('[BLE INGEST] wrote ESP vitals file: $espLatestFile');

      try {
        final prefs = await SharedPreferences.getInstance();
        final sensor = prefs.getString('sensor_type') ?? '';
        FlutterBackgroundService().invoke('reload_sensor', {
          'sensor_type': sensor,
        });
      } catch (e) {
        _log('[BLE INGEST] reload invoke failed: $e');
      }
    } catch (e) {
      _log('[BLE INGEST] vitals file write error: $e');
    }
  }
}

List<double> _movingMedianStatic(List<double> vals, int win) {
  final n = vals.length;
  final out = List<double>.filled(n, 0.0);
  final half = win ~/ 2;
  for (int i = 0; i < n; i++) {
    final start = max(0, i - half);
    final end = min(n, i + half + 1);
    final slice = vals.sublist(start, end)..sort();
    out[i] = slice[slice.length ~/ 2];
  }
  return out;
}

List<int> detectPeaksFromSamples(List<int> xs, List<double> ys) {
  if (xs.length != ys.length) {
    throw ArgumentError('xs and ys must have same length');
  }
  if (xs.length < 3) return [];

  final baseline = _movingMedianStatic(ys, 31);
  final vals = List<double>.generate(ys.length, (i) => ys[i] - baseline[i]);

  final detected = <int>[];
  int? lastPeak;
  for (int i = 1; i < vals.length - 1; i++) {
    final cur = vals[i];
    if (cur > vals[i - 1] && cur > vals[i + 1]) {
      final windowStart = max(0, i - 50);
      final windowEnd = min(vals.length, i + 50);
      double localMin = vals[windowStart];
      double localMax = vals[windowStart];
      for (int j = windowStart; j < windowEnd; j++) {
        localMin = min(localMin, vals[j]);
        localMax = max(localMax, vals[j]);
      }
      final amp = localMax - localMin;
      if (amp <= 0) continue;
      if (cur < (localMin + amp * 0.4)) continue;

      final t = xs[i];
      if (lastPeak == null || (t - lastPeak) > 300) {
        detected.add(t);
        lastPeak = t;
      }
    }
  }

  return detected;
}
