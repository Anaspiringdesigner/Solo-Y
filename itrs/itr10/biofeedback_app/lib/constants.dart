class AppConstants {
  // ── Server (non-const so it can be updated) ──
  static String serverIp   = '100.67.125.12';
  static String serverBase = 'http://100.67.125.12:8000';

  // SRT URL (caller mode: app dials TD stream server)
  // Adjust port if needed.
  static String streamUrl =
      'srt://100.67.125.12:9000?streamid=read:live';

  static void updateServerIp(String ip) {
    serverIp   = ip;
    serverBase = 'http://$ip:8000';
    streamUrl  =
        'srt://$ip:9000?streamid=read:live&mode=caller&latency=120';
  }

  // ── Polling ──────────────────────────────────
  static const int statusPollMs   = 2000;
  static const int calendarPollMs = 60000;

  // ── Calendar ─────────────────────────────────
  static const int calendarLookAheadMin = 5;

  // ── Colors ───────────────────────────────────
  static const int bgColor       = 0xFF0A0A0F;
  static const int surfaceColor  = 0xFF13131A;
  static const int accentColor   = 0xFF00E5FF;
  static const int stressColor   = 0xFFFF4444;
  static const int calmColor     = 0xFF00FF88;
  static const int textPrimary   = 0xFFFFFFFF;
  static const int textSecondary = 0xFF8888AA;
  static const int cardBorder    = 0xFF1E1E2E;

  // ── Interaction Names ────────────────────────
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