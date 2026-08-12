// lib/widgets/interaction_bar.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants.dart';

class InteractionBar extends StatelessWidget {
  final int    activeIndex;
  final bool   isHolding;
  final double holdProgress;
  final String holdTimeRemaining;

  const InteractionBar({
    super.key,
    required this.activeIndex,
    required this.isHolding,
    required this.holdProgress,
    required this.holdTimeRemaining,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:    const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        const Color(AppConstants.surfaceColor),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: const Color(AppConstants.cardBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Active Interaction Label ────────────────────
          Row(
            children: [
              Text(
                AppConstants.interactionIcons[activeIndex],
                style: const TextStyle(fontSize: 18),
              ),
              const SizedBox(width: 8),
              Text(
                AppConstants.interactionNames[activeIndex],
                style: GoogleFonts.inter(
                  color:      const Color(AppConstants.textPrimary),
                  fontSize:   16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (isHolding)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(AppConstants.accentColor)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(AppConstants.accentColor)
                          .withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    holdTimeRemaining,
                    style: GoogleFonts.inter(
                      color:      const Color(
                          AppConstants.accentColor),
                      fontSize:   12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),

          // ── Hold Progress Bar ───────────────────────────
          if (isHolding) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value:           holdProgress,
                backgroundColor: const Color(
                    AppConstants.cardBorder),
                valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(AppConstants.accentColor)),
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Holding interaction...',
              style: GoogleFonts.inter(
                color:    const Color(AppConstants.textSecondary),
                fontSize: 11,
              ),
            ),
          ],

          // ── Interaction Selector ────────────────────────
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(
                AppConstants.interactionNames.length,
                (i) {
                  final isActive = i == activeIndex;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin:   const EdgeInsets.only(right: 8),
                    padding:  const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isActive
                          ? const Color(AppConstants.accentColor)
                              .withValues(alpha: 0.15)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isActive
                            ? const Color(AppConstants.accentColor)
                            : const Color(AppConstants.cardBorder),
                        width: isActive ? 1.5 : 1.0,
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(
                          AppConstants.interactionIcons[i],
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          AppConstants.interactionNames[i]
                              .split(' ')[0],
                          style: GoogleFonts.inter(
                            color: isActive
                                ? const Color(
                                    AppConstants.accentColor)
                                : const Color(
                                    AppConstants.textSecondary),
                            fontSize:   12,
                            fontWeight: isActive
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}