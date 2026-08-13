import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import 'ble_ingest_service.dart';

const String polarDir = '/sdcard/Download/Data_from_H10';
const int pollIntervalSec = 5;
const int windowSeconds = 30;
const int strideSeconds = 5;
const int recentMinutes = 20;
const int staleMinutes = 3;

class DataTransferService {
  static final DataTransferService _instance = DataTransferService._internal();
  factory DataTransferService() => _instance;
  DataTransferService._internal();

  static Future<void> initialize() async {
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'biofeedback_data_transfer',
        initialNotificationTitle: 'Biofeedback',
        initialNotificationContent: 'Ready to transfer data',
        foregroundServiceNotificationId: 888,
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  static Future<void> start() async {
    final service = FlutterBackgroundService();
    final running = await service.isRunning();
    if (!running) {
      await service.startService();
    }
  }

  static Future<void> stop() async {
    FlutterBackgroundService().invoke('stop');
  }

  static Future<bool> isRunning() async {
    return FlutterBackgroundService().isRunning();
  }
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async => true;

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  final Map<String, String> fileHashes = {};
  final Map<String, String> lastPostedEnd = {};
  String sensorType = '';

  debugPrint('[BG] Data transfer service started');

  void updateNotification(String content) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Biofeedback Data Transfer',
        content: content,
      );
    }
  }

  Future<void> syncSensorType(String newType) async {
    sensorType = newType.trim().toLowerCase();
    fileHashes.clear();
    lastPostedEnd.clear();
    debugPrint('[BG] sensor type -> $sensorType');

    try {
      if (sensorType.startsWith('esp')) {
        final scan = await Permission.bluetoothScan.status;
        final connect = await Permission.bluetoothConnect.status;
        final loc = await Permission.locationWhenInUse.status;
        if (scan.isGranted && connect.isGranted && loc.isGranted) {
          await BleIngestService().start();
          updateNotification('ESP32 active');
        } else {
          updateNotification('BLE permissions needed for ESP32');
        }
      } else {
        await BleIngestService().stop();
        updateNotification(sensorType == 'polar' ? 'Polar active' : 'Select a sensor');
      }
    } catch (e) {
      debugPrint('[BG] sync sensor type error: $e');
      updateNotification('Sensor init error');
    }
  }

  service.on('stop').listen((_) async {
    try {
      await BleIngestService().stop();
    } catch (_) {}
    service.stopSelf();
  });

  service.on('reload_sensor').listen((event) async {
    try {
      final Map<String, dynamic> eventMap =
          event is Map ? Map<String, dynamic>.from(event as Map) : const <String, dynamic>{};
      final dynamic sensorValue = eventMap['sensor_type'] ?? '';
      await syncSensorType(sensorValue.toString());
    } catch (e) {
      debugPrint('[BG] reload_sensor error: $e');
    }
  });

  try {
    final prefs = await SharedPreferences.getInstance();
    await syncSensorType(prefs.getString('sensor_type') ?? '');
  } catch (e) {
    debugPrint('[BG] initial prefs read error: $e');
    updateNotification('Waiting for sensor selection');
  }

  Timer.periodic(const Duration(seconds: pollIntervalSec), (timer) async {
    try {
      final manageStatus = await Permission.manageExternalStorage.status;
      final storageStatus = await Permission.storage.status;
      if (!manageStatus.isGranted && !storageStatus.isGranted) {
        updateNotification('Storage permission needed');
        return;
      }

      final dir = Directory(polarDir);
      if (!await dir.exists()) {
        updateNotification('Data folder not found');
        return;
      }

      final patterns = sensorType.startsWith('esp')
          ? <String>['_esp.txt']
          : sensorType == 'polar'
              ? <String>['_HR.txt']
              : <String>['_esp.txt', '_HR.txt'];

      final files = <String>[];
      await for (final f in dir.list()) {
        final path = f.path;
        if (patterns.any(path.endsWith)) {
          files.add(path);
        }
      }

      if (files.isEmpty) {
        updateNotification(
          sensorType.startsWith('esp') ? 'Waiting for ESP32 vitals file' : 'No vitals files found',
        );
        return;
      }

      files.sort();
      final newestFile = files.last;
      final file = File(newestFile);
      final stat = await file.stat();
      final fname = newestFile.split('/').last;
      final hash = '${stat.modified.millisecondsSinceEpoch}_${stat.size}';

      if (fileHashes[fname] == hash) return;
      fileHashes[fname] = hash;

      final text = await file.readAsString();
      final rows = _parseVitalsFile(text);
      if (rows.isEmpty) {
        updateNotification('No valid rows in $fname');
        return;
      }

      final cutoff = DateTime.now().subtract(const Duration(minutes: recentMinutes));
      final recent = rows.where((r) => r.timestamp.isAfter(cutoff)).toList();
      if (recent.isEmpty) {
        updateNotification('Only stale rows in $fname');
        return;
      }

      final resampled = _resampleTo1s(recent);
      if (resampled.isEmpty) {
        updateNotification('Resample failed for $fname');
        return;
      }

      final windows = _buildWindows(resampled);
      if (windows.isEmpty) {
        updateNotification('Need more data for 30s window');
        return;
      }

      final lastEnd = lastPostedEnd[fname] ?? '';
      final newWindows = lastEnd.isEmpty
          ? windows
          : windows.where((w) => w.endTime.compareTo(lastEnd) > 0).toList();
      if (newWindows.isEmpty) return;

      final staleCutoff = DateTime.now().subtract(const Duration(minutes: staleMinutes));
      final fresh = newWindows.where((w) => DateTime.parse(w.endTime).isAfter(staleCutoff)).toList();
      if (fresh.isEmpty) {
        updateNotification('Skipping stale windows');
        return;
      }

      final ok = await _postWindows(fresh);
      if (ok) {
        lastPostedEnd[fname] = fresh.last.endTime;
        updateNotification('Posted ${fresh.length} windows | HR=${fresh.last.avgHr.toStringAsFixed(0)}');
      } else {
        updateNotification('Post failed');
      }
    } catch (e) {
      debugPrint('[BG ERROR] $e');
      updateNotification('Error: $e');
    }
  });
}

