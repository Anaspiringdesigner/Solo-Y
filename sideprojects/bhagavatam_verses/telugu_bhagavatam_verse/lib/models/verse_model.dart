import 'dart:convert';

/// Represents a single padyam (verse) from telugubhagavatam.org
class VerseModel {
  final String padyam;       // Telugu verse text
  final String teeka;        // Word-by-word meaning (టీక)
  final String bhavam;       // Overall meaning (భావం)
  final String skanda;       // Skanda name (స్కంధం)
  final String ghatta;       // Ghatta (episode) name
  final String sourceUrl;    // Direct link to the verse page
  final DateTime fetchedAt;  // When it was scraped
  final int skandaNum;
  final int ghattaNum;
  final int padyamNum;

  const VerseModel({
    required this.padyam,
    required this.teeka,
    required this.bhavam,
    required this.skanda,
    required this.ghatta,
    required this.sourceUrl,
    required this.fetchedAt,
    required this.skandaNum,
    required this.ghattaNum,
    required this.padyamNum,
  });

  /// Serialise to JSON for SharedPreferences storage
  Map<String, dynamic> toJson() => {
        'padyam': padyam,
        'teeka': teeka,
        'bhavam': bhavam,
        'skanda': skanda,
        'ghatta': ghatta,
        'sourceUrl': sourceUrl,
        'fetchedAt': fetchedAt.toIso8601String(),
        'skandaNum': skandaNum,
        'ghattaNum': ghattaNum,
        'padyamNum': padyamNum,
      };

  factory VerseModel.fromJson(Map<String, dynamic> json) => VerseModel(
        padyam: json['padyam'] ?? '',
        teeka: json['teeka'] ?? '',
        bhavam: json['bhavam'] ?? '',
        skanda: json['skanda'] ?? '',
        ghatta: json['ghatta'] ?? '',
        sourceUrl: json['sourceUrl'] ?? '',
        fetchedAt: DateTime.parse(json['fetchedAt']),
        skandaNum: json['skandaNum'] ?? 1,
        ghattaNum: json['ghattaNum'] ?? 1,
        padyamNum: json['padyamNum'] ?? 1,
      );

  String toJsonString() => jsonEncode(toJson());
  factory VerseModel.fromJsonString(String s) =>
      VerseModel.fromJson(jsonDecode(s));
}