import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';

class DataTransferService {
  static const String notificationChannelId = 'biofeedback_data_transfer';
  static const int foregroundNotificationId = 4242;

  static final FlutterBackgroundService _service = FlutterBackgroundService();

  static bool _configured = false;
  static String _sensorType = '';

  static Future<void> initialize() async {
    if (_configured) return;

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        autoStartOnBoot: false,
        foregroundServiceNotificationId: foregroundNotificationId,
        initialNotificationTitle: 'Biofeedback',
        initialNotificationContent: 'Background data transfer ready',
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
        notificationChannelId: notificationChannelId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );

    _configured = true;
  }

  static Future<void> start() async {
    if (!_configured) {
      await initialize();
    }

    final running = await _service.isRunning();
    if (running) {
      _service.invoke('heartbeat');
      return;
    }

    await _service.startService();
  }

  static Future<void> stop() async {
    final running = await _service.isRunning();
    if (!running) return;

    _service.invoke('stopService');
  }

  static Future<bool> isRunning() async {
    return _service.isRunning();
  }

  static Future<void> _updateSensorType(String sensorType) async {
    _sensorType = sensorType.trim().toLowerCase();
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    return true;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) {
    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
      service.setForegroundNotificationInfo(
        title: 'Biofeedback session active',
        content: 'Streaming physiological data in background',
      );
    }

    Timer.periodic(const Duration(seconds: 20), (timer) {
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'Biofeedback session active',
          content: 'Streaming physiological data in background',
        );
      }

      service.invoke('status', {
        'ok': true,
        'ts': DateTime.now().toIso8601String(),
        'sensor_type': _sensorType,
      });
    });

    service.on('heartbeat').listen((event) {
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'Biofeedback session active',
          content: 'Background transfer is running',
        );
      }
    });

    // Safe payload handling for:
    // - service.invoke('reload_sensor', {'sensor_type': 'esp32'})
    // - service.invoke('reload_sensor', 'esp32')
    service.on('reload_sensor').listen((event) async {
      final dynamic e = event;

      if (e is Map<String, dynamic>) {
        await _updateSensorType((e['sensor_type'] ?? '').toString());
      } else if (e is String) {
        await _updateSensorType(e);
      } else {
        await _updateSensorType('');
      }

      service.invoke('sensor_reloaded', {'sensor_type': _sensorType});
    });

    service.on('stopService').listen((event) {
      service.stopSelf();
    });
  }
}