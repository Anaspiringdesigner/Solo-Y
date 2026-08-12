import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  /// Ensure BLE & location permissions required on Android are granted.
  /// Returns true if permissions are granted or not required on platform.
  static Future<bool> ensureBlePermissions([BuildContext? context]) async {
    if (!Platform.isAndroid) return true;

    // Request modern Bluetooth + location permissions needed for scanning
    final Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    bool ok = statuses.values.every((s) => s.isGranted);

    if (!ok && context != null) {
      // Show a user-friendly dialog asking them to enable permissions
      try {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Permissions required'),
            content: const Text(
              'This app needs Bluetooth and location permissions to connect to your sensor.\n\n'
              'Please grant the permissions in the dialog or open App Settings to enable them.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
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

    return ok;
  }
}
