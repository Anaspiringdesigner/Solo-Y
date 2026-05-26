// lib/services/calendar_service.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';

class CalendarService {
  static final CalendarService _instance = CalendarService._internal();
  factory CalendarService() => _instance;
  CalendarService._internal();

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [gcal.CalendarApi.calendarReadonlyScope],
  );

  bool   isSignedIn = false;
  Timer? _calendarTimer;

  Function(String eventName)? onEventDetected;

  // ── Sign In ───────────────────────────────────────────────
  Future<bool> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      isSignedIn = account != null;
      return isSignedIn;
    } catch (e) {
      debugPrint('Calendar sign in error: $e');
      return false;
    }
  }

  // ── Sign Out ──────────────────────────────────────────────
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    isSignedIn = false;
    _calendarTimer?.cancel();
  }

  // ── Start Polling ─────────────────────────────────────────
  void startPolling(Function(String) onEvent) {
    onEventDetected = onEvent;
    _calendarTimer  = Timer.periodic(
      Duration(milliseconds: AppConstants.calendarPollMs),
      (_) => _checkUpcomingEvents(),
    );
    _checkUpcomingEvents();
  }

  void stopPolling() {
    _calendarTimer?.cancel();
  }

  // ── Check Upcoming Events ─────────────────────────────────
  Future<void> _checkUpcomingEvents() async {
    if (!isSignedIn) return;

    try {
      final account = await _googleSignIn.signInSilently();
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
      final now    = DateTime.now().toUtc();
      final ahead  = now.add(Duration(
          minutes: AppConstants.calendarLookAheadMin));

      final events = await calApi.events.list(
        'primary',
        timeMin:      now,
        timeMax:      ahead,
        singleEvents: true,
        orderBy:      'startTime',
        maxResults:   5,
      );

      client.close();

      if (events.items != null &&
          events.items!.isNotEmpty) {
        for (final event in events.items!) {
          final name = event.summary ?? 'Calendar Event';
          debugPrint('[CALENDAR] Upcoming: $name');
          onEventDetected?.call(name);
          break;
        }
      }
    } catch (e) {
      debugPrint('[CALENDAR ERROR] $e');
    }
  }
}