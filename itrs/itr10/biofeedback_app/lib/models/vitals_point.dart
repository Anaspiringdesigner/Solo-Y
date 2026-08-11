class VitalsPoint {
  final DateTime ts;
  final double hr;
  final double hrv;
  final double br;

  VitalsPoint({
    required this.ts,
    required this.hr,
    required this.hrv,
    required this.br,
  });

  Map<String, dynamic> toJson() => {
        'ts': ts.toUtc().toIso8601String(),
        'hr': hr,
        'hrv': hrv,
        'br': br,
      };

  factory VitalsPoint.fromJson(Map<dynamic, dynamic> json) {
    return VitalsPoint(
      ts: DateTime.parse((json['ts'] ?? DateTime.now().toUtc().toIso8601String()).toString()).toUtc(),
      hr: (json['hr'] ?? 0).toDouble(),
      hrv: (json['hrv'] ?? 0).toDouble(),
      br: (json['br'] ?? 0).toDouble(),
    );
  }
}