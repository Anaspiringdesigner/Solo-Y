import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/verse_model.dart';

class VerseCard extends StatefulWidget {
  final VerseModel verse;
  const VerseCard({super.key, required this.verse});

  @override
  State<VerseCard> createState() => _VerseCardState();
}

class _VerseCardState extends State<VerseCard> {
  bool _showTeeka = false;
  bool _showBhavam = true;

  @override
  Widget build(BuildContext context) {
    final verse = widget.verse;

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E0A00), Color(0xFF2D1200)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFFF8C00).withOpacity(0.3),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF8C00).withOpacity(0.1),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0x33FF8C00)),
              ),
            ),
            child: Row(
              children: [
                const Text('🪔', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        verse.skanda,
                        style: GoogleFonts.notoSansTelugu(
                          color: const Color(0xFFFFB347),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      if (verse.ghatta.isNotEmpty)
                        Text(
                          verse.ghatta,
                          style: GoogleFonts.notoSansTelugu(
                            color: const Color(0xFFD4A96A),
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                ),
                // Date badge
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF8C00).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _formatDate(verse.fetchedAt),
                    style: const TextStyle(
                      color: Color(0xFFFFD580),
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Padyam (verse) ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Verse text
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: const Border(
                      left: BorderSide(
                        color: Color(0xFFFF8C00),
                        width: 3,
                      ),
                    ),
                  ),
                  child: SelectableText(
                    verse.padyam,
                    style: GoogleFonts.notoSansTelugu(
                      color: const Color(0xFFFFF8E7),
                      fontSize: 16,
                      height: 1.9,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Copy button
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: verse.padyam));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'పద్యం కాపీ అయింది!',
                            style: GoogleFonts.notoSansTelugu(),
                          ),
                          backgroundColor: const Color(0xFF3D1A00),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy,
                        size: 14, color: Color(0xFFFFB347)),
                    label: Text(
                      'కాపీ',
                      style: GoogleFonts.notoSansTelugu(
                        color: const Color(0xFFFFB347),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),

                // ── Bhavam (meaning) ─────────────────────────────────────────
                _SectionToggle(
                  title: '📖 భావం',
                  isExpanded: _showBhavam,
                  onToggle: () =>
                      setState(() => _showBhavam = !_showBhavam),
                  content: verse.bhavam,
                  contentColor: const Color(0xFFD4A96A),
                ),

                const SizedBox(height: 8),

                // ── Teeka (word meanings) ────────────────────────────────────
                _SectionToggle(
                  title: '📝 టీక',
                  isExpanded: _showTeeka,
                  onToggle: () =>
                      setState(() => _showTeeka = !_showTeeka),
                  content: verse.teeka,
                  contentColor: const Color(0xFFB8956A),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      'జన', 'ఫిబ్ర', 'మార్చి', 'ఏప్రి', 'మే', 'జూన్',
      'జూలై', 'ఆగ', 'సెప్ట', 'అక్టో', 'నవ', 'డిసె'
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }
}

/// ── Collapsible section widget ────────────────────────────────────────────────
class _SectionToggle extends StatelessWidget {
  final String title;
  final bool isExpanded;
  final VoidCallback onToggle;
  final String content;
  final Color contentColor;

  const _SectionToggle({
    required this.title,
    required this.isExpanded,
    required this.onToggle,
    required this.content,
    required this.contentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Text(
                  title,
                  style: GoogleFonts.notoSansTelugu(
                    color: const Color(0xFFFFB347),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  color: const Color(0xFFFFB347),
                  size: 18,
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              content,
              style: GoogleFonts.notoSansTelugu(
                color: contentColor,
                fontSize: 13,
                height: 1.7,
              ),
            ),
          ),
          crossFadeState: isExpanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 250),
        ),
      ],
    );
  }
}