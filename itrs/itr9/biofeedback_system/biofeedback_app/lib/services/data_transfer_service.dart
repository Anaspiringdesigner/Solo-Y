// lib/services/data_transfer_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../constants.dart';

// ── Constants ──────────────────────────────────────────────
const String POLAR_DIR =
    '/sdcard/Download/Data_from_H10';
const int    POLL_INTERVAL_SEC  = 5;
const int    WINDOW_SECONDS     = 30;
const int    STRIDE_SECONDS     = 5;
const int    RECENT_MINUTES     = 20;
const int    STALE_MINUTES      = 3;

class DataTransferService {
  static final DataTransferService _instance =
      DataTransferService._internal();
  factory DataTransferService() => _instance;
  DataTransferService._internal();

  // ── Initialize Background Service ──────────────────────
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart:           onStart,
        autoStart:         true,
        isForegroundMode:  true,
        notificationChannelId:
            'biofeedback_data_transfer',
        initialNotificationTitle:
            'Biofeedback',
        initialNotificationContent:
            'Transferring biometric data...',
        foregroundServiceNotificationId: 888,
        foregroundServiceTypes: [
          AndroidForegroundType.dataSync,
        ],
      ),
      iosConfiguration: IosConfiguration(
        autoStart:  true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  // ── Start Service ───────────────────────────────────────
  static Future<void> start() async {
    final service = FlutterBackgroundService();
    await service.startService();
  }

  // ── Stop Service ────────────────────────────────────────
  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    service.invoke('stop');
  }

  // ── Check if Running ────────────────────────────────────
  static Future<bool> isRunning() async {
    final service = FlutterBackgroundService();
    return await service.isRunning();
  }
}

// ── iOS Background Handler ──────────────────────────────────
@pragma('vm:entry-point')
Future<bool> onIosBackground(
    ServiceInstance service) async {
  return true;
}

// ── Main Background Entry Point ─────────────────────────────
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // State tracking
  final Map<String, String> fileHashes     = {};
  final Map<String, String> lastPostedEnd  = {};

  debugPrint('[BG] Data transfer service started');

  // Handle stop command
  service.on('stop').listen((_) {
    service.stopSelf();
    debugPrint('[BG] Service stopped');
  });

  // Update notification helper
  void updateNotification(String content) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title:   'Biofeedback Data Transfer',
        content: content,
      );
    }
  }

  // ── Main polling loop ─────────────────────────────────
  Timer.periodic(
    const Duration(seconds: POLL_INTERVAL_SEC),
    (timer) async {
      try {
        // Check storage permission
        final status =
            await Permission.manageExternalStorage
                .status;
        if (!status.isGranted) {
          updateNotification(
              'Storage permission needed');
          return;
        }

        // List HR files
        final dir = Directory(POLAR_DIR);
        if (!await dir.exists()) {
          updateNotification(
              'Polar data folder not found');
          return;
        }

        final files = await dir
            .list()
            .where((f) =>
                f.path.endsWith('_HR.txt'))
            .map((f) => f.path)
            .toList();

        if (files.isEmpty) {
          updateNotification('No HR files found');
          return;
        }

        // Sort and get newest file
        files.sort();
        final newestFile = files.last;
        final fname      = newestFile
            .split('/')
            .last;

        // Check if file changed (hash)
        final file    = File(newestFile);
        final content = await file.readAsBytes();
        final hash    = content.length.toString() +
                        content.last.toString();

        if (fileHashes[fname] == hash) return;
        fileHashes[fname] = hash;

        debugPrint('[BG] Updated: $fname');
        updateNotification('Reading: $fname');

        // Parse file
        final text  = await file.readAsString();
        final rows  = _parseHRFile(text);
        if (rows.isEmpty) return;

        // Filter recent data
        final cutoff = DateTime.now()
            .subtract(Duration(minutes: RECENT_MINUTES));
        final recent = rows
            .where((r) => r.timestamp.isAfter(cutoff))
            .toList();
        if (recent.isEmpty) return;

        // Resample + interpolate
        final resampled = _resampleTo1s(recent);
        if (resampled.isEmpty) return;

        // Build windows
        final windows = _buildWindows(resampled);
        if (windows.isEmpty) return;

        // Filter new windows
        final lastEnd = lastPostedEnd[fname] ?? '';
        final newWindows = lastEnd.isEmpty
            ? windows
            : windows
                .where((w) => w.endTime > lastEnd)
                .toList();
        if (newWindows.isEmpty) return;

        // Filter stale windows
        final staleCutoff = DateTime.now()
            .subtract(Duration(minutes: STALE_MINUTES));
        final fresh = newWindows
            .where((w) {
              final wEnd = DateTime.parse(w.endTime);
              return wEnd.isAfter(staleCutoff);
            })
            .toList();
        if (fresh.isEmpty) return;

        // POST to Julia server
        final ok = await _postWindows(fresh);
        if (ok) {
          lastPostedEnd[fname] =
              fresh.last.endTime;
          updateNotification(
              'Posted ${fresh.length} windows | '
              'HR=${fresh.last.avgHr.toStringAsFixed(0)}');
          debugPrint('[BG] Posted '
              '${fresh.length} windows');
        }

      } catch (e) {
        debugPrint('[BG ERROR] $e');
        updateNotification('Error: $e');
      }
    },
  );
}

