import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../services/data_transfer_service.dart';
import '../services/ble_ingest_service.dart';
import '../services/permission_service.dart';
import 'home_screen.dart';

class SensorSelectionScreen extends StatefulWidget {
  const SensorSelectionScreen({super.key});

  @override
  State<SensorSelectionScreen> createState() => _SensorSelectionScreenState();
}

class _SensorSelectionScreenState extends State<SensorSelectionScreen> {
  String? _choice;
  bool _saving = false;

  Future<void> _saveChoice(String choice) async {
    setState(() => _saving = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sensor_type', choice);

    try {
      if (choice == 'polar') {
        await DataTransferService.start();
        // notify background service to reload sensor type
        final service = FlutterBackgroundService();
        try {
          service.invoke('reload_sensor', {'sensor_type': choice});
        } catch (_) {}
      } else {
        // ensure permissions first
        final ok = await PermissionService.ensureBlePermissions(context);
        if (!ok) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Bluetooth permissions required to use ESP32 sensor'),
            ));
          }
        }

        // start BLE ingest and DataTransfer so existing pipeline continues
        if (ok) {
          await BleIngestService().start();
        }
        await DataTransferService.start();
        final service = FlutterBackgroundService();
        try {
          service.invoke('reload_sensor', {'sensor_type': choice});
        } catch (_) {}
      }
    } catch (e) {
      // ignore errors but show a snackbar if still mounted
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Start error: $e'),
        ));
      }
    }

    setState(() => _saving = false);
    // Navigate to home (replace)
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  void initState() {
    super.initState();
    debugPrint('[SELECTION] SensorSelectionScreen.initState');
    // load existing choice if any and auto-navigate
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final stored = prefs.getString('sensor_type');
        debugPrint('[SELECTION] stored sensor_type: $stored');
        if (stored != null) {
          if (stored == 'polar') {
            await DataTransferService.start();
          } else {
            // ensure BLE permissions before starting
            final ok = await PermissionService.ensureBlePermissions();
            if (ok) {
              await BleIngestService().start();
            }
            await DataTransferService.start();
          }
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const HomeScreen()));
        }
      } catch (e) {
        debugPrint('[SELECTION] prefs read error: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Sensor')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Which sensor will you use?',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            RadioListTile<String>(
              title: const Text('Polar H10 (file-based)'),
              value: 'polar',
              groupValue: _choice,
              onChanged: (v) => setState(() => _choice = v),
            ),
            RadioListTile<String>(
              title: const Text('ESP32-MAX30102 (BLE streaming)'),
              value: 'esp32',
              groupValue: _choice,
              onChanged: (v) => setState(() => _choice = v),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: (_choice == null || _saving)
                  ? null
                  : () => _saveChoice(_choice!),
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save and continue'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () async {
                // allow user to clear choice
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove('sensor_type');
                setState(() => _choice = null);
              },
              child: const Text('Clear saved choice'),
            ),
          ],
        ),
      ),
    );
  }
}
