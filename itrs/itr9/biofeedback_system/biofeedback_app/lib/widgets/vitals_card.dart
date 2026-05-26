// lib/widgets/vitals_card.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants.dart';

class VitalsCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color  color;
  final bool   isStressed;

  const VitalsCard({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    this.isStressed = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        margin:  const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(
            vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color:        const Color(AppConstants.surfaceColor),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isStressed
                ? color.withOpacity(0.8)
                : color.withOpacity(0.3),
            width: isStressed ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                color:         color,
                fontSize:      11,
                fontWeight:    FontWeight.w500,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: GoogleFonts.inter(
                color:      const Color(AppConstants.textPrimary),
                fontSize:   24,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              unit,
              style: GoogleFonts.inter(
                color:    const Color(AppConstants.textSecondary),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}