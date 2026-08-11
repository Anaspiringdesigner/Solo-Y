import '../constants.dart';

class BiofeedbackStatus {
  final double avgHr;
  final double avgHrv;
  final double avgBr;

  final int activeInteraction;
  final String state;
  final bool isHolding;
  final int holdStepsLeft;
  final String triggerType;

  BiofeedbackStatus({
    required this.avgHr,
    required this.avgHrv,
    required this.avgBr,
    required this.activeInteraction,
    required this.state,
    required this.isHolding,
    required this.holdStepsLeft,
    required this.triggerType,
  });

  factory BiofeedbackStatus.fromJson(Map<String, dynamic> json) {
    return BiofeedbackStatus(
      avgHr: (json['avg_hr'] ?? 0).toDouble(),
      avgHrv: (json['avg_hrv'] ?? 0).toDouble(),
      avgBr: (json['avg_br'] ?? 0).toDouble(),
      activeInteraction: (json['active_interaction'] ?? 0).toInt(),
      state: (json['state'] ?? 'IDLE').toString(),
      isHolding: json['is_holding'] ?? false,
      holdStepsLeft: (json['hold_steps_left'] ?? 0).toInt(),
      triggerType: (json['trigger_type'] ?? 'none').toString(),
    );
  }

  double get holdProgress {
    final totalSteps =
        AppConstants.triggerStreamDurationSec ~/ AppConstants.holdStepSec;
    if (!isHolding || totalSteps <= 0) return 0.0;
    final p = 1.0 - (holdStepsLeft / totalSteps);
    return p.clamp(0.0, 1.0);
  }

  String get holdTimeRemaining {
    final seconds = holdStepsLeft * AppConstants.holdStepSec;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}