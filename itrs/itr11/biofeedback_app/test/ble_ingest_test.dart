import 'package:flutter_test/flutter_test.dart';
import 'package:biofeedback_app/services/ble_ingest_service.dart';

void main() {
  test('detectPeaksFromSamples finds synthetic peaks', () {
    // synthetic signal: three peaks at indices 100, 300, 700 with timestamps
    final xs = List<int>.generate(1000, (i) => i * 10); // 10ms sampling
    final ys = List<double>.filled(1000, 0.0);

    // create peaks
    ys[100] = 100.0;
    ys[300] = 110.0;
    ys[700] = 120.0;

    final peaks = detectPeaksFromSamples(xs, ys);
    expect(peaks.isNotEmpty, true);
    // ensure near expected timestamps
    expect(peaks.any((t) => (t - xs[100]).abs() < 5), true);
    expect(peaks.any((t) => (t - xs[300]).abs() < 5), true);
    expect(peaks.any((t) => (t - xs[700]).abs() < 5), true);
  });
}
