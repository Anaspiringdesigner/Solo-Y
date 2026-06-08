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
    as shelf_router;  // ← prefix to avoid Router conflict

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

  // ── Initialize Camera ─────────────────────────
  Future<bool> initCamera({
    CameraLensDirection lens =
        CameraLensDirection.front,
  }) async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        debugPrint('[MJPEG] No cameras found');
        return false;
      }

      final camera = cameras.firstWhere(
        (c) => c.lensDirection == lens,
        orElse: () => cameras.first,
      );

      _currentLens = lens;
      await _cameraController?.dispose();

      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio:      false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _cameraController!.initialize();
      debugPrint('[MJPEG] Camera ready: '
          '${lens == CameraLensDirection.front
              ? "Front" : "Back"}');
      return true;

    } catch (e) {
      debugPrint('[MJPEG] Camera error: $e');
      return false;
    }
  }

  // ── Switch Camera ─────────────────────────────
  Future<void> switchCamera() async {
    final newLens =
        _currentLens == CameraLensDirection.front
            ? CameraLensDirection.back
            : CameraLensDirection.front;

    final wasStreaming = _isStreaming;
    if (wasStreaming) {
      _isStreaming = false;
      await Future.delayed(
          const Duration(milliseconds: 200));
    }

    await initCamera(lens: newLens);

    if (wasStreaming) {
      _isStreaming = true;
    }
  }

  // ── Start HTTP Server ─────────────────────────
  Future<bool> startServer() async {
    if (_isRunning) {
      debugPrint('[MJPEG] Already running');
      return true;
    }

    try {
      // Use shelf_router prefix to avoid
      // conflict with Flutter's Router
      final router = shelf_router.Router();

      router.get('/camera',
          _handleMjpegRequest);

      router.get('/status', (Request req) {
        return Response.ok(
          '{"ok":true,'
          '"streaming":$_isStreaming,'
          '"lens":"${_currentLens.name}",'
          '"url":"$streamUrl"}',
          headers: {
            'Content-Type':
                'application/json',
            'Access-Control-Allow-Origin':
                '*',
          },
        );
      });

      router.get('/ping', (Request req) {
        return Response.ok('pong');
      });

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
      debugPrint('[MJPEG] Server error: $e');
      return false;
    }
  }

  // ── Stop Server ───────────────────────────────
  Future<void> stopServer() async {
    _isStreaming = false;
    _closeAllClients();
    await _server?.close(force: true);
    _server    = null;
    _isRunning = false;
    debugPrint('[MJPEG] Server stopped');
  }

  // ── Start Streaming ───────────────────────────
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

    _isStreaming = true;
    debugPrint('[MJPEG] Streaming → '
        '$streamUrl');
    return true;
  }

  // ── Stop Streaming ────────────────────────────
  Future<void> stopStreaming() async {
    _isStreaming = false;
    _closeAllClients();
    debugPrint('[MJPEG] Streaming stopped');
  }

  // ── Close All Clients ─────────────────────────
  void _closeAllClients() {
    for (final c in _clients) {
      if (!c.isClosed) c.close();
    }
    _clients.clear();
  }

  // ── Handle MJPEG Request ──────────────────────
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
          '(${_clients.length} remaining)');
    };

    debugPrint('[MJPEG] Client connected '
        '(${_clients.length} total)');

    _frameLoop(ctrl);

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

  // ── Frame Capture Loop ────────────────────────
  Future<void> _frameLoop(
      StreamController<List<int>> ctrl)
      async {
    const boundary =
        '--mjpegframe\r\n'
        'Content-Type: image/jpeg\r\n';

    while (_isStreaming && !ctrl.isClosed) {
      try {
        if (_cameraController == null ||
            !_cameraController!
                .value.isInitialized) {
          await Future.delayed(
              const Duration(
                  milliseconds: 100));
          continue;
        }

        final XFile xfile =
            await _cameraController!
                .takePicture();
        final Uint8List bytes =
            await xfile.readAsBytes();

        if (ctrl.isClosed) break;

        ctrl.add(
          (boundary +
           'Content-Length: '
           '${bytes.length}\r\n\r\n')
              .codeUnits,
        );
        ctrl.add(bytes);
        ctrl.add('\r\n'.codeUnits);

        // ~15 fps
        await Future.delayed(
            const Duration(
                milliseconds: 66));

      } catch (e) {
        if (!ctrl.isClosed) {
          debugPrint(
              '[MJPEG] Frame error: $e');
          await Future.delayed(
              const Duration(
                  milliseconds: 100));
        }
      }
    }

    if (!ctrl.isClosed) {
      await ctrl.close();
    }
  }

  // ── Dispose ───────────────────────────────────
  Future<void> dispose() async {
    await stopServer();
    await _cameraController?.dispose();
    _cameraController = null;
  }
}