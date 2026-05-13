import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/verse_model.dart';
import '../services/scraper_service.dart';
import '../services/verse_storage_service.dart';
import '../services/sunrise_service.dart';
import '../services/location_service.dart';
import '../widgets/verse_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scraper = ScraperService();
  final _storage = VerseStorageService();
  final _location = LocationService();

  VerseModel? _verse;
  bool _isLoading = true;
  bool _isRefreshing = false;
  String _statusMessage = '';
  int _libraryCount = 0;
  String _sunriseTime = '';
  String _locationLabel = '';

  @override
  void initState() {
    super.initState();
    _loadOrFetchVerse();
    _loadSunriseInfo();
  }

  /// Fetch real GPS coordinates and compute today's exact sunrise time.
  Future<void> _loadSunriseInfo() async {
    final coords = await _location.getCurrentLocation();
    final now = DateTime.now();
    final sunrise = SunriseService.getSunrise(
      date: now,
      latitude: coords.latitude,
      longitude: coords.longitude,
    );
    final h = sunrise.hour.toString().padLeft(2, '0');
    final m = sunrise.minute.toString().padLeft(2, '0');

    setState(() {
      _sunriseTime = '$h:$m';
      _locationLabel =
          '${coords.latitude.toStringAsFixed(2)}°, '
          '${coords.longitude.toStringAsFixed(2)}°';
    });
  }

  Future<void> _loadOrFetchVerse({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'నేటి పద్యం తెస్తున్నాం...';
    });

    if (!forceRefresh && await _storage.hasTodayVerse()) {
      final cached = await _storage.loadTodayVerse();
      if (cached != null) {
        final count = await _storage.libraryCount();
        setState(() {
          _verse = cached;
          _isLoading = false;
          _libraryCount = count;
          _statusMessage = '';
        });
        return;
      }
    }

    setState(
        () => _statusMessage = 'వెబ్‌సైట్ నుండి పద్యం తెస్తున్నాం...');

    final verse = await _scraper.fetchRandomVerse();

    if (verse != null) {
      await _storage.saveTodayVerse(verse);
      final count = await _storage.libraryCount();
      setState(() {
        _verse = verse;
        _isLoading = false;
        _libraryCount = count;
        _statusMessage = '';
      });
    } else {
      final library = await _storage.loadLibrary();
      setState(() {
        _verse = library.isNotEmpty ? library.last : null;
        _isLoading = false;
        _statusMessage = library.isNotEmpty
            ? '⚠️ నెట్‌వర్క్ లేదు — చివరి పద్యం చూపిస్తున్నాం'
            : '⚠️ పద్యం తెచ్చుకోలేకపోయాం. నెట్‌వర్క్ తనిఖీ చేయండి.';
      });
    }
  }

  Future<void> _openInBrowser(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0500),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A0800),
        elevation: 0,
        title: Text(
          '🪔 తెలుగు భాగవతం',
          style: GoogleFonts.notoSansTelugu(
            color: const Color(0xFFFFD580),
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          // Sunrise chip
          if (_sunriseTime.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: Tooltip(
                  message: 'సూర్యోదయం @ $_locationLabel',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF8C00).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color:
                              const Color(0xFFFF8C00).withOpacity(0.35)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('🌅',
                            style: TextStyle(fontSize: 11)),
                        const SizedBox(width: 4),
                        Text(
                          _sunriseTime,
                          style: const TextStyle(
                            color: Color(0xFFFFD580),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Library count chip
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF8C00).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: const Color(0xFFFF8C00).withOpacity(0.35)),
                ),
                child: Text(
                  '📚 $_libraryCount',
                  style: const TextStyle(
                    color: Color(0xFFFFB347),
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ),

          // Refresh button
          IconButton(
            icon: _isRefreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFFFFD580),
                    ),
                  )
                : const Icon(Icons.refresh, color: Color(0xFFFFD580)),
            onPressed: _isRefreshing
                ? null
                : () async {
                    setState(() => _isRefreshing = true);
                    await Future.wait([
                      _loadOrFetchVerse(forceRefresh: true),
                      _loadSunriseInfo(),
                    ]);
                    setState(() => _isRefreshing = false);
                  },
          ),
        ],
      ),
      body: _isLoading
          ? _buildLoadingState()
          : _verse == null
              ? _buildErrorState()
              : _buildVerseContent(),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Color(0xFFFFB347)),
          const SizedBox(height: 20),
          Text(
            _statusMessage,
            style: GoogleFonts.notoSansTelugu(
              color: const Color(0xFFD4A96A),
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi_off,
                color: Color(0xFFFFB347), size: 64),
            const SizedBox(height: 16),
            Text(
              _statusMessage,
              style: GoogleFonts.notoSansTelugu(
                color: const Color(0xFFD4A96A),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _loadOrFetchVerse(forceRefresh: true),
              icon: const Icon(Icons.refresh),
              label: Text(
                'మళ్ళీ ప్రయత్నించు',
                style: GoogleFonts.notoSansTelugu(),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF8C00),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerseContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Warning banner
          if (_statusMessage.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: Colors.orange.withOpacity(0.4)),
              ),
              child: Text(
                _statusMessage,
                style: GoogleFonts.notoSansTelugu(
                  color: Colors.orange[300],
                  fontSize: 12,
                ),
              ),
            ),

          VerseCard(verse: _verse!),

          const SizedBox(height: 16),

          // Open in browser
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openInBrowser(_verse!.sourceUrl),
              icon: const Icon(Icons.open_in_browser,
                  color: Color(0xFFFFB347)),
              label: Text(
                'తెలుగుభాగవతం.ఆర్గ్ లో చదువు',
                style: GoogleFonts.notoSansTelugu(
                  color: const Color(0xFFFFB347),
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFFFB347)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Attribution + location info
          Center(
            child: Column(
              children: [
                Text(
                  'మూలం: telugubhagavatam.org · పోతన తెలుగు భాగవతం',
                  style: GoogleFonts.notoSansTelugu(
                    color: const Color(0xFF6B4C2A),
                    fontSize: 10,
                  ),
                ),
                if (_locationLabel.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '📍 $_locationLabel · 🌅 సూర్యోదయం $_sunriseTime',
                    style: const TextStyle(
                      color: Color(0xFF4A3020),
                      fontSize: 9,
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}