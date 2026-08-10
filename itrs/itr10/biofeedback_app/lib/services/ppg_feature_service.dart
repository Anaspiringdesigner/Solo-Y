import 'dart:async';
import 'dart:math';
import '../models/ring_sample_packet.dart';
import '../models/vitals_point.dart';

class PpgFeatureService {
  final _outCtrl = StreamController<VitalsPoint>.broadcast();
  Stream<VitalsPoint> get points => _outCtrl.stream;

  final List<RingSamplePacket> _window = [];
  static const int windowMs = 10000; // 10s window

  void addPacket(RingSamplePacket p) {
    _window.add(p);
    final cutoff = p.tsMs - windowMs;
    _window.removeWhere((x) => x.tsMs < cutoff);

    if (_window.length < 50) return; // need enough samples (~1s at 50Hz)

    final point = _computePoint(_window);
    if (point != null) _outCtrl.add(point);
  }

  VitalsPoint? _computePoint(List<RingSamplePacket> w) {
    final xs = w.map((e) => e.ir.toDouble()).toList();
    if (xs.length < 20) return null;

    // crude peak detection
    final peaks = <int>[];
    for (int i = 1; i < xs.length - 1; i++) {
      if (xs[i] > xs[i - 1] && xs[i] > xs[i + 1]) peaks.add(i);
    }
    if (peaks.length < 2) return null;

    final ts = w.map((e) => e.tsMs).toList();
    final rr = <double>[];
    for (int i = 1; i < peaks.length; i++) {
      final dt = (ts[peaks[i]] - ts[peaks[i - 1]]).toDouble();
      if (dt > 300 && dt < 2000) rr.add(dt); // plausible RR ms
    }
    if (rr.isEmpty) return null;

    final meanRr = rr.reduce((a, b) => a + b) / rr.length;
    final hr = 60000.0 / meanRr;

    // RMSSD
    double sumSq = 0;
    for (int i = 1; i < rr.length; i++) {
      final d = rr[i] - rr[i - 1];
      sumSq += d * d;
    }
    final hrv = rr.length > 1 ? sqrt(sumSq / (rr.length - 1)) : 0.0;

    // simple BR proxy
    final br = (hr / 5.5).clamp(6.0, 24.0);

    return VitalsPoint(
      ts: DateTime.now().toUtc(),
      hr: hr.clamp(30.0, 220.0),
      hrv: hrv.clamp(0.0, 300.0),
      br: br,
    );
  }

  Future<void> dispose() async {
    await _outCtrl.close();
  }
} 