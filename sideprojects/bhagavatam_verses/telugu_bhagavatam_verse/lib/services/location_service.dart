import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Handles GPS location with permission flow, caching and fallback.
class LocationService {
  static const String _cachedLatKey = 'cached_latitude';
  static const String _cachedLngKey = 'cached_longitude';

  // Fallback: geographical centre of India
  static const double _fallbackLat = 20.5937;
  static const double _fallbackLng = 78.9629;

  /// Request permission and get current GPS position.
  /// Call this from the UI (foreground) so the dialog can appear.
  Future<({double latitude, double longitude})> getCurrentLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return await _loadCachedOrFallback();

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return await _loadCachedOrFallback();
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return await _loadCachedOrFallback();
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 10),
        ),
      );

      await _cacheCoordinates(position.latitude, position.longitude);
      return (latitude: position.latitude, longitude: position.longitude);
    } catch (_) {
      return await _loadCachedOrFallback();
    }
  }

  /// Load cached coordinates — safe to call from background tasks.
  Future<({double latitude, double longitude})> getCachedLocation() async {
    return await _loadCachedOrFallback();
  }

  /// Returns true if coordinates have been cached from a previous session.
  Future<bool> hasCachedLocation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_cachedLatKey);
  }

  Future<void> _cacheCoordinates(double lat, double lng) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_cachedLatKey, lat);
    await prefs.setDouble(_cachedLngKey, lng);
  }

  Future<({double latitude, double longitude})> _loadCachedOrFallback() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(_cachedLatKey);
    final lng = prefs.getDouble(_cachedLngKey);
    if (lat != null && lng != null) return (latitude: lat, longitude: lng);
    return (latitude: _fallbackLat, longitude: _fallbackLng);
  }
}