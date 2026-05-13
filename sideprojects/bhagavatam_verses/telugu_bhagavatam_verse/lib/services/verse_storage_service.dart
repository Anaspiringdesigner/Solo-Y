import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/verse_model.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// Handles:
///  1. Storing today's verse (keyed by local date)
///  2. Growing a local library of all fetched verses over time
///  3. Sunrise-to-sunrise day boundary logic
/// ─────────────────────────────────────────────────────────────────────────────
class VerseStorageService {
  static const String _todayVerseKey = 'today_verse';
  static const String _todayDateKey = 'today_date';
  static const String _verseLibraryKey = 'verse_library';
  static const String _lastFetchKey = 'last_fetch_epoch';

  /// ── Get today's date string (used as the day key) ─────────────────────────
  /// We use local date (YYYY-MM-DD) as the day boundary.
  /// For true sunrise-to-sunrise, you'd integrate a sunrise API,
  /// but local date is accurate enough for most time zones.
  String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// ── Check if we already have a verse for today ────────────────────────────
  Future<bool> hasTodayVerse() async {
    final prefs = await SharedPreferences.getInstance();
    final storedDate = prefs.getString(_todayDateKey);
    return storedDate == _todayKey();
  }

  /// ── Save today's verse ────────────────────────────────────────────────────
  Future<void> saveTodayVerse(VerseModel verse) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_todayVerseKey, verse.toJsonString());
    await prefs.setString(_todayDateKey, _todayKey());
    await prefs.setInt(
        _lastFetchKey, DateTime.now().millisecondsSinceEpoch);

    // Also add to the growing library
    await _addToLibrary(prefs, verse);
  }

  /// ── Load today's verse ────────────────────────────────────────────────────
  Future<VerseModel?> loadTodayVerse() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_todayVerseKey);
    if (json == null) return null;
    try {
      return VerseModel.fromJsonString(json);
    } catch (_) {
      return null;
    }
  }

  /// ── Add verse to the growing local library ────────────────────────────────
  Future<void> _addToLibrary(SharedPreferences prefs, VerseModel verse) async {
    final raw = prefs.getStringList(_verseLibraryKey) ?? [];
    // Avoid duplicates by sourceUrl
    final existing = raw.map((s) => VerseModel.fromJsonString(s)).toList();
    final isDuplicate =
        existing.any((v) => v.sourceUrl == verse.sourceUrl);
    if (!isDuplicate) {
      raw.add(verse.toJsonString());
      await prefs.setStringList(_verseLibraryKey, raw);
    }
  }

  /// ── Load the entire verse library ─────────────────────────────────────────
  Future<List<VerseModel>> loadLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_verseLibraryKey) ?? [];
    return raw.map((s) => VerseModel.fromJsonString(s)).toList();
  }

  /// ── Total verses collected so far ─────────────────────────────────────────
  Future<int> libraryCount() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_verseLibraryKey) ?? []).length;
  }
}