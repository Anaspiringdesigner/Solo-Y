import 'dart:async';
import 'dart:math';
import '../models/ring_sample_packet.dart';
import '../models/vitals_point.dart';

class PpgFeatureService {
  final _outCtrl = StreamController<VitalsPoint>.broadcast();
  Stream<VitalsPoint> get points => _outCtrl.stream;

  final List<RingSamplePacket> _window = [];
  static const int windowMs = 10000; // 10s window

  // Simple smoothing state
  double? _prevHr;
  double? _prevHrv;
  double? _prevBr;

  void addPacket(RingSamplePacket p) {
    _window.add(p);
    final cutoff = p.tsMs - windowMs;
    _window.removeWhere((x) => x.tsMs < cutoff);

    if (_window.length < 100) return;

    final point = _computePoint(_window);
    if (point != null) _outCtrl.add(point);
  }

  VitalsPoint? _computePoint(List<RingSamplePacket> w) {
    final xs = w.map((e) => e.ir.toDouble()).toList();
    if (xs.length < 100) return null;

    // If signal is clipped/saturated, skip
    final satCount = xs.where((v) => v >= 260000).length;
    if (satCount / xs.length > 0.2) return null;

    // crude but tighter peak detection
    final peaks = <int>[];
    for (int i = 2; i < xs.length - 2; i++) {
      if (xs[i] > xs[i - 1] &&
          xs[i] > xs[i - 2] &&
          xs[i] > xs[i + 1] &&
          xs[i] > xs[i + 2]) {
        peaks.add(i);
      }
    }
    if (peaks.length < 5) return null;

    final ts = w.map((e) => e.tsMs).toList();
    final rr = <double>[];
    for (int i = 1; i < peaks.length; i++) {
      final dt = (ts[peaks[i]] - ts[peaks[i - 1]]).toDouble();
      if (dt >= 400 && dt <= 1400) rr.add(dt); // tighter physiological range
    }
    if (rr.length < 4) return null;

    rr.sort();
    final median = rr[rr.length ~/ 2];
    final rrClean = rr.where((x) => (x - median).abs() <= 180).toList();
    if (rrClean.length < 4) return null;

    final meanRr = rrClean.reduce((a, b) => a + b) / rrClean.length;
    double hr = (60000.0 / meanRr).clamp(40.0, 180.0);

    // RMSSD with outlier guard
    double sumSq = 0;
    int n = 0;
    for (int i = 1; i < rrClean.length; i++) {
      final d = rrClean[i] - rrClean[i - 1];
      if (d.abs() <= 200) {
        sumSq += d * d;
        n++;
      }
    }
    if (n < 2) return null;

    double hrv = sqrt(sumSq / n).clamp(8.0, 120.0);
    double br = (hr / 5.8).clamp(8.0, 24.0);

    // Exponential smoothing
    hr = _smooth(_prevHr, hr, alpha: 0.25);
    hrv = _smooth(_prevHrv, hrv, alpha: 0.2);
    br = _smooth(_prevBr, br, alpha: 0.25);

    _prevHr = hr;
    _prevHrv = hrv;
    _prevBr = br;

    return VitalsPoint(
      ts: DateTime.now().toUtc(),
      hr: hr,
      hrv: hrv,
      br: br,
    );
  }

  double _smooth(double? prev, double current, {required double alpha}) {
    if (prev == null) return current;
    return prev + alpha * (current - prev);
  }

  Future<void> dispose() async {
    await _outCtrl.close();
  }
}