// ── Data Row ─────────────────────────────────────────────────
class _HRRow {
  final DateTime timestamp;
  final double   hr;
  final double   hrv;
  final double   br;
  _HRRow(this.timestamp, this.hr, this.hrv, this.br);
}

// ── Window ───────────────────────────────────────────────────
class _Window {
  final String        startTime;
  final String        endTime;
  final List<double>  hr;
  final List<double>  hrv;
  final List<double>  br;
  final double        avgHr;
  final double        avgHrv;
  final double        avgBr;

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
    'end_time':   endTime,
    'hr':         hr,
    'hrv':        hrv,
    'br':         br,
    'avg_hr':     avgHr,
    'avg_hrv':    avgHrv,
    'avg_br':     avgBr,
  };
}

// ── Parse HR File ─────────────────────────────────────────────
List<_HRRow> _parseHRFile(String content) {
  final rows  = <_HRRow>[];
  final lines = content.split('\n');

  for (final line in lines) {
    final l = line.trim();
    if (l.isEmpty) continue;
    if (l.startsWith('Phone timestamp')) continue;
    if (l.startsWith('Polar_H10')) continue;

    final parts = l.split(';');
    if (parts.length < 2) continue;

    try {
      final ts  = DateTime.parse(parts[0].trim());
      final hr  = parts.length > 1 &&
                  parts[1].trim().isNotEmpty
          ? double.parse(parts[1].trim())
          : double.nan;
      final hrv = parts.length > 2 &&
                  parts[2].trim().isNotEmpty
          ? double.parse(parts[2].trim())
          : double.nan;
      final br  = parts.length > 3 &&
                  parts[3].trim().isNotEmpty
          ? double.parse(parts[3].trim())
          : double.nan;

      if (hr.isNaN) continue;
      if (hr < 30 || hr > 220) continue;

      rows.add(_HRRow(
        ts,
        hr,
        hrv.isNaN || hrv < 1 || hrv > 250
            ? double.nan
            : hrv,
        br.isNaN || br < 4 || br > 60
            ? double.nan
            : br,
      ));
    } catch (_) {
      continue;
    }
  }

  rows.sort((a, b) =>
      a.timestamp.compareTo(b.timestamp));
  return rows;
}

