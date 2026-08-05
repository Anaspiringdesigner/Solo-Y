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
}