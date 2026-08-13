import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../constants.dart';
import '../services/ble_ingest_service.dart';
import '../services/data_transfer_service.dart';
import '../services/permission_service.dart';
import 'home_screen.dart';

class SensorSelectionScreen extends StatefulWidget {
  const SensorSelectionScreen({super.key});

  @override
  State<SensorSelectionScreen> createState() => _SensorSelectionScreenState();
}

class _SensorSelectionScreenState extends State<SensorSelectionScreen> {
  bool _saving = false;

  Future<void> _saveChoice(String choice) async {
    if (_saving) return;
    setState(() => _saving = true);

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sensor_type', choice);

      if (choice == 'esp32') {
        final ok = await PermissionService.ensureBlePermissions(context);
        if (!mounted) return;
        if (!ok) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Bluetooth permissions are required for ESP32 sensor'),
            ),
          );
          setState(() => _saving = false);
          return;
        }
        await BleIngestService().start();
      } else {
        await BleIngestService().stop();
      }

      await DataTransferService.start();
      try {
        FlutterBackgroundService().invoke('reload_sensor', {'sensor_type': choice});
      } catch (_) {}

      if (!mounted) return;
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Setup error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Widget _sensorCard({
    required String title,
    required String subtitle,
    required String emoji,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _saving ? null : onTap,
        child: Container(
          width: 320,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(AppConstants.surfaceColor),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(AppConstants.cardBorder)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(AppConstants.accentColor).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 26)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.inter(
                        color: const Color(AppConstants.textPrimary),
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: GoogleFonts.inter(
                        color: const Color(AppConstants.textSecondary),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.arrow_forward_ios_rounded, color: Color(AppConstants.textSecondary), size: 18),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppConstants.bgColor),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'BIOFEEDBACK',
                  style: GoogleFonts.inter(
                    color: const Color(AppConstants.accentColor),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2.2,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Select Sensor',
                  style: GoogleFonts.inter(
                    color: const Color(AppConstants.textPrimary),
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Choose the sensor source for live vitals and background transfer.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    color: const Color(AppConstants.textSecondary),
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 28),
                _sensorCard(
                  title: 'Polar H10',
                  subtitle: 'Use existing file-based Polar vitals import.',
                  emoji: '❤️',
                  onTap: () => _saveChoice('polar'),
                ),
                const SizedBox(height: 16),
                _sensorCard(
                  title: 'ESP32 MAX30102',
                  subtitle: 'Use Bluetooth streaming from the ESP32 ring sensor.',
                  emoji: '📡',
                  onTap: () => _saveChoice('esp32'),
                ),
                const SizedBox(height: 24),
                if (_saving)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Color(AppConstants.accentColor),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