class _HRRow {
  final DateTime timestamp;
  final double hr;
  final double hrv;
  final double br;
  _HRRow(this.timestamp, this.hr, this.hrv, this.br);
}

class _Window {
  final String startTime;
  final String endTime;
  final List<double> hr;
  final List<double> hrv;
  final List<double> br;
  final double avgHr;
  final double avgHrv;
  final double avgBr;

  _Window({
    required this.startTime,
    required this.endTime,
    required this.hr,
    required this.hrv,
    required this.br,
    required this.avgHr,
    required this.avgHrv,
    required this.avgBr,
  });

  Map<String, dynamic> toJson() => {
        'start_time': startTime,
        'end_time': endTime,
        'hr': hr,
        'hrv': hrv,
        'br': br,
        'avg_hr': avgHr,
        'avg_hrv': avgHrv,
        'avg_br': avgBr,
      };
}

List<_HRRow> _parseVitalsFile(String content) {
  final rows = <_HRRow>[];
  final lines = content.split('\n');

  for (final line in lines) {
    final l = line.trim();
    if (l.isEmpty) continue;
    if (l.startsWith('Phone timestamp')) continue;
    if (l.startsWith('Polar_H10')) continue;
    if (l.toLowerCase().startsWith('timestamp;hr;hrv;br')) continue;

    final parts = l.split(';');
    if (parts.length < 2) continue;

    try {
      final ts = DateTime.parse(parts[0].trim());
      final hr = parts.length > 1 && parts[1].trim().isNotEmpty
          ? double.parse(parts[1].trim())
          : double.nan;
      final hrv = parts.length > 2 && parts[2].trim().isNotEmpty
          ? double.parse(parts[2].trim())
          : double.nan;
      final br = parts.length > 3 && parts[3].trim().isNotEmpty
          ? double.parse(parts[3].trim())
          : double.nan;

      if (hr.isNaN || hr < 30 || hr > 220) {
        continue;
      }

      rows.add(_HRRow(
        ts,
        hr,
        hrv.isNaN || hrv < 1 || hrv > 250 ? double.nan : hrv,
        br.isNaN || br < 4 || br > 60 ? double.nan : br,
      ));
    } catch (_) {
      continue;
    }
  }

  rows.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return rows;
}

List<_HRRow> _resampleTo1s(List<_HRRow> rows) {
  if (rows.isEmpty) return [];

  final start = rows.first.timestamp;
  final end = rows.last.timestamp;
  final secs = end.difference(start).inSeconds + 1;
  if (secs <= 0) return [];

  final hrGrid = List<double>.filled(secs, double.nan);
  final hrvGrid = List<double>.filled(secs, double.nan);
  final brGrid = List<double>.filled(secs, double.nan);

  for (final row in rows) {
    final idx = row.timestamp.difference(start).inSeconds.clamp(0, secs - 1);
    hrGrid[idx] = row.hr;
    hrvGrid[idx] = row.hrv;
    brGrid[idx] = row.br;
  }

  _interpolate(hrGrid, 10);

  final hrvNanCount = hrvGrid.where((v) => v.isNaN).length;
  if (hrvNanCount / secs > 0.5) {
    _estimateHRV(hrGrid, hrvGrid);
  }
  _interpolate(hrvGrid, 20);

  final brNanCount = brGrid.where((v) => v.isNaN).length;
  if (brNanCount / secs > 0.5) {
    _estimateBR(hrGrid, brGrid);
  }
  _interpolate(brGrid, 20);

  final result = <_HRRow>[];
  for (int i = 0; i < secs; i++) {
    if (!hrGrid[i].isNaN && !hrvGrid[i].isNaN && !brGrid[i].isNaN) {
      result.add(_HRRow(
        start.add(Duration(seconds: i)),
        hrGrid[i],
        hrvGrid[i],
        brGrid[i],
      ));
    }
  }
  return result;
}