// ── Resample to 1s Grid ───────────────────────────────────────
List<_HRRow> _resampleTo1s(List<_HRRow> rows) {
  if (rows.isEmpty) return [];

  final start = rows.first.timestamp;
  final end   = rows.last.timestamp;
  final secs  = end.difference(start).inSeconds + 1;
  if (secs <= 0) return [];

  // Build 1s grid
  final hrGrid  = List<double>.filled(secs, double.nan);
  final hrvGrid = List<double>.filled(secs, double.nan);
  final brGrid  = List<double>.filled(secs, double.nan);

  for (final row in rows) {
    final idx = row.timestamp
        .difference(start)
        .inSeconds
        .clamp(0, secs - 1);
    hrGrid[idx]  = row.hr;
    hrvGrid[idx] = row.hrv;
    brGrid[idx]  = row.br;
  }

  // Interpolate HR (limit 10)
  _interpolate(hrGrid, 10);

  // Estimate + interpolate HRV
  final hrvNanCount =
      hrvGrid.where((v) => v.isNaN).length;
  if (hrvNanCount / secs > 0.5) {
    _estimateHRV(hrGrid, hrvGrid);
  }
  _interpolate(hrvGrid, 20);

  // Estimate + interpolate BR
  final brNanCount =
      brGrid.where((v) => v.isNaN).length;
  if (brNanCount / secs > 0.5) {
    _estimateBR(hrGrid, brGrid);
  }
  _interpolate(brGrid, 20);

  // Build result
  final result = <_HRRow>[];
  for (int i = 0; i < secs; i++) {
    if (!hrGrid[i].isNaN &&
        !hrvGrid[i].isNaN &&
        !brGrid[i].isNaN) {
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

// ── Interpolation ─────────────────────────────────────────────
void _interpolate(List<double> vals, int limit) {
  final n = vals.length;
  int i   = 0;
  while (i < n) {
    if (vals[i].isNaN) {
      int j = i;
      while (j < n && vals[j].isNaN) j++;
      final gapLen = j - i;
      if (gapLen <= limit) {
        final left  = i > 0 ? vals[i - 1] : double.nan;
        final right = j < n ? vals[j]      : double.nan;
        if (!left.isNaN && !right.isNaN) {
          for (int k = i; k < j; k++) {
            final t = (k - i + 1) / (gapLen + 1);
            vals[k] = left + t * (right - left);
          }
        } else if (!left.isNaN) {
          for (int k = i; k < j; k++) vals[k] = left;
        } else if (!right.isNaN) {
          for (int k = i; k < j; k++) vals[k] = right;
        }
      }
      i = j;
    } else {
      i++;
    }
  }
}

// ── HRV Estimation ────────────────────────────────────────────
void _estimateHRV(
    List<double> hr, List<double> hrv) {
  const window = 60;
  for (int i = 0; i < hr.length; i++) {
    if (!hrv[i].isNaN) continue;
    final start = (i - window + 1).clamp(0, i);
    final chunk = hr
        .sublist(start, i + 1)
        .where((v) => !v.isNaN)
        .toList();
    if (chunk.length < 10) continue;
    final mean = chunk.reduce((a, b) => a + b) /
                 chunk.length;
    final variance = chunk
            .map((v) => (v - mean) * (v - mean))
            .reduce((a, b) => a + b) /
        chunk.length;
    final std = variance > 0
        ? variance / variance * (variance.abs())
        : 0.0;
    hrv[i] = (std * 12.0).clamp(5.0, 120.0);
  }
}

// ── BR Estimation ─────────────────────────────────────────────
void _estimateBR(
    List<double> hr, List<double> br) {
  const window = 30;
  final smooth = List<double>.filled(
      hr.length, double.nan);

  for (int i = 0; i < hr.length; i++) {
    final start = (i - window + 1).clamp(0, i);
    final chunk = hr
        .sublist(start, i + 1)
        .where((v) => !v.isNaN)
        .toList();
    if (chunk.length >= 5) {
      smooth[i] = chunk.reduce((a, b) => a + b) /
                  chunk.length;
    }
  }

  final validSmooth =
      smooth.where((v) => !v.isNaN).toList();
  if (validSmooth.isEmpty) return;

  validSmooth.sort();
  final hrMin =
      validSmooth[(validSmooth.length * 0.05).floor()];
  final hrMax =
      validSmooth[(validSmooth.length * 0.95).floor()];
  final denom = (hrMax - hrMin).abs() < 1e-6
      ? 1.0
      : hrMax - hrMin;

  for (int i = 0; i < br.length; i++) {
    if (!br[i].isNaN) continue;
    if (smooth[i].isNaN) continue;
    br[i] = (10.0 +
              (smooth[i] - hrMin) * (10.0 / denom))
        .clamp(8.0, 24.0);
  }
}

// ── Build Windows ─────────────────────────────────────────────
List<_Window> _buildWindows(List<_HRRow> rows) {
  final windows = <_Window>[];
  final n       = rows.length;

  if (n < WINDOW_SECONDS) return windows;

  int s = 0;
  while (s + WINDOW_SECONDS <= n) {
    final chunk = rows.sublist(s, s + WINDOW_SECONDS);

    final hrList  = chunk.map((r) => r.hr).toList();
    final hrvList = chunk.map((r) => r.hrv).toList();
    final brList  = chunk.map((r) => r.br).toList();

    final avgHr  = hrList.reduce((a, b) => a + b) /
                   hrList.length;
    final avgHrv = hrvList.reduce((a, b) => a + b) /
                   hrvList.length;
    final avgBr  = brList.reduce((a, b) => a + b) /
                   brList.length;

    windows.add(_Window(
      startTime: chunk.first.timestamp.toIso8601String(),
      endTime:   chunk.last.timestamp.toIso8601String(),
      hr:        hrList,
      hrv:       hrvList,
      br:        brList,
      avgHr:     double.parse(avgHr.toStringAsFixed(1)),
      avgHrv:    double.parse(avgHrv.toStringAsFixed(1)),
      avgBr:     double.parse(avgBr.toStringAsFixed(1)),
    ));

    s += STRIDE_SECONDS;
  }

  return windows;
}

// ── POST Windows to Julia ─────────────────────────────────────
Future<bool> _postWindows(List<_Window> windows) async {
  try {
    final payload = jsonEncode({
      'windows': windows.map((w) => w.toJson()).toList(),
    });

    final resp = await http
        .post(
          Uri.parse('${AppConstants.serverBase}/ingest'),
          headers: {
            'Content-Type': 'application/json',
          },
          body: payload,
        )
        .timeout(const Duration(seconds: 20));

    return resp.statusCode == 200;
  } catch (e) {
    debugPrint('[BG POST ERROR] $e');
    return false;
  }
}