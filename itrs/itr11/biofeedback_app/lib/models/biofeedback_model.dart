class BiofeedbackStatus {
  final double avgHr;
  final double avgHrv;
  final double avgBr;
  final int activeInteraction;
  final String interactionName;
  final double lastReward;
  final bool isHolding;
  final int holdStepsLeft;
  final int replaySize;
  final double epsilon;
  final int step;
  final bool encoderReady;

  final int maxDashboards;
  final int dashboardCount;
  final List<int> activeDashboardIds;
  final bool hasPendingIntervention;
  final String interventionPhase;
  final String dashboardConfirmedAt;
  final int proposedVisualId;
  final int executedVisualId;
  final int proposedDashboardId;
  final int executedDashboardId;
  final int proposedEncodedAction;
  final int executedEncodedAction;
  final String proposedDashboardTitle;
  final String proposedDashboardInstruction;
  final String executedDashboardTitle;
  final String executedDashboardInstruction;

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
    required this.maxDashboards,
    required this.dashboardCount,
    required this.activeDashboardIds,
    required this.hasPendingIntervention,
    required this.interventionPhase,
    required this.dashboardConfirmedAt,
    required this.proposedVisualId,
    required this.executedVisualId,
    required this.proposedDashboardId,
    required this.executedDashboardId,
    required this.proposedEncodedAction,
    required this.executedEncodedAction,
    required this.proposedDashboardTitle,
    required this.proposedDashboardInstruction,
    required this.executedDashboardTitle,
    required this.executedDashboardInstruction,
  });

  factory BiofeedbackStatus.fromJson(Map<String, dynamic> json) {
    final rawIds = json['active_dashboard_ids'];
    final List<int> parsedDashboardIds = <int>[];

    if (rawIds is List) {
      for (final item in rawIds) {
        if (item is int) {
          parsedDashboardIds.add(item);
        } else if (item is num) {
          parsedDashboardIds.add(item.toInt());
        } else if (item != null) {
          parsedDashboardIds.add(int.tryParse(item.toString()) ?? 0);
        }
      }
    }

    return BiofeedbackStatus(
      avgHr: (json['avg_hr'] ?? 0).toDouble(),
      avgHrv: (json['avg_hrv'] ?? 0).toDouble(),
      avgBr: (json['avg_br'] ?? 0).toDouble(),
      activeInteraction: (json['active_interaction'] ?? 0).toInt(),
      interactionName: json['interaction_name'] ?? 'Unknown',
      lastReward: (json['last_reward'] ?? 0).toDouble(),
      isHolding: json['is_holding'] ?? false,
      holdStepsLeft: (json['hold_steps_left'] ?? 0).toInt(),
      replaySize: (json['replay_size'] ?? 0).toInt(),
      epsilon: (json['epsilon'] ?? 1).toDouble(),
      step: (json['step'] ?? 0).toInt(),
      encoderReady: json['encoder_ready'] ?? false,
      maxDashboards: (json['max_dashboards'] ?? 0).toInt(),
      dashboardCount: (json['dashboard_count'] ?? 0).toInt(),
      activeDashboardIds: parsedDashboardIds,
      hasPendingIntervention: json['has_pending_intervention'] ?? false,
      interventionPhase: json['intervention_phase'] ?? 'idle',
      dashboardConfirmedAt: json['dashboard_confirmed_at'] ?? '',
      proposedVisualId: (json['proposed_visual_id'] ?? 0).toInt(),
      executedVisualId: (json['executed_visual_id'] ?? 0).toInt(),
      proposedDashboardId: (json['proposed_dashboard_id'] ?? 0).toInt(),
      executedDashboardId: (json['executed_dashboard_id'] ?? 0).toInt(),
      proposedEncodedAction: (json['proposed_encoded_action'] ?? 0).toInt(),
      executedEncodedAction: (json['executed_encoded_action'] ?? 0).toInt(),
      proposedDashboardTitle: json['proposed_dashboard_title'] ?? '',
      proposedDashboardInstruction:
          json['proposed_dashboard_instruction'] ?? '',
      executedDashboardTitle: json['executed_dashboard_title'] ?? '',
      executedDashboardInstruction:
          json['executed_dashboard_instruction'] ?? '',
    );
  }

  double get holdProgress {
    const totalSteps = 36;
    if (!isHolding) return 0.0;
    return 1.0 - (holdStepsLeft / totalSteps);
  }

  String get holdTimeRemaining {
    final seconds = holdStepsLeft * 5;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}