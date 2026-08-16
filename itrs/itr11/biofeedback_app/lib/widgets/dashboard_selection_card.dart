import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants.dart';
import '../models/dashboard_model.dart';

class DashboardSelectionCard extends StatefulWidget {
  final String suggestedTitle;
  final String suggestedInstruction;
  final int? selectedDashboardId;
  final List<DashboardOption> dashboards;
  final bool isCreating;
  final bool isConfirming;
  final String message;
  final ValueChanged<int> onSelectDashboard;
  final ValueChanged<String> onCreateDashboard;
  final VoidCallback onConfirm;

  const DashboardSelectionCard({
    super.key,
    required this.suggestedTitle,
    required this.suggestedInstruction,
    required this.selectedDashboardId,
    required this.dashboards,
    required this.isCreating,
    required this.isConfirming,
    required this.message,
    required this.onSelectDashboard,
    required this.onCreateDashboard,
    required this.onConfirm,
  });

  @override
  State<DashboardSelectionCard> createState() => _DashboardSelectionCardState();
}

class _DashboardSelectionCardState extends State<DashboardSelectionCard> {
  static const int totalSeconds = 60;
  late int _secondsLeft;
  Timer? _timer;
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _secondsLeft = totalSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_secondsLeft <= 1) {
        _timer?.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft -= 1);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  double get _progress => (totalSeconds - _secondsLeft) / totalSeconds;

  String get _timeLabel {
    final m = _secondsLeft ~/ 60;
    final s = _secondsLeft % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(AppConstants.surfaceColor),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(AppConstants.cardBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: LinearProgressIndicator(
              value: _progress,
              backgroundColor: const Color(AppConstants.cardBorder),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(AppConstants.accentColor),
              ),
              minHeight: 4,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
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
                        const SizedBox(height: 6),
                        Text(
                          widget.suggestedTitle.isEmpty ? 'Pending...' : widget.suggestedTitle,
                          style: GoogleFonts.inter(
                            color: const Color(AppConstants.textPrimary),
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(AppConstants.accentColor).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(AppConstants.accentColor).withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        _timeLabel,
                        style: GoogleFonts.inter(
                          color: const Color(AppConstants.accentColor),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  widget.suggestedInstruction,
                  style: GoogleFonts.inter(
                    color: const Color(AppConstants.textSecondary),
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Choose a different dashboard or create your own action.',
                  style: GoogleFonts.inter(
                    color: const Color(AppConstants.textSecondary),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 42,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.dashboards.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final d = widget.dashboards[index];
                      final isSelected = d.id == widget.selectedDashboardId;
                      return GestureDetector(
                        onTap: () => widget.onSelectDashboard(d.id),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(AppConstants.accentColor).withValues(alpha: 0.14)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(AppConstants.accentColor)
                                  : const Color(AppConstants.cardBorder),
                              width: isSelected ? 1.5 : 1,
                            ),
                          ),
                          child: Text(
                            d.title,
                            style: GoogleFonts.inter(
                              color: isSelected
                                  ? const Color(AppConstants.accentColor)
                                  : const Color(AppConstants.textSecondary),
                              fontSize: 12,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        style: GoogleFonts.inter(color: const Color(AppConstants.textPrimary)),
                        decoration: InputDecoration(
                          hintText: 'Type your own action',
                          hintStyle: GoogleFonts.inter(
                            color: const Color(AppConstants.textSecondary),
                            fontSize: 13,
                          ),
                          filled: true,
                          fillColor: const Color(AppConstants.bgColor),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: Color(AppConstants.cardBorder)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: Color(AppConstants.cardBorder)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: Color(AppConstants.accentColor)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: widget.isCreating
                          ? null
                          : () {
                              final text = _controller.text.trim();
                              if (text.isNotEmpty) {
                                widget.onCreateDashboard(text);
                                _controller.clear();
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(AppConstants.accentColor).withValues(alpha: 0.15),
                        foregroundColor: const Color(AppConstants.accentColor),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      ),
                      child: widget.isCreating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add),
                    ),
                  ],
                ),
                if (widget.message.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    widget.message,
                    style: GoogleFonts.inter(
                      color: const Color(AppConstants.accentColor),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: widget.isConfirming ? null : widget.onConfirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(AppConstants.accentColor).withValues(alpha: 0.15),
                      foregroundColor: const Color(AppConstants.accentColor),
                      side: const BorderSide(
                        color: Color(AppConstants.accentColor),
                        width: 1,
                      ),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: widget.isConfirming
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(AppConstants.accentColor),
                            ),
                          )
                        : Text(
                            'Confirm Selected Action',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}