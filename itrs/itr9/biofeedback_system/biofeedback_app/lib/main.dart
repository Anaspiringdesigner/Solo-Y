import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:permission_handler/permission_handler.dart';
import 'providers/biofeedback_provider.dart';
import 'screens/home_screen.dart';
import 'services/data_transfer_service.dart';
import 'constants.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Initialize background service
  await DataTransferService.initialize();

  runApp(const BiofeedbackApp());
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
            primary: const Color(AppConstants.accentColor),
            surface: const Color(AppConstants.surfaceColor),
          ),
          scaffoldBackgroundColor:
              const Color(AppConstants.bgColor),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}