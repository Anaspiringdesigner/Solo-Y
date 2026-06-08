// lib/widgets/camera_stream_widget.dart

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../constants.dart';
import '../services/mjpeg_server.dart';

class CameraStreamWidget extends StatefulWidget {
  const CameraStreamWidget({super.key});

  @override
  State<CameraStreamWidget> createState() =>
      _CameraStreamWidgetState();
}

class _CameraStreamWidgetState
    extends State<CameraStreamWidget> {

  final MjpegServer _server = MjpegServer();
  bool   _isLoading   = false;
  bool   _isStreaming  = false;
  String _statusMsg   = 'Initializing...';

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    setState(() {
      _isLoading  = true;
      _statusMsg  = 'Initializing camera...';
    });

    await _server.initCamera();
    final ok = await _server.startServer();

    if (mounted) {
      setState(() {
        _isLoading = false;
        _statusMsg = ok
            ? 'Camera ready'
            : 'Camera init failed';
      });
    }
  }

  Future<void> _toggleStream() async {
    if (_isStreaming) {
      await _server.stopStreaming();
      if (mounted) {
        setState(() {
          _isStreaming = false;
          _statusMsg   = 'Stream stopped';
        });
      }
    } else {
      setState(() {
        _isLoading = true;
        _statusMsg = 'Starting stream...';
      });

      final ok =
          await _server.startStreaming();

      if (mounted) {
        setState(() {
          _isLoading  = false;
          _isStreaming = ok;
          _statusMsg  = ok
              ? 'Live → TD | '
                '${_server.streamUrl}'
              : 'Failed to start';
        });
      }
    }
  }

  Future<void> _switchCamera() async {
    setState(() {
      _isLoading = true;
      _statusMsg = 'Switching camera...';
    });

    await _server.switchCamera();

    if (mounted) {
      setState(() {
        _isLoading = false;
        _statusMsg = _isStreaming
            ? 'Switched — streaming'
            : 'Camera switched';
      });
    }
  }

  @override
  void dispose() {
    _server.stopStreaming();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(
            AppConstants.surfaceColor),
        borderRadius:
            BorderRadius.circular(16),
        border: Border.all(
          color: _isStreaming
              ? const Color(
                  AppConstants.calmColor)
              : const Color(
                  AppConstants.cardBorder),
          width: _isStreaming ? 2 : 1,
        ),
      ),
      child: Column(
        children: [

          // ── Header ──────────────────────
          Padding(
            padding:
                const EdgeInsets.fromLTRB(
                    16, 12, 16, 8),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(
                      milliseconds: 500),
                  width:  8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isStreaming
                        ? const Color(
                            AppConstants
                                .calmColor)
                        : const Color(
                            AppConstants
                                .textSecondary),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'CAMERA → TD',
                  style: TextStyle(
                    color: const Color(
                        AppConstants
                            .textSecondary),
                    fontSize:      11,
                    fontWeight:
                        FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
                const Spacer(),
                // Switch camera button
                GestureDetector(
                  onTap: _isLoading
                      ? null
                      : _switchCamera,
                  child: Container(
                    padding:
                        const EdgeInsets
                            .all(6),
                    decoration: BoxDecoration(
                      color: const Color(
                              AppConstants
                                  .accentColor)
                          .withValues(
                              alpha: 0.1),
                      borderRadius:
                          BorderRadius
                              .circular(8),
                    ),
                    child: const Icon(
                      Icons.flip_camera_ios,
                      color: Color(
                          AppConstants
                              .accentColor),
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Camera Preview ───────────────
          ClipRRect(
            borderRadius:
                BorderRadius.zero,
            child: AspectRatio(
              aspectRatio: 1.0,
              child: _buildPreview(),
            ),
          ),

          // ── Status + Controls ────────────
          Padding(
            padding:
                const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  _statusMsg,
                  style: TextStyle(
                    color: _isStreaming
                        ? const Color(
                            AppConstants
                                .calmColor)
                        : const Color(
                            AppConstants
                                .textSecondary),
                    fontSize: 11,
                  ),
                  textAlign:
                      TextAlign.center,
                  maxLines:  2,
                  overflow:
                      TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLoading
                        ? null
                        : _toggleStream,
                    style: ElevatedButton
                        .styleFrom(
                      backgroundColor:
                          _isStreaming
                              ? const Color(
                                      AppConstants
                                          .stressColor)
                                  .withValues(
                                      alpha:
                                          0.15)
                              : const Color(
                                      AppConstants
                                          .calmColor)
                                  .withValues(
                                      alpha:
                                          0.15),
                      foregroundColor:
                          _isStreaming
                              ? const Color(
                                  AppConstants
                                      .stressColor)
                              : const Color(
                                  AppConstants
                                      .calmColor),
                      side: BorderSide(
                        color: _isStreaming
                            ? const Color(
                                AppConstants
                                    .stressColor)
                            : const Color(
                                AppConstants
                                    .calmColor),
                      ),
                      shape:
                          RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius
                                .circular(
                                    12),
                      ),
                      padding: const EdgeInsets
                          .symmetric(
                              vertical: 12),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width:  16,
                            height: 16,
                            child:
                                CircularProgressIndicator(
                              strokeWidth:
                                  2,
                            ),
                          )
                        : Text(
                            _isStreaming
                                ? '⏹  Stop Stream'
                                : '▶  Stream to TD',
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (_isLoading) {
      return Container(
        color: const Color(
            AppConstants.bgColor),
        child: const Center(
          child: CircularProgressIndicator(
            color: Color(
                AppConstants.accentColor),
          ),
        ),
      );
    }

    if (_server.controller != null &&
        _server.controller!
            .value.isInitialized) {
      return Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(
              _server.controller!),
          if (_isStreaming)
            Positioned(
              top:   8,
              right: 8,
              child: Container(
                padding:
                    const EdgeInsets
                        .symmetric(
                  horizontal: 8,
                  vertical:   3,
                ),
                decoration: BoxDecoration(
                  color: const Color(
                          AppConstants
                              .calmColor)
                      .withValues(
                          alpha: 0.9),
                  borderRadius:
                      BorderRadius.circular(
                          12),
                ),
                child: const Row(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    Icon(
                      Icons
                          .fiber_manual_record,
                      color: Colors.white,
                      size:  8,
                    ),
                    SizedBox(width: 4),
                    Text(
                      'LIVE → TD',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize:   10,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    }

    return Container(
      color: const Color(
          AppConstants.bgColor),
      child: const Center(
        child: Icon(
          Icons.camera_alt,
          color: Color(
              AppConstants.textSecondary),
          size: 48,
        ),
      ),
    );
  }
}