import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';
import 'services/scraper_service.dart';
import 'services/verse_storage_service.dart';
import 'screens/home_screen.dart';

/// ── Background task name ──────────────────────────────────────────────────────
const String _dailyFetchTask = 'dailyVerseFetch';

/// ── Workmanager callback (runs in background at sunrise) ─────────────────────
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == _dailyFetchTask) {
      final storage = VerseStorageService();
      final scraper = ScraperService();

      // Only fetch if we don't already have today's verse
      if (!await storage.hasTodayVerse()) {
        final verse = await scraper.fetchRandomVerse();
        if (verse != null) {
          await storage.saveTodayVerse(verse);
        }
      }
    }
    return Future.value(true);
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Initialise background worker
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

  // Schedule daily fetch at ~6 AM (approximate sunrise)
  await Workmanager().registerPeriodicTask(
    _dailyFetchTask,
    _dailyFetchTask,
    frequency: const Duration(hours: 24),
    initialDelay: _timeUntilNextSunrise(),
    constraints: Constraints(
      networkType: NetworkType.connected,
    ),
    existingWorkPolicy: ExistingWorkPolicy.keep,
  );

  runApp(const TeluguBhagavatamApp());
}

/// ── Calculate delay until ~6 AM tomorrow ─────────────────────────────────────
Duration _timeUntilNextSunrise() {
  final now = DateTime.now();
  var sunrise = DateTime(now.year, now.month, now.day, 6, 0);
  if (now.isAfter(sunrise)) {
    sunrise = sunrise.add(const Duration(days: 1));
  }
  return sunrise.difference(now);
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