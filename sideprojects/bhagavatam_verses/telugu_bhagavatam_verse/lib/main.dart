import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';
import 'services/scraper_service.dart';
import 'services/verse_storage_service.dart';
import 'services/sunrise_service.dart';
import 'services/location_service.dart';
import 'screens/home_screen.dart';

const String _dailyFetchTask = 'dailyVerseFetch';

/// Background callback — uses cached coordinates since GPS
/// permission dialogs cannot appear in background tasks.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == _dailyFetchTask) {
      final storage = VerseStorageService();
      final scraper = ScraperService();
      if (!await storage.hasTodayVerse()) {
        final verse = await scraper.fetchRandomVerse();
        if (verse != null) await storage.saveTodayVerse(verse);
      }
    }
    return Future.value(true);
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

  // Get real GPS coordinates in foreground so permission dialog can appear
  final locationService = LocationService();
  final coords = await locationService.getCurrentLocation();

  // Calculate exact sunrise delay from real coordinates
  final delayUntilSunrise = SunriseService.durationUntilNextSunrise(
    latitude: coords.latitude,
    longitude: coords.longitude,
  );

  // Schedule daily background fetch to fire at exact local sunrise
  await Workmanager().registerPeriodicTask(
    _dailyFetchTask,
    _dailyFetchTask,
    frequency: const Duration(hours: 24),
    initialDelay: delayUntilSunrise,
    constraints: Constraints(
      networkType: NetworkType.connected,
    ),
    // Replace ensures sunrise time recalculates on every app launch
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );

  runApp(const TeluguBhagavatamApp());
}

class TeluguBhagavatamApp extends StatelessWidget {
  const TeluguBhagavatamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'తెలుగు భాగవతం',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFFFF8C00),
          secondary: const Color(0xFFFFD580),
          surface: const Color(0xFF1A0800),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0D0500),
      ),
      home: const HomeScreen(),
    );
  }
}