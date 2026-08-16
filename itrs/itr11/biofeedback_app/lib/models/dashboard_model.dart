class DashboardOption {
  final int id;
  final String title;
  final String instruction;
  final String normalizedKey;
  final bool createdByUser;
  final bool active;
  final int createdAtStep;

  DashboardOption({
    required this.id,
    required this.title,
    required this.instruction,
    required this.normalizedKey,
    required this.createdByUser,
    required this.active,
    required this.createdAtStep,
  });

  factory DashboardOption.fromJson(Map<String, dynamic> json) {
    return DashboardOption(
      id: (json['id'] ?? 0).toInt(),
      title: json['title'] ?? 'Untitled',
      instruction: json['instruction'] ?? '',
      normalizedKey: json['normalized_key'] ?? '',
      createdByUser: json['created_by_user'] ?? false,
      active: json['active'] ?? true,
      createdAtStep: (json['created_at_step'] ?? 0).toInt(),
    );
  }
}