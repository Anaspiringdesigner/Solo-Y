// lib/constants.dart

class AppConstants {
  // ── Server ──────────────────────────────────────────────
  static const String serverIp   = '10.96.79.235';
  static const String serverBase = 'http://10.96.79.235:8000';
  static const String streamUrl  =
      'http://10.96.79.235:8080/hls/biofeedback.m3u8';

  // ── Polling ─────────────────────────────────────────────
  static const int statusPollMs   = 2000;
  static const int calendarPollMs = 60000;

  // ── Calendar ─────────────────────────────────────────────
  static const int calendarLookAheadMin = 5;

  // ── Colors ───────────────────────────────────────────────
  static const int bgColor       = 0xFF0A0A0F;
  static const int surfaceColor  = 0xFF13131A;
  static const int accentColor   = 0xFF00E5FF;
  static const int stressColor   = 0xFFFF4444;
  static const int calmColor     = 0xFF00FF88;
  static const int textPrimary   = 0xFFFFFFFF;
  static const int textSecondary = 0xFF8888AA;
  static const int cardBorder    = 0xFF1E1E2E;

  // ── Interaction Names ────────────────────────────────────
  static const List<String> interactionNames = [
    'Paper Crumpling',
    'Noise Crumpling',
    'Noise in Circle',
    'Video Ripples',
    'Flowery Noise',
  ];

  static const List<String> interactionIcons = [
    '📄', '🌊', '⭕', '📹', '🌸',
  ];
}