void _interpolate(List<double> vals, int limit) {
  final n = vals.length;
  int i = 0;
  while (i < n) {
    if (vals[i].isNaN) {
      int j = i;
      while (j < n && vals[j].isNaN) {
        j++;
      }
      final gapLen = j - i;
      if (gapLen <= limit) {
        final left = i > 0 ? vals[i - 1] : double.nan;
        final right = j < n ? vals[j] : double.nan;
        if (!left.isNaN && !right.isNaN) {
          for (int k = i; k < j; k++) {
            final t = (k - i + 1) / (gapLen + 1);
            vals[k] = left + t * (right - left);
          }
        } else if (!left.isNaN) {
          for (int k = i; k < j; k++) {
            vals[k] = left;
          }
        } else if (!right.isNaN) {
          for (int k = i; k < j; k++) {
            vals[k] = right;
          }
        }
      }
      i = j;
    } else {
      i++;
    }
  }
}

void _estimateHRV(List<double> hr, List<double> hrv) {
  const window = 60;

  for (int i = 0; i < hr.length; i++) {
    if (!hrv[i].isNaN) continue;
    final start = (i - window + 1).clamp(0, i);
    final chunk = hr.sublist(start, i + 1).where((v) => !v.isNaN && v > 0).toList();
    if (chunk.length < 6) continue;

    final rr = chunk.map((h) => 60000.0 / h).toList();
    if (rr.length < 6) continue;

    final diffs = <double>[];
    for (int k = 1; k < rr.length; k++) {
      final d = rr[k] - rr[k - 1];
      diffs.add(d);
    }
    if (diffs.length < 5) continue;

    final sq = diffs.map((d) => d * d).toList();
    final meanSq = sq.reduce((a, b) => a + b) / sq.length;
    final rmssd = meanSq > 0 ? math.sqrt(meanSq) : 0.0;
    hrv[i] = rmssd.clamp(5.0, 250.0);
  }
}

void _estimateBR(List<double> hr, List<double> br) {
  const window = 30;
  final smooth = List<double>.filled(hr.length, double.nan);

  for (int i = 0; i < hr.length; i++) {
    final start = (i - window + 1).clamp(0, i);
    final chunk = hr.sublist(start, i + 1).where((v) => !v.isNaN).toList();
    if (chunk.length >= 5) {
      smooth[i] = chunk.reduce((a, b) => a + b) / chunk.length;
    }
  }

  final validSmooth = smooth.where((v) => !v.isNaN).toList();
  if (validSmooth.isEmpty) return;

  validSmooth.sort();
  final hrMin = validSmooth[(validSmooth.length * 0.05).floor()];
  final hrMax = validSmooth[(validSmooth.length * 0.95).floor()];
  final denom = (hrMax - hrMin).abs() < 1e-6 ? 1.0 : hrMax - hrMin;

  for (int i = 0; i < br.length; i++) {
    if (!br[i].isNaN) continue;
    if (smooth[i].isNaN) continue;
    br[i] = (10.0 + (smooth[i] - hrMin) * (10.0 / denom)).clamp(8.0, 24.0);
  }
}

List<_Window> _buildWindows(List<_HRRow> rows) {
  final windows = <_Window>[];
  final n = rows.length;

  if (n < windowSeconds) return windows;

  int s = 0;
  while (s + windowSeconds <= n) {
    final chunk = rows.sublist(s, s + windowSeconds);

    final hrList = chunk.map((r) => r.hr).toList();
    final hrvList = chunk.map((r) => r.hrv).toList();
    final brList = chunk.map((r) => r.br).toList();

    final avgHr = hrList.reduce((a, b) => a + b) / hrList.length;
    final avgHrv = hrvList.reduce((a, b) => a + b) / hrvList.length;
    final avgBr = brList.reduce((a, b) => a + b) / brList.length;

    windows.add(_Window(
      startTime: chunk.first.timestamp.toIso8601String(),
      endTime: chunk.last.timestamp.toIso8601String(),
      hr: hrList,
      hrv: hrvList,
      br: brList,
      avgHr: double.parse(avgHr.toStringAsFixed(1)),
      avgHrv: double.parse(avgHrv.toStringAsFixed(1)),
      avgBr: double.parse(avgBr.toStringAsFixed(1)),
    ));

    s += strideSeconds;
  }

  return windows;
}

Future<bool> _postWindows(List<_Window> windows) async {
  final serverUrl = '${AppConstants.serverBase}/ingest';
  const maxRetries = 3;

  final payload = jsonEncode({
    'windows': windows.map((w) => w.toJson()).toList(),
  });

  for (int attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      final resp = await http
          .post(
            Uri.parse(serverUrl),
            headers: {'Content-Type': 'application/json'},
            body: payload,
          )
          .timeout(const Duration(seconds: 30));

      debugPrint('[BG] POST /ingest -> ${resp.statusCode}');
      if (resp.statusCode == 200) return true;
    } catch (e) {
      debugPrint('[BG POST ERROR] attempt $attempt -> $e');
    }

    if (attempt < maxRetries) {
      final backoffMs = 500 * (1 << (attempt - 1));
      await Future.delayed(Duration(milliseconds: backoffMs));
    }
  }

  return false;
}