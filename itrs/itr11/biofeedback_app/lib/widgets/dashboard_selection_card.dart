import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants.dart';
import '../models/dashboard_model.dart';

class DashboardSelectionCard extends StatefulWidget {
  final String suggestedTitle;
  final String suggestedInstruction;
  final List<DashboardOption> dashboards;
  final int selectedDashboardId;
  final ValueChanged<int> onDashboardSelected;
  final ValueChanged<String> onCustomInstructionChanged;
  final Future<void> Function() onCreateCustomDashboard;
  final Future<void> Function() onConfirm;
  final bool isCreatingDashboard;
  final bool isSubmitting;

  const DashboardSelectionCard({
    super.key,
    required this.suggestedTitle,
    required this.suggestedInstruction,
    required this.dashboards,
    required this.selectedDashboardId,
    required this.onDashboardSelected,
    required this.onCustomInstructionChanged,
    required this.onCreateCustomDashboard,
    required this.onConfirm,
    required this.isCreatingDashboard,
    required this.isSubmitting,
  });

  @override
  State<DashboardSelectionCard> createState() => _DashboardSelectionCardState();
}

class _DashboardSelectionCardState extends State<DashboardSelectionCard> {
  static const int totalSeconds = 60;
  late Timer _timer;
  int _secondsLeft = totalSeconds;
  final TextEditingController _customController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft -= 1);
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _customController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double progress = 1.0 - (_secondsLeft / totalSeconds);
    final int mins = _secondsLeft ~/ 60;
    final int secs = _secondsLeft % 60;
    final String timerLabel = '$mins:${secs.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(AppConstants.surfaceColor),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(AppConstants.cardBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: const Color(AppConstants.cardBorder),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(AppConstants.accentColor),
              ),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                'SUGGESTED ACTION',
                style: GoogleFonts.inter(
                  color: const Color(AppConstants.textSecondary),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.4,
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                  timerLabel,
                  style: GoogleFonts.inter(
                    color: const Color(AppConstants.accentColor),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(AppConstants.accentColor).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: const Color(AppConstants.accentColor).withValues(alpha: 0.35),
                width: 1.2,
              ),
            ),
            child: Column(
              children: [
                Text(
                  widget.suggestedTitle.isEmpty
                      ? 'Suggested dashboard'
                      : widget.suggestedTitle,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    color: const Color(AppConstants.textPrimary),
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.suggestedInstruction,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    color: const Color(AppConstants.textSecondary),
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Choose a dashboard',
            style: GoogleFonts.inter(
              color: const Color(AppConstants.textPrimary),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          ...widget.dashboards.map((dashboard) {
            final bool isSelected = dashboard.id == widget.selectedDashboardId;
            return GestureDetector(
              onTap: () => widget.onDashboardSelected(dashboard.id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(AppConstants.accentColor).withValues(alpha: 0.12)
                      : const Color(AppConstants.bgColor).withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isSelected
                        ? const Color(AppConstants.accentColor)
                        : const Color(AppConstants.cardBorder),
                    width: isSelected ? 1.5 : 1.0,
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      dashboard.title,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        color: isSelected
                            ? const Color(AppConstants.accentColor)
                            : const Color(AppConstants.textPrimary),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      dashboard.instruction,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        color: isSelected
                            ? const Color(AppConstants.textPrimary)
                            : const Color(AppConstants.textSecondary),
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
          Text(
            'Or create your own action',
            style: GoogleFonts.inter(
              color: const Color(AppConstants.textPrimary),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _customController,
            minLines: 2,
            maxLines: 4,
            onChanged: widget.onCustomInstructionChanged,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              color: const Color(AppConstants.textPrimary),
            ),
            decoration: InputDecoration(
              hintText: 'Type the action you want to take during the event duration...',
              hintStyle: GoogleFonts.inter(
                color: const Color(AppConstants.textSecondary),
                fontSize: 12,
              ),
              filled: true,
              fillColor: const Color(AppConstants.bgColor).withValues(alpha: 0.45),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(AppConstants.cardBorder),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(AppConstants.cardBorder),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(AppConstants.accentColor),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: widget.isCreatingDashboard
                  ? null
                  : widget.onCreateCustomDashboard,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(AppConstants.accentColor),
                side: const BorderSide(
                  color: Color(AppConstants.accentColor),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              child: widget.isCreatingDashboard
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      'Create Custom Dashboard',
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: widget.isSubmitting ? null : widget.onConfirm,
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    const Color(AppConstants.accentColor).withValues(alpha: 0.15),
                foregroundColor: const Color(AppConstants.accentColor),
                side: const BorderSide(
                  color: Color(AppConstants.accentColor),
                  width: 1,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(32),
                ),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: widget.isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(AppConstants.accentColor),
                      ),
                    )
                  : Text(
                      'Confirm Action',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
} 