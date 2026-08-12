// lib/models/biofeedback_model.dart

class BiofeedbackStatus {
  final double avgHr;
  final double avgHrv;
  final double avgBr;
  final int    activeInteraction;
  final String interactionName;
  final double lastReward;
  final bool   isHolding;
  final int    holdStepsLeft;
  final int    replaySize;
  final double epsilon;
  final int    step;
  final bool   encoderReady;

  BiofeedbackStatus({
    required this.avgHr,
    required this.avgHrv,
    required this.avgBr,
    required this.activeInteraction,
    required this.interactionName,
    required this.lastReward,
    required this.isHolding,
    required this.holdStepsLeft,
    required this.replaySize,
    required this.epsilon,
    required this.step,
    required this.encoderReady,
  });

  factory BiofeedbackStatus.fromJson(Map<String, dynamic> json) {
    return BiofeedbackStatus(
      avgHr:             (json['avg_hr']             ?? 0).toDouble(),
      avgHrv:            (json['avg_hrv']            ?? 0).toDouble(),
      avgBr:             (json['avg_br']             ?? 0).toDouble(),
      activeInteraction: (json['active_interaction'] ?? 0).toInt(),
      interactionName:   json['interaction_name']    ?? 'Unknown',
      lastReward:        (json['last_reward']        ?? 0).toDouble(),
      isHolding:          json['is_holding']         ?? false,
      holdStepsLeft:     (json['hold_steps_left']    ?? 0).toInt(),
      replaySize:        (json['replay_size']        ?? 0).toInt(),
      epsilon:           (json['epsilon']            ?? 1).toDouble(),
      step:              (json['step']               ?? 0).toInt(),
      encoderReady:       json['encoder_ready']      ?? false,
    );
  }

  // Hold progress 0.0 → 1.0
  double get holdProgress {
    const totalSteps = 36;
    if (!isHolding) return 0.0;
    return 1.0 - (holdStepsLeft / totalSteps);
  }

  // Remaining hold time in mm:ss
  String get holdTimeRemaining {
    final seconds = holdStepsLeft * 5;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}