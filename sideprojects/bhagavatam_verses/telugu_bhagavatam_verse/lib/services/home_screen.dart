import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/verse_model.dart';
import '../services/scraper_service.dart';
import '../services/verse_storage_service.dart';
import '../widgets/verse_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scraper = ScraperService();
  final _storage = VerseStorageService();

  VerseModel? _verse;
  bool _isLoading = true;
  bool _isRefreshing = false;
  String _statusMessage = '';
  int _libraryCount = 0;

  @override
  void initState() {
    super.initState();
    _loadOrFetchVerse();
  }

  /// ── Main logic: load cached verse or fetch new one ────────────────────────
  Future<void> _loadOrFetchVerse({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'నేటి పద్యం తెస్తున్నాం...';
    });

    // Check if we already have today's verse
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

    // Fetch a new random verse from the website
    setState(() => _statusMessage = 'వెబ్‌సైట్ నుండి పద్యం తెస్తున్నాం...');

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
      // Fallback: load last known verse from library
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
          // Library count badge
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF8C00).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: const Color(0xFFFF8C00).withOpacity(0.4)),
                ),
                child: Text(
                  '📚 $_libraryCount పద్యాలు',
                  style: GoogleFonts.notoSansTelugu(
                    color: const Color(0xFFFFB347),
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
                    await _loadOrFetchVerse(forceRefresh: true);
                    setState(() => _isRefreshing = false);
                  },
            tooltip: 'కొత్త పద్యం',
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
            const Icon(Icons.wifi_off, color: Color(0xFFFFB347), size: 64),
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
          // Status message (warning etc.)
          if (_statusMessage.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withOpacity(0.4)),
              ),
              child: Text(
                _statusMessage,
                style: GoogleFonts.notoSansTelugu(
                  color: Colors.orange[300],
                  fontSize: 12,
                ),
              ),
            ),

          // Main verse card
          VerseCard(verse: _verse!),

          const SizedBox(height: 16),

          // Open in browser button
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

          // Attribution
          Center(
            child: Text(
              'మూలం: telugubhagavatam.org · పోతన తెలుగు భాగవతం',
              style: GoogleFonts.notoSansTelugu(
                color: const Color(0xFF6B4C2A),
                fontSize: 10,
              ),
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}