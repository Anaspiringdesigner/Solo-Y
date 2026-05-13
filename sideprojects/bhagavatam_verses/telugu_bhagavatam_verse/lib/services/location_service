import 'dart:math';

/// Pure Dart NOAA Solar Algorithm — null-safe, zero dependencies.
/// Reference: https://gml.noaa.gov/grad/solcalc/solareqns.PDF
class SunriseService {
  /// Returns the local sunrise [DateTime] for a given [date],
  /// [latitude] and [longitude].
  /// Falls back to 6:00 AM local time if calculation fails
  /// (e.g. extreme latitudes with no sunrise).
  static DateTime getSunrise({
    required DateTime date,
    required double latitude,
    required double longitude,
  }) {
    try {
      final utcMinutes = _calcSunriseUtcMinutes(date, latitude, longitude);
      if (utcMinutes == null) return _fallback(date);

      final utcHour = utcMinutes ~/ 60;
      final utcMin = (utcMinutes % 60).round();

      final offset = date.timeZoneOffset;
      final sunriseUtc = DateTime.utc(
        date.year,
        date.month,
        date.day,
        utcHour,
        utcMin,
      );
      return sunriseUtc.add(offset);
    } catch (_) {
      return _fallback(date);
    }
  }

  /// Returns the [Duration] from now until the next sunrise
  /// at the given [latitude] and [longitude].
  static Duration durationUntilNextSunrise({
    required double latitude,
    required double longitude,
  }) {
    final now = DateTime.now();

    DateTime sunrise = getSunrise(
      date: now,
      latitude: latitude,
      longitude: longitude,
    );

    // If today's sunrise has already passed, compute tomorrow's
    if (now.isAfter(sunrise)) {
      final tomorrow = now.add(const Duration(days: 1));
      sunrise = getSunrise(
        date: tomorrow,
        latitude: latitude,
        longitude: longitude,
      );
    }

    return sunrise.difference(now);
  }

  // ── NOAA internals ──────────────────────────────────────────────────────────

  static double? _calcSunriseUtcMinutes(
      DateTime date, double lat, double lng) {
    final jd = _toJulianDay(date);
    final t = _julianCentury(jd);

    final eqTime = _equationOfTime(t);
    final solarDec = _sunDeclination(t);

    final latRad = _toRad(lat);
    final sdRad = _toRad(solarDec);

    final haCos = cos(_toRad(90.833)) / (cos(latRad) * cos(sdRad)) -
        tan(latRad) * tan(sdRad);

    if (haCos < -1 || haCos > 1) return null;

    final haDeg = _toDeg(acos(haCos));
    return 720 - 4 * (lng + haDeg) - eqTime;
  }

  static double _equationOfTime(double t) {
    final epsilon = _obliquityCorrection(t);
    final l0 = _geomMeanLongSun(t);
    final e = _eccentricityEarthOrbit(t);
    final m = _geomMeanAnomalySun(t);

    double y = tan(_toRad(epsilon / 2));
    y *= y;

    final l0Rad = _toRad(l0);
    final mRad = _toRad(m);

    final eqTime = y * sin(2 * l0Rad) -
        2 * e * sin(mRad) +
        4 * e * y * sin(mRad) * cos(2 * l0Rad) -
        0.5 * y * y * sin(4 * l0Rad) -
        1.25 * e * e * sin(2 * mRad);

    return _toDeg(eqTime) * 4;
  }

  static double _sunDeclination(double t) {
    final e = _obliquityCorrection(t);
    final lambda = _sunApparentLong(t);
    return _toDeg(asin(sin(_toRad(e)) * sin(_toRad(lambda))));
  }

  static double _sunApparentLong(double t) {
    final omega = 125.04 - 1934.136 * t;
    return _sunTrueLong(t) - 0.00569 - 0.00478 * sin(_toRad(omega));
  }

  static double _sunTrueLong(double t) =>
      _geomMeanLongSun(t) + _sunEqOfCenter(t);

  static double _sunEqOfCenter(double t) {
    final m = _toRad(_geomMeanAnomalySun(t));
    return sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
        sin(2 * m) * (0.019993 - 0.000101 * t) +
        sin(3 * m) * 0.000289;
  }

  static double _geomMeanLongSun(double t) =>
      (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360;

  static double _geomMeanAnomalySun(double t) =>
      357.52911 + t * (35999.05029 - 0.0001537 * t);

  static double _eccentricityEarthOrbit(double t) =>
      0.016708634 - t * (0.000042037 + 0.0000001267 * t);

  static double _obliquityCorrection(double t) {
    final e0 = 23.0 +
        (26.0 +
                (21.448 -
                        t * (46.8150 + t * (0.00059 - t * 0.001813))) /
                    60) /
            60;
    final omega = 125.04 - 1934.136 * t;
    return e0 + 0.00256 * cos(_toRad(omega));
  }

  static double _toJulianDay(DateTime date) {
    final d = DateTime.utc(date.year, date.month, date.day);
    final a = (14 - d.month) ~/ 12;
    final y = d.year + 4800 - a;
    final m = d.month + 12 * a - 3;
    return d.day +
        (153 * m + 2) ~/ 5 +
        365 * y +
        y ~/ 4 -
        y ~/ 100 +
        y ~/ 400 -
        32045.0;
  }

  static double _julianCentury(double jd) => (jd - 2451545.0) / 36525.0;

  static double _toRad(double deg) => deg * pi / 180.0;
  static double _toDeg(double rad) => rad * 180.0 / pi;

  static DateTime _fallback(DateTime date) =>
      DateTime(date.year, date.month, date.day, 6, 0);
}