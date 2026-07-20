// lib/services/calendar_service.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';

class CalendarService {
  static final CalendarService _instance =
      CalendarService._internal();
  factory CalendarService() => _instance;
  CalendarService._internal();

  // ── Google Sign In ────────────────────────────────────────
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId:
        '760908125337-sfppi17rht5mkv6ckcm28q2g25r5ru5i'
        '.apps.googleusercontent.com',
    scopes: [
      gcal.CalendarApi.calendarReadonlyScope,
      'email',
      'profile',
    ],
  );

  bool         isSignedIn  = false;
  Timer?       _dailyTimer;
  final List<Timer> _eventTimers = [];

  Function(String eventName)? onEventDetected;

  // ── Sign In ───────────────────────────────────────────────
  Future<bool> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) return false;
      isSignedIn = true;
      debugPrint('[CALENDAR] Signed in: '
          '${account.email}');
      return true;
    } catch (e) {
      debugPrint('[CALENDAR] Sign in error: $e');
      return false;
    }
  }

  // ── Sign Out ──────────────────────────────────────────────
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    isSignedIn = false;
    _cancelAllTimers();
  }

  // ── Start Daily Planning ──────────────────────────────────
  void startDailyPlanning(
      Function(String) onEvent) {
    onEventDetected = onEvent;
    _planTodayEvents();
    _scheduleMidnightRefresh();
  }

  // ── Cancel All Timers ─────────────────────────────────────
  void _cancelAllTimers() {
    for (final t in _eventTimers) {
      t.cancel();
    }
    _eventTimers.clear();
    _dailyTimer?.cancel();
  }

  void stopPolling() {
    _cancelAllTimers();
  }

  // ── Schedule Midnight Refresh ─────────────────────────────
  void _scheduleMidnightRefresh() {
    final now      = DateTime.now();
    final midnight = DateTime(
        now.year, now.month, now.day + 1, 0, 0, 0);
    final timeUntilMidnight =
        midnight.difference(now);

    _dailyTimer = Timer(timeUntilMidnight, () {
      _planTodayEvents();
      _dailyTimer = Timer.periodic(
        const Duration(hours: 24),
        (_) => _planTodayEvents(),
      );
    });

    debugPrint('[CALENDAR] Next refresh in: '
        '${timeUntilMidnight.inHours}h '
        '${timeUntilMidnight.inMinutes % 60}m');
  }

  // ── Plan Today's Events ───────────────────────────────────
  Future<void> _planTodayEvents() async {
    if (!isSignedIn) return;

    try {
      // Cancel existing event timers
      for (final t in _eventTimers) {
        t.cancel();
      }
      _eventTimers.clear();

      final account =
          await _googleSignIn.signInSilently();
      if (account == null) return;

      final auth = await account.authentication;
      if (auth.accessToken == null) return;

      final client = authenticatedClient(
        http.Client(),
        AccessCredentials(
          AccessToken(
            'Bearer',
            auth.accessToken!,
            DateTime.now().toUtc().add(
                const Duration(hours: 1)),
          ),
          null,
          [gcal.CalendarApi.calendarReadonlyScope],
        ),
      );

      final calApi = gcal.CalendarApi(client);

      final now        = DateTime.now();
      final startOfDay = DateTime(
              now.year, now.month, now.day,
              0, 0, 0)
          .toUtc();
      final endOfDay = DateTime(
              now.year, now.month, now.day,
              23, 59, 59)
          .toUtc();

      final events = await calApi.events.list(
        'primary',
        timeMin:      startOfDay,
        timeMax:      endOfDay,
        singleEvents: true,
        orderBy:      'startTime',
        maxResults:   50,
      );

      client.close();

      if (events.items == null ||
          events.items!.isEmpty) {
        debugPrint('[CALENDAR] No events today');
        return;
      }

      debugPrint('[CALENDAR] Found '
          '${events.items!.length} events today');

      int scheduled = 0;
      for (final event in events.items!) {
        final eventName =
            event.summary ?? 'Calendar Event';
        final startTime =
            event.start?.dateTime?.toLocal();

        if (startTime == null) continue;

        // Trigger 5 minutes before event
        final triggerTime = startTime.subtract(
          Duration(
              minutes:
                  AppConstants.calendarLookAheadMin),
        );

        // Skip if trigger time already passed
        if (triggerTime
            .isBefore(DateTime.now())) {
          debugPrint('[CALENDAR] Skipping past: '
              '$eventName');
          continue;
        }

        final delay =
            triggerTime.difference(DateTime.now());

        debugPrint('[CALENDAR] Scheduled: '
            '$eventName → in '
            '${delay.inMinutes}m '
            '${delay.inSeconds % 60}s');

        final timer = Timer(delay, () {
          debugPrint('[CALENDAR] ⚡ Firing: '
              '$eventName');
          onEventDetected?.call(eventName);
        });

        _eventTimers.add(timer);
        scheduled++;
      }

      debugPrint('[CALENDAR] Scheduled '
          '$scheduled triggers for today');

    } catch (e) {
      debugPrint('[CALENDAR ERROR] $e');
    }
  }

  // ── Manual Refresh ────────────────────────────────────────
  Future<void> refreshToday() async {
    await _planTodayEvents();
  }

  // ── Scheduled Trigger Count ───────────────────────────────
  int get scheduledTriggerCount =>
      _eventTimers.length;
}