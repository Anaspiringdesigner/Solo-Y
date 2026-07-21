class AppConstants {
  // ===== API =====
  static const String apiBaseUrl = 'http://127.0.0.1:8000';

  // Dev gateway headers (temporary; move to secure auth later)
  static const String gatewaySecret = 'super_secret_gateway_key';
  static const String verifiedUserId = 'user123';
  static const String authIssuer = 'local-gateway';

  // Polling / timeouts
  static const int statusPollMs = 2000;
  static const int httpTimeoutSec = 12;

  // Trigger/calendar
  static const int calendarLookAheadMin = 5;
  static const int triggerStreamDurationSec = 180;

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