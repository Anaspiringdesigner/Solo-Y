import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

class AppConstants {
  static const String appEnv = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'dev',
  );

  // IMPORTANT:
  // - Android emulator should use 10.0.2.2
  // - Physical phone should use your PC LAN IP (override via --dart-define)
  static String get apiBaseUrl {
    const envUrl = String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: '',
    );
    if (envUrl.isNotEmpty) return envUrl;

    if (kIsWeb) return 'http://127.0.0.1:8000';
    if (Platform.isAndroid) return 'http://10.0.2.2:8000';
    return 'http://127.0.0.1:8000';
  }

  static const String whepBaseUrl = String.fromEnvironment(
    'WHEP_BASE_URL',
    defaultValue: 'http://100.67.125.12:8889/live/whep',
  );

  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue:
        '760908125337-sfppi17rht5mkv6ckcm28q2g25r5ru5i.apps.googleusercontent.com',
  );

  static const bool enableCalendar = bool.fromEnvironment(
    'ENABLE_CALENDAR',
    defaultValue: true,
  );

  static const bool enableCameraInteraction = bool.fromEnvironment(
    'ENABLE_CAMERA_INTERACTION',
    defaultValue: true,
  );

  static const bool useMockRing = bool.fromEnvironment(
    'USE_MOCK_RING',
    defaultValue: true,
  );

  static const int statusPollMs = 2000;
  static const int httpTimeoutSec = 12;

  static const int calendarLookAheadMin = 5;
  static const int triggerStreamDurationSec = 180;

  static const List<String> interactionNames = [
    'Idle',
    'Breathing',
    'Visual',
    'Camera',
  ];

  static const List<String> interactionIcons = [
    '○',
    '◔',
    '◈',
    '◉',
  ];

  static const int bgColor = 0xFF0C0F14;
  static const int surfaceColor = 0xFF171C24;
  static const int cardBorder = 0xFF2A3140;
  static const int textPrimary = 0xFFE8ECF2;
  static const int textSecondary = 0xFF97A3B6;
  static const int accentColor = 0xFF6EA8FE;
  static const int calmColor = 0xFF4CD97B;
  static const int stressColor = 0xFFFF6B6B;

  static bool get isProd => appEnv.toLowerCase() == 'prod';
  static bool get isDev => !isProd;
}