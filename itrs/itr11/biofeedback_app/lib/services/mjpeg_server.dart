// lib/services/mjpeg_server.dart

import 'dart:async';
import 'dart:typed_data';
import 'dart:io' as dart_io;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;

class MjpegServer {
  static final MjpegServer _instance = MjpegServer._internal();
  factory MjpegServer() => _instance;
  MjpegServer._internal();

  CameraController? _cameraController;
  dart_io.HttpServer? _server;

  bool _isRunning = false;
  bool _isStreaming = false;
  bool _isProcessingFrame = false;

  CameraLensDirection _currentLens = CameraLensDirection.front;

  Uint8List? _latestFrame;
  final List<StreamController<List<int>>> _clients = [];

  String _boundIp = '0.0.0.0';

  bool get isRunning => _isRunning;
  bool get isStreaming => _isStreaming;
  CameraLensDirection get currentLens => _currentLens;
  CameraController? get controller => _cameraController;

  static const int serverPort = 8081;

  // Continuous-first tuning
  static const ResolutionPreset preset = ResolutionPreset.medium;
  static const int jpegQuality = 58;
  static const int maxEncodeWidth = 640; // keep encode light for smoother fps

  String get streamUrl => 'http://$_boundIp:$serverPort/camera';

  // ── Resolve current local IPv4 ─────────────────────────
  Future<String> _getLocalIpv4() async {
    try {
      final ifaces = await dart_io.NetworkInterface.list(
        type: dart_io.InternetAddressType.IPv4,
        includeLoopback: false,
      );

      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!ip.startsWith('127.')) return ip;
        }
      }
    } catch (e) {
      debugPrint('[MJPEG] IP resolve error: $e');
    }
    return '0.0.0.0';
  }

  // ── Initialize Camera ─────────────────────
  Future<bool> initCamera({
    CameraLensDirection lens = CameraLensDirection.front,
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

      if (_cameraController != null) {
        await _stopCameraStream();
        await _cameraController!.dispose();
      }

      _cameraController = CameraController(
        camera,
        preset,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();

      debugPrint('[MJPEG] Camera ready: ${lens.name}');
      return true;
    } catch (e) {
      debugPrint('[MJPEG] Camera init error: $e');
      return false;
    }
  }

  // ── Start Camera Stream ───────────────────
  Future<void> _startCameraStream() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (_cameraController!.value.isStreamingImages) {
      return;
    }

    await _cameraController!.startImageStream((CameraImage image) {
      _processCameraImage(image);
    });

    debugPrint('[MJPEG] Camera image stream started');
  }

  // ── Stop Camera Stream ────────────────────
  Future<void> _stopCameraStream() async {
    if (_cameraController != null && _cameraController!.value.isStreamingImages) {
      await _cameraController!.stopImageStream();
      debugPrint('[MJPEG] Camera image stream stopped');
    }
  }

  // ── Process frame with drop policy ────────
  void _processCameraImage(CameraImage image) {
    // Critical for continuity: never queue slow frame processing
    if (_isProcessingFrame) return;
    _isProcessingFrame = true;

    try {
      final jpegBytes = _cameraImageToJpegFast(image);
      if (jpegBytes == null || jpegBytes.isEmpty) return;

      _latestFrame = jpegBytes;
      _pushFrameToClients(jpegBytes);
    } catch (e) {
      debugPrint('[MJPEG] Frame process error: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  // ── Convert CameraImage -> JPEG (fast path) ───────────────
  Uint8List? _cameraImageToJpegFast(CameraImage image) {
    try {
      img.Image rgb;

      if (image.format.group == ImageFormatGroup.yuv420 && image.planes.length >= 3) {
        rgb = _yuv420ToRgb(image);
      } else if (image.format.group == ImageFormatGroup.bgra8888 &&
          image.planes.isNotEmpty) {
        final plane = image.planes[0];
        rgb = img.Image.fromBytes(
          width: image.width,
          height: image.height,
          bytes: plane.bytes.buffer,
          order: img.ChannelOrder.bgra,
        );
      } else if (image.format.group == ImageFormatGroup.jpeg &&
          image.planes.isNotEmpty) {
        final decoded = img.decodeJpg(image.planes[0].bytes);
        if (decoded == null) return null;
        rgb = decoded;
      } else {
        return null;
      }

      // Keep native aspect ratio. Resize only if too wide (reduce CPU).
      if (rgb.width > maxEncodeWidth) {
        final newHeight = (rgb.height * (maxEncodeWidth / rgb.width)).round();
        rgb = img.copyResize(
          rgb,
          width: maxEncodeWidth,
          height: newHeight,
          interpolation: img.Interpolation.linear,
        );
      }

      return Uint8List.fromList(
        img.encodeJpg(rgb, quality: jpegQuality),
      );
    } catch (e) {
      debugPrint('[MJPEG] Conversion error: $e');
      return null;
    }
  }

  img.Image _yuv420ToRgb(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final out = img.Image(width: width, height: height);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final yBytes = yPlane.bytes;
    final uBytes = uPlane.bytes;
    final vBytes = vPlane.bytes;

    final yRowStride = yPlane.bytesPerRow;
    final uRowStride = uPlane.bytesPerRow;
    final vRowStride = vPlane.bytesPerRow;
    final uPixelStride = uPlane.bytesPerPixel ?? 1;
    final vPixelStride = vPlane.bytesPerPixel ?? 1;

    for (int y = 0; y < height; y++) {
      final uvRow = y >> 1;
      for (int x = 0; x < width; x++) {
        final yIndex = y * yRowStride + x;
        final uvCol = x >> 1;

        final uIndex = uvRow * uRowStride + uvCol * uPixelStride;
        final vIndex = uvRow * vRowStride + uvCol * vPixelStride;

        if (yIndex >= yBytes.length || uIndex >= uBytes.length || vIndex >= vBytes.length) {
          continue;
        }

        final yp = yBytes[yIndex];
        final up = uBytes[uIndex];
        final vp = vBytes[vIndex];

        int r = (yp + 1.402 * (vp - 128)).round();
        int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).round();
        int b = (yp + 1.772 * (up - 128)).round();

        if (r < 0) r = 0; else if (r > 255) r = 255;
        if (g < 0) g = 0; else if (g > 255) g = 255;
        if (b < 0) b = 0; else if (b > 255) b = 255;

        out.setPixelRgb(x, y, r, g, b);
      }
    }

    return out;
  }

  // ── Push frame to all clients ─────────────
  void _pushFrameToClients(Uint8List bytes) {
    if (_clients.isEmpty) return;

    const boundary = '--mjpegframe\r\nContent-Type: image/jpeg\r\n';
    final header = '$boundary'
        'Content-Length: ${bytes.length}\r\n\r\n';

    final dead = <StreamController<List<int>>>[];

    for (final c in _clients) {
      if (c.isClosed) {
        dead.add(c);
        continue;
      }
      try {
        c.add(header.codeUnits);
        c.add(bytes);
        c.add('\r\n'.codeUnits);
      } catch (_) {
        dead.add(c);
      }
    }

    for (final d in dead) {
      _clients.remove(d);
    }
  }

  // ── Switch Camera ─────────────────────────
  Future<void> switchCamera() async {
    final newLens = _currentLens == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front;

    final wasStreaming = _isStreaming;
    if (wasStreaming) await _stopCameraStream();

    await initCamera(lens: newLens);

    if (wasStreaming) await _startCameraStream();
  }

  // ── Start HTTP Server ─────────────────────
  Future<bool> startServer() async {
    if (_isRunning) return true;

    try {
      final router = shelf_router.Router();

      router.get('/camera', _handleMjpegRequest);

      router.get('/status', (Request req) {
        return Response.ok(
          '{"ok":true,'
          '"streaming":$_isStreaming,'
          '"lens":"${_currentLens.name}",'
          '"clients":${_clients.length},'
          '"url":"$streamUrl",'
          '"quality":$jpegQuality,'
          '"max_width":$maxEncodeWidth}',
          headers: {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
          },
        );
      });

      router.get('/ping', (Request req) => Response.ok('pong'));

      final handler = const Pipeline().addHandler(router.call);

      _server = await shelf_io.serve(
        handler,
        dart_io.InternetAddress.anyIPv4,
        serverPort,
      );

      _boundIp = await _getLocalIpv4();
      _isRunning = true;

      debugPrint('[MJPEG] Server at $streamUrl');
      return true;
    } catch (e) {
      debugPrint('[MJPEG] Server error: $e');
      return false;
    }
  }

  // ── Stop Server ───────────────────────────
  Future<void> stopServer() async {
    await stopStreaming();
    await _server?.close(force: true);
    _server = null;
    _isRunning = false;
    _boundIp = '0.0.0.0';
  }

  // ── Start Streaming ───────────────────────
  Future<bool> startStreaming() async {
    if (!_isRunning) {
      final ok = await startServer();
      if (!ok) return false;
    }

    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      final ok = await initCamera(lens: _currentLens);
      if (!ok) return false;
    }

    await _startCameraStream();
    _isStreaming = true;
    debugPrint('[MJPEG] Streaming -> $streamUrl');
    return true;
  }

  // ── Stop Streaming ────────────────────────
  Future<void> stopStreaming() async {
    _isStreaming = false;
    await _stopCameraStream();
    _closeAllClients();
    _latestFrame = null;
  }

  void _closeAllClients() {
    for (final c in _clients) {
      if (!c.isClosed) c.close();
    }
    _clients.clear();
  }

  // ── MJPEG endpoint ────────────────────────
  Future<Response> _handleMjpegRequest(Request request) async {
    if (!_isStreaming) {
      return Response(
        503,
        body: 'Stream not active',
        headers: {'Access-Control-Allow-Origin': '*'},
      );
    }

    final ctrl = StreamController<List<int>>();
    _clients.add(ctrl);

    ctrl.onCancel = () {
      _clients.remove(ctrl);
      debugPrint('[MJPEG] Client left (${_clients.length} left)');
    };

    debugPrint('[MJPEG] Client connected (${_clients.length} total)');

    if (_latestFrame != null) {
      const boundary = '--mjpegframe\r\nContent-Type: image/jpeg\r\n';
      final header = '$boundary'
          'Content-Length: ${_latestFrame!.length}\r\n\r\n';
      ctrl.add(header.codeUnits);
      ctrl.add(_latestFrame!);
      ctrl.add('\r\n'.codeUnits);
    }

    return Response(
      200,
      body: ctrl.stream,
      headers: {
        'Content-Type': 'multipart/x-mixed-replace; boundary=mjpegframe',
        'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
        'Pragma': 'no-cache',
        'Expires': '0',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no',
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