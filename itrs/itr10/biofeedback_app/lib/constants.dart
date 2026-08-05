import 'package:flutter/material.dart';

class AppConstants {
  // ===== API / Media =====
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  static const String whepHost = String.fromEnvironment(
    'WHEP_HOST',
    defaultValue: '100.67.125.12',
  );

  static const String whepPath = String.fromEnvironment(
    'WHEP_PATH',
    defaultValue: 'live',
  );

  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue:
        '760908125337-sfppi17rht5mkv6ckcm28q2g25r5ru5i.apps.googleusercontent.com',
  );

  // Polling / timeouts
  static const int statusPollMs = 2000;
  static const int httpTimeoutSec = 12;

  // Trigger/calendar
  static const int calendarLookAheadMin = 5;
  static const int triggerStreamDurationSec = 180;

  // Interaction labels/icons
  static const List<String> interactionNames = [
    'Idle',
    'Calm',
    'Focus',
    'Camera',
  ];

  static const List<IconData> interactionIcons = [
    Icons.pause_circle_outline,
    Icons.spa_outlined,
    Icons.psychology_outlined,
    Icons.videocam_outlined,
  ];

  // ===== UI Colors =====
  static const int bgColor = 0xFF0C0F14;
  static const int surfaceColor = 0xFF171C24;
  static const int cardBorder = 0xFF2A3140;
  static const int textPrimary = 0xFFE8ECF2;
  static const int textSecondary = 0xFF97A3B6;
  static const int accentColor = 0xFF6EA8FE;
  static const int calmColor = 0xFF4CD97B;
  static const int stressColor = 0xFFFF6B6B;
}