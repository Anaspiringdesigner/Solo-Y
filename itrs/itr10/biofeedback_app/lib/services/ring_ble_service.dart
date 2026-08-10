import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import '../models/ring_sample_packet.dart';

class RingBleService {
  static final RingBleService _instance = RingBleService._internal();
  factory RingBleService() => _instance;
  RingBleService._internal();

  final FlutterReactiveBle _ble = FlutterReactiveBle();

  static final Uuid serviceUuid = Uuid.parse("12345678-1234-1234-1234-1234567890ab");
  static final Uuid sampleCharUuid = Uuid.parse("12345678-1234-1234-1234-1234567890ac");

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;

  final _packetCtrl = StreamController<RingSamplePacket>.broadcast();
  Stream<RingSamplePacket> get packets => _packetCtrl.stream;

  Future<void> start() async {
    await stop();
    debugPrint('[BLE] scan start');

    _scanSub = _ble.scanForDevices(withServices: []).listen((d) async {
      final name = d.name.toLowerCase();
      final hasName = name.contains("esp32-max30102") || name.contains("esp32");
      final hasSvc = d.serviceUuids.contains(serviceUuid);

      if (hasName || hasSvc) {
        debugPrint('[BLE] candidate found: name=${d.name} id=${d.id} services=${d.serviceUuids}');
        await _scanSub?.cancel();
        _scanSub = null;
        await _connect(d.id);
      }
    }, onError: (e) {
      debugPrint('[BLE] scan error: $e');
    });
  }

  Future<void> _connect(String deviceId) async {
    await _connSub?.cancel();
    debugPrint('[BLE] connecting -> $deviceId');

    _connSub = _ble.connectToDevice(
      id: deviceId,
      connectionTimeout: const Duration(seconds: 10),
    ).listen((u) async {
      if (u.connectionState == DeviceConnectionState.connected) {
        debugPrint('[BLE] connected: $deviceId');
        await _subscribeSamples(deviceId);
      } else if (u.connectionState == DeviceConnectionState.disconnected) {
        debugPrint('[BLE] disconnected');
        await _notifySub?.cancel();
        _notifySub = null;
        Future.delayed(const Duration(seconds: 2), () => start());
      }
    }, onError: (e) {
      debugPrint('[BLE] connect error: $e');
      Future.delayed(const Duration(seconds: 2), () => start());
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
    });
  }

  Future<void> stop() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _connSub?.cancel();
    _connSub = null;
    await _notifySub?.cancel();
    _notifySub = null;
  }

  Future<void> dispose() async {
    await stop();
    await _packetCtrl.close();
  }
}