// lib/models/biofeedback_model.dart
class BiofeedbackStatus {
  final double avgHr;
  final double avgHrv;
  final double avgBr;

  final int activeInteraction;
  final String state;
  final bool isHolding;
  final int holdStepsLeft;

  BiofeedbackStatus({
    required this.avgHr,
    required this.avgHrv,
    required this.avgBr,
    required this.activeInteraction,
    required this.state,
    required this.isHolding,
    required this.holdStepsLeft,
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
    );
  }

  /// Hold progress in [0.0 .. 1.0]
  double get holdProgress {
    const totalSteps = 36; // 180 sec / 5 sec per step
    if (!isHolding) return 0.0;
    final p = 1.0 - (holdStepsLeft / totalSteps);
    return p.clamp(0.0, 1.0);
  }

  /// Remaining hold time as mm:ss
  String get holdTimeRemaining {
    final seconds = holdStepsLeft * 5;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() {
    return {
      'avg_hr': avgHr,
      'avg_hrv': avgHrv,
      'avg_br': avgBr,
      'active_interaction': activeInteraction,
      'state': state,
      'is_holding': isHolding,
      'hold_steps_left': holdStepsLeft,
    };
  }

  BiofeedbackStatus copyWith({
    double? avgHr,
    double? avgHrv,
    double? avgBr,
    int? activeInteraction,
    String? state,
    bool? isHolding,
    int? holdStepsLeft,
  }) {
    return BiofeedbackStatus(
      avgHr: avgHr ?? this.avgHr,
      avgHrv: avgHrv ?? this.avgHrv,
      avgBr: avgBr ?? this.avgBr,
      activeInteraction: activeInteraction ?? this.activeInteraction,
      state: state ?? this.state,
      isHolding: isHolding ?? this.isHolding,
      holdStepsLeft: holdStepsLeft ?? this.holdStepsLeft,
    );
  }
}