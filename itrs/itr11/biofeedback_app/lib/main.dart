import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/permission_service.dart';
import 'providers/biofeedback_provider.dart';
import 'screens/startup_router.dart';
import 'services/data_transfer_service.dart';
import 'constants.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // If user previously selected ESP sensor, request BLE/location permissions
  try {
    final prefs = await SharedPreferences.getInstance();
    final sensor = prefs.getString('sensor_type') ?? '';
    if (sensor.trim().toLowerCase().startsWith('esp')) {
      debugPrint('[MAIN] ESP sensor selected — requesting BLE permissions');
      // don't pass a context here (we're pre-run), permission handler will show system dialogs
      final ok = await PermissionService.ensureBlePermissions();
      debugPrint('[MAIN] BLE permission result: $ok');
    }
  } catch (e) {
    debugPrint('[MAIN] prefs read error: $e');
  }

  debugPrint('[MAIN] DataTransferService.initialize() starting');
  await DataTransferService.initialize();
  debugPrint('[MAIN] DataTransferService.initialize() done');
  runApp(const BiofeedbackApp());
  debugPrint('[MAIN] runApp completed');
}

class BiofeedbackApp extends StatelessWidget {
  const BiofeedbackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => BiofeedbackProvider(),
        ),
      ],
      child: MaterialApp(
        title:                      'Biofeedback',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.dark(
            primary: const Color(
                AppConstants.accentColor),
            surface: const Color(
                AppConstants.surfaceColor),
          ),
          scaffoldBackgroundColor:
              const Color(AppConstants.bgColor),
          useMaterial3: true,
        ),
        home: const StartupRouter(),
      ),
    );
  }
}