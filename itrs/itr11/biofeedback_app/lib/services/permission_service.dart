import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static Future<bool> ensureBlePermissions([BuildContext? context]) async {
    if (!Platform.isAndroid) return true;

    final perms = [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];

    final before = <Permission, PermissionStatus>{};
    for (final p in perms) {
      final s = await p.status;
      before[p] = s;
    }
    debugPrint(
      '[PERM] current statuses: ${before.entries.map((e) => '${e.key}: ${e.value}').join(', ')}',
    );

    final results = <Permission, PermissionStatus>{};
    for (final p in perms) {
      final cur = before[p]!;
      if (cur.isGranted) {
        results[p] = cur;
        continue;
      }

      if (cur.isPermanentlyDenied) {
        results[p] = cur;
        continue;
      }

      try {
        final r = await p.request();
        results[p] = r;
        debugPrint('[PERM] requested $p -> $r');
      } catch (e) {
        debugPrint('[PERM] request error for $p: $e');
        results[p] = cur;
      }
    }

    final ok = results.values.every((s) => s.isGranted);

    if (!ok && context != null) {
      if (!context.mounted) return ok;
      final anyPermanent = results.values.any((s) => s.isPermanentlyDenied);
      try {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Permissions required'),
            content: Text(
              anyPermanent
                  ? 'Bluetooth permissions were permanently denied. Please open App Settings and allow Bluetooth and Location permissions so the app can connect to the sensor.'
                  : 'This app needs Bluetooth and location permissions to connect to your sensor. Please grant them in the dialog.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
              if (anyPermanent)
                TextButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await openAppSettings();
                  },
                  child: const Text('Open Settings'),
                ),
            ],
          ),
        );
      } catch (_) {}
    }

    debugPrint(
      '[PERM] final statuses: ${results.entries.map((e) => '${e.key}: ${e.value}').join(', ')}',
    );

    return ok;
  }
}