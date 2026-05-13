import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as htmlParser;
import '../models/verse_model.dart';

/// Known Skanda → max Ghatta count mapping.
/// Based on telugubhagavatam.org site structure (640 total ghattas).
const Map<int, int> _skandaMaxGhatta = {
  1: 30,
  2: 20,
  3: 40,
  4: 45,
  51: 30,
  52: 25,
  6: 40,
  7: 35,
  8: 40,
  9: 45,
  101: 90,
  102: 80,
  11: 45,
  12: 15,
};

const Map<int, String> _skandaUrlParam = {
  1: '1',
  2: '2',
  3: '3',
  4: '4',
  51: '5.1',
  52: '5.2',
  6: '6',
  7: '7',
  8: '8',
  9: '9',
  101: '10.1',
  102: '10.2',
  11: '11',
  12: '12',
};

const Map<int, String> _skandaNames = {
  1: 'ప్రథమ స్కంధము',
  2: 'ద్వితీయ స్కంధము',
  3: 'తృతీయ స్కంధము',
  4: 'చతుర్థ స్కంధము',
  51: 'పంచమ స్కంధము (ప్రథమాశ్వాసము)',
  52: 'పంచమ స్కంధము (ద్వితీయాశ్వాసము)',
  6: 'షష్ఠ స్కంధము',
  7: 'సప్తమ స్కంధము',
  8: 'అష్టమ స్కంధము',
  9: 'నవమ స్కంధము',
  101: 'దశమ స్కంధము (పూర్వభాగము)',
  102: 'దశమ స్కంధము (ఉత్తరభాగము)',
  11: 'ఏకాదశ స్కంధము',
  12: 'ద్వాదశ స్కంధము',
};

class ScraperService {
  static const String _baseUrl = 'https://telugubhagavatam.org/';
  static const int _maxPadyamPerGhatta = 30;
  static const int _maxRetries = 5;

  final _random = Random();
  final List<int> _skandaKeys = _skandaMaxGhatta.keys.toList();

  /// Fetch a completely random verse from the website.
  Future<VerseModel?> fetchRandomVerse() async {
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        final skandaKey = _skandaKeys[_random.nextInt(_skandaKeys.length)];
        final maxGhatta = _skandaMaxGhatta[skandaKey]!;
        final ghattaNum = _random.nextInt(maxGhatta) + 1;
        final padyamNum = _random.nextInt(_maxPadyamPerGhatta) + 1;

        final verse = await _scrapeVerse(
          skandaKey: skandaKey,
          ghattaNum: ghattaNum,
          padyamNum: padyamNum,
        );

        if (verse != null) return verse;
      } catch (_) {
        // Retry on any error
      }
    }
    return null;
  }

  String _buildUrl(int skandaKey, int ghattaNum, int padyamNum) {
    final skandaParam = _skandaUrlParam[skandaKey]!;
    return '$_baseUrl?tebha&Skanda=$skandaParam&Ghatta=$ghattaNum&padyam=$padyamNum';
  }

  Future<VerseModel?> _scrapeVerse({
    required int skandaKey,
    required int ghattaNum,
    required int padyamNum,
  }) async {
    final url = _buildUrl(skandaKey, ghattaNum, padyamNum);

    final response = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'te,en;q=0.9',
      },
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) return null;

    final body = response.body;
    if (body.isEmpty) return null;

    final document = htmlParser.parse(body);

    // Extract padyam (verse text)
    String padyam = _extractText(document, [
      '.padyam',
      '.padya',
      'p.padyam',
      'div.padyam',
      '.verse',
    ]);

    // If no padyam found this coordinate doesn't exist — skip
    if (padyam.trim().isEmpty) return null;

    // Extract teeka (word-by-word meaning)
    String teeka = _extractText(document, [
      '.teeka',
      '.tika',
      'div.teeka',
      'p.teeka',
    ]);

    // Extract bhavam (overall meaning)
    String bhavam = _extractText(document, [
      '.bhavam',
      '.bhava',
      'div.bhavam',
      'p.bhavam',
    ]);

    // Extract ghatta name
    String ghatta = _extractText(document, [
      '.ghatta',
      '.ghattam',
      'h2.ghatta',
      'h3',
      '.subtitle',
    ]);

    return VerseModel(
      padyam: _cleanText(padyam),
      teeka: _cleanText(teeka).isNotEmpty
          ? _cleanText(teeka)
          : 'వివరణ అందుబాటులో లేదు',
      bhavam: _cleanText(bhavam).isNotEmpty
          ? _cleanText(bhavam)
          : 'భావం అందుబాటులో లేదు',
      skanda: _skandaNames[skandaKey] ?? 'స్కంధము',
      ghatta: _cleanText(ghatta).isNotEmpty
          ? _cleanText(ghatta)
          : 'ఘట్టం $ghattaNum',
      sourceUrl: url,
      fetchedAt: DateTime.now(),
      skandaNum: skandaKey,
      ghattaNum: ghattaNum,
      padyamNum: padyamNum,
    );
  }

  String _extractText(dynamic document, List<String> selectors) {
    for (final selector in selectors) {
      try {
        final elements = document.querySelectorAll(selector);
        if (elements.isNotEmpty) {
          final text = elements
              .map((e) => e.text.trim())
              .where((t) => t.isNotEmpty)
              .join('\n');
          if (text.isNotEmpty) return text;
        }
      } catch (_) {}
    }
    return '';
  }

  String _cleanText(String text) {
    return text
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}