import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import '../models/ring_sample_packet.dart';
import '../constants.dart';

void _log(String m) {
  if (AppConstants.verboseLogging || !kReleaseMode) debugPrint(m);
}

class RingBleService {
  static final RingBleService _instance = RingBleService._internal();
  factory RingBleService() => _instance;
  RingBleService._internal();

  final FlutterReactiveBle _ble = FlutterReactiveBle();

  // NOTE: these UUIDs match the device firmware used in itr10
  static final Uuid serviceUuid = Uuid.parse("12345678-1234-1234-1234-1234567890ab");
  static final Uuid sampleCharUuid = Uuid.parse("12345678-1234-1234-1234-1234567890ac");

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BleStatus>? _statusSub;

  int _reconnectAttempts = 0;
  final int _maxBackoffSeconds = 64;
  bool _disposed = false;

  final _packetCtrl = StreamController<RingSamplePacket>.broadcast();
  Stream<RingSamplePacket> get packets => _packetCtrl.stream;

  Future<void> start() async {
    await stop();
    if (_disposed) return;

    _log('[BLE] start: subscribing to BLE status');
    // Listen for BLE adapter status and only scan when ready
    _statusSub = _ble.statusStream.listen((s) {
      _log('[BLE] adapter status: $s');
      if (s == BleStatus.ready) {
        _startScan();
      } else if (s == BleStatus.unauthorized || s == BleStatus.unknown) {
        // adapter not usable - stop any existing activity
        _cancelScan();
        _cancelConnection();
      }
    }, onError: (e) {
      _log('[BLE] status error: $e');
    });

    // start immediate scan attempt
    _startScan();
  }

  void _startScan() {
    if (_scanSub != null) return;
    _log('[BLE] scan start');

    try {
      // Prefer scanning for known serviceUuid — faster and more reliable.
      _scanSub = _ble.scanForDevices(withServices: [serviceUuid]).listen((d) async {
        try {
          final name = d.name.toLowerCase();
          final hasName = name.contains('esp32-max30102') || name.contains('esp32');
          final hasSvc = d.serviceUuids.contains(serviceUuid);

          if (hasSvc || hasName) {
            _log('[BLE] candidate found: name=${d.name} id=${d.id} services=${d.serviceUuids}');
            await _cancelScan();
            await _connect(d.id);
          }
        } catch (e) {
          debugPrint('[BLE] scan callback error: $e');
        }
      }, onError: (e) {
        _log('[BLE] scan error: $e');
        _cancelScan();
        _scheduleReconnect();
      });

      // safety timeout: stop scan after 20s to allow backoff and reduce battery
      Future.delayed(const Duration(seconds: 20), () async {
        if (_scanSub != null) {
          _log('[BLE] scan timeout - restarting scan');
          await _cancelScan();
          _scheduleReconnect();
        }
      });
    } catch (e) {
      debugPrint('[BLE] start scan failed: $e');
      _scheduleReconnect();
    }
  }

  Future<void> _cancelScan() async {
    try {
      await _scanSub?.cancel();
    } catch (_) {}
    _scanSub = null;
  }

  Future<void> _connect(String deviceId) async {
    await _cancelConnection();
    _log('[BLE] connecting -> $deviceId');

    try {
      _connSub = _ble.connectToDevice(
        id: deviceId,
        connectionTimeout: const Duration(seconds: 10),
      ).listen((u) async {
        if (_disposed) return;
        if (u.connectionState == DeviceConnectionState.connected) {
          _log('[BLE] connected: $deviceId');
          _reconnectAttempts = 0;
          await _subscribeSamples(deviceId);
        } else if (u.connectionState == DeviceConnectionState.disconnected) {
          _log('[BLE] disconnected');
          await _notifySub?.cancel();
          _notifySub = null;
          _scheduleReconnect();
        }
      }, onError: (e) {
        _log('[BLE] connect error: $e');
        _scheduleReconnect();
      });
    } catch (e) {
      _log('[BLE] connect exception: $e');
      _scheduleReconnect();
    }
  }

  Future<void> _cancelConnection() async {
    try {
      await _connSub?.cancel();
    } catch (_) {}
    _connSub = null;
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectAttempts++;
    final backoff = ((_reconnectAttempts <= 1) ? 1 : (1 << (_reconnectAttempts - 1))).clamp(1, _maxBackoffSeconds);
    debugPrint('[BLE] scheduling reconnect in ${backoff}s (attempt=$_reconnectAttempts)');
    Future.delayed(Duration(seconds: backoff), () {
      if (_disposed) return;
      _startScan();
    });
  }

  Future<void> _subscribeSamples(String deviceId) async {
    final c = QualifiedCharacteristic(
      serviceId: serviceUuid,
      characteristicId: sampleCharUuid,
      deviceId: deviceId,
    );

    await _notifySub?.cancel();
    _notifySub = _ble.subscribeToCharacteristic(c).listen((data) {
      try {
        final pkt = RingSamplePacket.fromBytes(Uint8List.fromList(data));
        _packetCtrl.add(pkt);
      } catch (e) {
        debugPrint('[BLE] parse error: $e');
      }
    }, onError: (e) {
      debugPrint('[BLE] notify error: $e');
      _scheduleReconnect();
    });
  }

  Future<void> stop() async {
    await _cancelScan();
    await _cancelConnection();
    try {
      await _notifySub?.cancel();
    } catch (_) {}
    _notifySub = null;
    try {
      await _statusSub?.cancel();
    } catch (_) {}
    _statusSub = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _packetCtrl.close();
  }
}
