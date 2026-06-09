// lib/services/mjpeg_server.dart

import 'dart:async';
import 'dart:typed_data';
import 'dart:io' as dart_io;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart'
    as shelf_io;
import 'package:shelf_router/shelf_router.dart'
    as shelf_router;

class MjpegServer {
  static final MjpegServer _instance =
      MjpegServer._internal();
  factory MjpegServer() => _instance;
  MjpegServer._internal();

  CameraController?   _cameraController;
  dart_io.HttpServer? _server;
  bool                _isRunning   = false;
  bool                _isStreaming = false;
  CameraLensDirection _currentLens =
      CameraLensDirection.front;

  // Latest JPEG frame from camera
  Uint8List? _latestFrame;

  // Active client stream controllers
  final List<StreamController<List<int>>>
      _clients = [];

  bool get isRunning   => _isRunning;
  bool get isStreaming => _isStreaming;
  CameraLensDirection get currentLens =>
      _currentLens;
  CameraController? get controller =>
      _cameraController;

  static const String phoneIp   =
      '100.122.118.37';
  static const int    serverPort = 8081;

  String get streamUrl =>
      'http://$phoneIp:$serverPort/camera';

  // ── Initialize Camera ─────────────────────
  Future<bool> initCamera({
    CameraLensDirection lens =
        CameraLensDirection.front,
  }) async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        debugPrint('[MJPEG] No cameras');
        return false;
      }

      final camera = cameras.firstWhere(
        (c) => c.lensDirection == lens,
        orElse: () => cameras.first,
      );

      _currentLens = lens;

      // Stop existing stream first
      if (_cameraController != null) {
        await _stopCameraStream();
        await _cameraController!.dispose();
      }

      // Use JPEG format for direct streaming
      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio:      false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _cameraController!.initialize();

      debugPrint('[MJPEG] Camera ready: '
          '${lens.name}');
      return true;

    } catch (e) {
      debugPrint('[MJPEG] Camera error: $e');
      return false;
    }
  }

  // ── Start Camera Image Stream ─────────────
  Future<void> _startCameraStream() async {
    if (_cameraController == null ||
        !_cameraController!
            .value.isInitialized) {
      return;
    }

    if (_cameraController!
        .value.isStreamingImages) {
      return;
    }

    await _cameraController!
        .startImageStream((CameraImage image) {
      // Convert camera image to JPEG bytes
      _processCameraImage(image);
    });

    debugPrint('[MJPEG] Camera image '
        'stream started');
  }

  // ── Stop Camera Image Stream ──────────────
  Future<void> _stopCameraStream() async {
    if (_cameraController != null &&
        _cameraController!
            .value.isStreamingImages) {
      await _cameraController!
          .stopImageStream();
      debugPrint('[MJPEG] Camera image '
          'stream stopped');
    }
  }

  // ── Process Camera Frame ──────────────────
  void _processCameraImage(
      CameraImage image) {
    try {
      // For JPEG format group,
      // planes[0] contains JPEG bytes directly
      if (image.format.group ==
          ImageFormatGroup.jpeg) {
        final bytes = image.planes[0].bytes;
        _latestFrame = bytes;

        // Push to all connected clients
        _pushFrameToClients(bytes);
      }
    } catch (e) {
      debugPrint('[MJPEG] Frame error: $e');
    }
  }

  // ── Push Frame to All Clients ─────────────
  void _pushFrameToClients(Uint8List bytes) {
    if (_clients.isEmpty) return;

    const boundary =
        '--mjpegframe\r\n'
        'Content-Type: image/jpeg\r\n';

    final header =
        '$boundary'
        'Content-Length: '
        '${bytes.length}\r\n\r\n';

    final deadClients = <StreamController>[];

    for (final ctrl in _clients) {
      if (ctrl.isClosed) {
        deadClients.add(ctrl);
        continue;
      }
      try {
        ctrl.add(header.codeUnits);
        ctrl.add(bytes);
        ctrl.add('\r\n'.codeUnits);
      } catch (e) {
        deadClients.add(ctrl);
      }
    }

    // Remove dead clients
    for (final c in deadClients) {
      _clients.remove(c);
    }
  }

  // ── Switch Camera ─────────────────────────
  Future<void> switchCamera() async {
    final newLens =
        _currentLens ==
                CameraLensDirection.front
            ? CameraLensDirection.back
            : CameraLensDirection.front;

    final wasStreaming = _isStreaming;
    if (wasStreaming) {
      await _stopCameraStream();
    }

    await initCamera(lens: newLens);

    if (wasStreaming) {
      await _startCameraStream();
    }
  }

  // ── Start HTTP Server ─────────────────────
  Future<bool> startServer() async {
    if (_isRunning) return true;

    try {
      final router = shelf_router.Router();

      // MJPEG stream endpoint
      router.get('/camera',
          _handleMjpegRequest);

      // Status endpoint
      router.get('/status',
          (Request req) {
        return Response.ok(
          '{"ok":true,'
          '"streaming":$_isStreaming,'
          '"lens":"${_currentLens.name}",'
          '"clients":${_clients.length},'
          '"url":"$streamUrl"}',
          headers: {
            'Content-Type':
                'application/json',
            'Access-Control-Allow-Origin':
                '*',
          },
        );
      });

      router.get('/ping',
          (Request req) =>
              Response.ok('pong'));

      final handler = const Pipeline()
          .addHandler(router.call);

      _server = await shelf_io.serve(
        handler,
        dart_io.InternetAddress.anyIPv4,
        serverPort,
      );

      _isRunning = true;
      debugPrint('[MJPEG] Server at '
          '$streamUrl');
      return true;

    } catch (e) {
      debugPrint(
          '[MJPEG] Server error: $e');
      return false;
    }
  }

  // ── Stop Server ───────────────────────────
  Future<void> stopServer() async {
    await stopStreaming();
    await _server?.close(force: true);
    _server    = null;
    _isRunning = false;
  }

  // ── Start Streaming ───────────────────────
  Future<bool> startStreaming() async {
    if (!_isRunning) {
      final ok = await startServer();
      if (!ok) return false;
    }

    if (_cameraController == null ||
        !_cameraController!
            .value.isInitialized) {
      final ok = await initCamera(
          lens: _currentLens);
      if (!ok) return false;
    }

    // Start continuous frame capture
    await _startCameraStream();

    _isStreaming = true;
    debugPrint('[MJPEG] Streaming → '
        '$streamUrl');
    return true;
  }

  // ── Stop Streaming ────────────────────────
  Future<void> stopStreaming() async {
    _isStreaming = false;
    await _stopCameraStream();
    _closeAllClients();
    _latestFrame = null;
  }

  // ── Close All Clients ─────────────────────
  void _closeAllClients() {
    for (final c in _clients) {
      if (!c.isClosed) c.close();
    }
    _clients.clear();
  }

  // ── Handle MJPEG HTTP Request ─────────────
  Future<Response> _handleMjpegRequest(
      Request request) async {
    if (!_isStreaming) {
      return Response(503,
          body: 'Stream not active',
          headers: {
            'Access-Control-Allow-Origin':
                '*',
          });
    }

    final ctrl =
        StreamController<List<int>>();
    _clients.add(ctrl);

    ctrl.onCancel = () {
      _clients.remove(ctrl);
      debugPrint('[MJPEG] Client left '
          '(${_clients.length} left)');
    };

    debugPrint('[MJPEG] Client connected '
        '(${_clients.length} total)');

    // Send latest frame immediately
    // so client sees something right away
    if (_latestFrame != null) {
      const boundary =
          '--mjpegframe\r\n'
          'Content-Type: image/jpeg\r\n';
      final header =
          '$boundary'
          'Content-Length: '
          '${_latestFrame!.length}\r\n\r\n';
      ctrl.add(header.codeUnits);
      ctrl.add(_latestFrame!);
      ctrl.add('\r\n'.codeUnits);
    }

    return Response(
      200,
      body: ctrl.stream,
      headers: {
        'Content-Type':
            'multipart/x-mixed-replace; '
            'boundary=mjpegframe',
        'Cache-Control':   'no-cache',
        'Connection':      'keep-alive',
        'Pragma':          'no-cache',
        'Access-Control-Allow-Origin': '*',
      },
    );
  }

  // ── Dispose ───────────────────────────────
  Future<void> dispose() async {
    await stopServer();
    await _cameraController?.dispose();
    _cameraController = null;
  }
}