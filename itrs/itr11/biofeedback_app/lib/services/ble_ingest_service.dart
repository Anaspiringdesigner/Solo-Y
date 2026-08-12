import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/ring_sample_packet.dart';
import 'ring_ble_service.dart';
import '../constants.dart';

void _log(String m) {
  if (AppConstants.verboseLogging || !kReleaseMode) debugPrint(m);
}

// Uses same folder as existing DataTransferService expects
const String polarDir = '/sdcard/Download/Data_from_H10';

// Detection + write params
const int kMinRRms = 300; // 200-300 ms min RR
const int kMaxRRms = 2000; // 2s max RR
const int kRefractoryMs = 300; // minimal time between beats
const int kFlushIntervalSeconds = 10; // how often to write HR file

class BleIngestService {
  static final BleIngestService _instance = BleIngestService._internal();
  factory BleIngestService() => _instance;
  BleIngestService._internal();

  StreamSubscription<RingSamplePacket>? _pktSub;
  final List<RingSamplePacket> _buf = [];
  final List<int> _beatTs = []; // milliseconds epoch

  // offset to convert device tsMs -> epoch ms
  int? _tsOffsetMs;

  Timer? _procTimer;
  bool _running = false;

  Future<void> start() async {
    if (_running) return;
    _running = true;

    // ensure folder exists
    try {
      final dir = Directory(polarDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      _log('[BLE INGEST] could not create polar dir: $e');
    }

    // start BLE scanner
    await RingBleService().start();

    _pktSub = RingBleService().packets.listen((p) {
      _handlePacket(p);
    }, onError: (e) {
      _log('[BLE INGEST] packet stream error: $e');
    });

    // periodic processing (detect peaks, flush HR files)
    _procTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      try {
        _processBuffer();
      } catch (e) {
        _log('[BLE INGEST] process error: $e');
      }
    });
  }

  Future<void> stop() async {
    _running = false;
    await _pktSub?.cancel();
    _pktSub = null;
    _procTimer?.cancel();
    _procTimer = null;
    await RingBleService().stop();
  }

  void _handlePacket(RingSamplePacket p) {
    // establish offset mapping from device ts to epoch
    final now = DateTime.now().millisecondsSinceEpoch;
    _tsOffsetMs ??= now - p.tsMs;

    _buf.add(p);

    // keep buffer to last ~30s
    if (_buf.length > 20000) {
      _buf.removeRange(0, _buf.length - 20000);
    }

    // also append raw sample to a rolling raw file (non-blocking)
    _appendRawLine(p);
  }

  Future<void> _appendRawLine(RingSamplePacket p) async {
    try {
      final epochMs = (p.tsMs + (_tsOffsetMs ?? 0));
      final dt = DateTime.fromMillisecondsSinceEpoch(epochMs).toIso8601String();
      final line = '$dt;${p.ir};${p.red}\n';
      final f = File('$polarDir/BLE_raw.log');
      try {
        await f.writeAsString(line, mode: FileMode.append);
      } catch (e) {
        _log('[BLE INGEST] raw log write error: $e');
      }
    } catch (e) {
      // ignore write errors
    }
  }

  void _processBuffer() {
    if (_buf.isEmpty) return;

    // copy buffer and clear small prefix to avoid unbounded growth
    final samples = List<RingSamplePacket>.from(_buf);

    // convert to list of (t, val)
    final xs = <int>[]; // timestamp epoch ms
    final ys = <double>[]; // ir values as double
    for (final s in samples) {
      final t = s.tsMs + (_tsOffsetMs ?? 0);
      xs.add(t);
      ys.add(s.ir.toDouble());
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Detect peaks using helper (moving median baseline + prominence)
    final detected = detectPeaksFromSamples(xs, ys);

    // merge newly detected beats (keep unique and increasing, enforce refractory)
    for (final t in detected) {
      if (_beatTs.isEmpty || t - _beatTs.last > kRefractoryMs) {
        _beatTs.add(t);
      }
    }

    // keep only recent beats (last 30 minutes)
    final cutoff = nowMs - (30 * 60 * 1000);
    while (_beatTs.isNotEmpty && _beatTs.first < cutoff) {
      _beatTs.removeAt(0);
    }

    // compute RR intervals and clean out unrealistic intervals
    final rrs = <int>[];
    for (int i = 1; i < _beatTs.length; i++) {
      final rr = _beatTs[i] - _beatTs[i - 1];
      if (rr >= kMinRRms && rr <= kMaxRRms) rrs.add(rr);
    }

    if (rrs.isEmpty) return;

    // compute HR and HRV metrics (RMSSD, SDNN) using last N intervals
    final window = min(rrs.length, 60); // use up to last 60 intervals (~1 minute)
    final recentRRs = rrs.sublist(rrs.length - window);

    double computeRMSSD(List<int> arr) {
      if (arr.length < 2) return double.nan;
      double sum = 0.0;
      for (int i = 1; i < arr.length; i++) {
        final d = arr[i] - arr[i - 1];
        sum += d * d;
      }
      final mean = sum / (arr.length - 1);
      return sqrt(mean);
    }

    double computeSDNN(List<int> arr) {
      if (arr.isEmpty) return double.nan;
      final mean = arr.reduce((a, b) => a + b) / arr.length;
      final varSum = arr.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / arr.length;
      return sqrt(varSum);
    }

    final rmssd = computeRMSSD(recentRRs);
    final sdnn = computeSDNN(recentRRs);

    // Write rows for most recent beats (only beats in last flush interval)
    final recentBeats = _beatTs.where((t) => t >= nowMs - (kFlushIntervalSeconds * 1000)).toList();
    if (recentBeats.isEmpty) return;

    final rows = <String>[];
    for (final t in recentBeats) {
      // find rr preceding this beat
      final idx = _beatTs.indexOf(t);
      if (idx <= 0) continue;
      final rr = _beatTs[idx] - _beatTs[idx - 1];
      if (rr <= 0) continue;
      final hr = 60000.0 / rr;
      final dt = DateTime.fromMillisecondsSinceEpoch(t).toIso8601String();
      // include HRV as RMSSD (ms) — DataTransferService will still validate
      final hrvVal = rmssd.isNaN ? '' : rmssd.toStringAsFixed(1);
      final hrStr = hr.toStringAsFixed(1);
      rows.add('$dt;$hrStr;$hrvVal;\n');
    }

    // write a rolling file that ends with _HR.txt so existing DataTransferService picks it up
    _flushHrFile(rows, rmssd: rmssd, sdnn: sdnn);
  }

  Future<void> _flushHrFile(List<String> rows, {double? rmssd, double? sdnn}) async {
    if (rows.isEmpty) return;
    try {
      final iso = DateTime.now().toIso8601String();
      final filename = 'BLE_${iso}_HR.txt'.replaceAll(':', '-');
      final temp = '$polarDir/.$filename.tmp';
      final finalPath = '$polarDir/$filename';

      const header = 'Phone timestamp;hr;hrv;br\n';
      final tmpFile = File(temp);
      await tmpFile.writeAsString(header + rows.join());
      // atomic rename
      try {
        await tmpFile.rename(finalPath);
      } catch (e) {
        // fallback to copy+delete
        await tmpFile.copy(finalPath);
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      _log('[BLE INGEST] Wrote HR file: $filename');
      if (rmssd != null || sdnn != null) {
        _log('[BLE INGEST] HRV RMSSD=${rmssd == null || rmssd.isNaN ? 'na' : rmssd.toStringAsFixed(1)} SDNN=${sdnn == null || sdnn.isNaN ? 'na' : sdnn.toStringAsFixed(1)}');
      }
    } catch (e) {
      debugPrint('[BLE INGEST] write HR file error: $e');
    }
  }

}

// --- Helper functions (exported for unit tests) ----------------------
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
