import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sensor_selection_screen.dart';
import 'home_screen.dart';

class StartupRouter extends StatefulWidget {
  const StartupRouter({super.key});

  @override
  State<StartupRouter> createState() => _StartupRouterState();
}

class _StartupRouterState extends State<StartupRouter> {
  Future<String?> _getChoice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final val = prefs.getString('sensor_type');
      debugPrint('[STARTUP] sensor_type from prefs: $val');
      // Treat empty string as not set
      if (val != null && val.trim().isEmpty) return null;
      return val;
    } catch (e) {
      debugPrint('[STARTUP] error reading prefs: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _getChoice(),
      builder: (context, snap) {
        debugPrint('[STARTUP] FutureBuilder state: ${snap.connectionState}');
        if (snap.hasError) debugPrint('[STARTUP] prefs future error: ${snap.error}');
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final val = snap.data;
        debugPrint('[STARTUP] FutureBuilder result sensor_type: $val');
        if (val == null) return const SensorSelectionScreen();
        return const HomeScreen();
      },
    );
  }
}
