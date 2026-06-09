import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../constants.dart';
import '../services/mjpeg_server.dart';

class CameraStreamWidget
    extends StatefulWidget {
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
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _isLoading = true;
      _statusMsg = 'Starting camera...';
    });

    await _server.initCamera();
    await _server.startServer();

    // Auto-start streaming
    final ok = await _server.startStreaming();

    if (mounted) {
      setState(() {
        _isLoading  = false;
        _isStreaming = ok;
        _statusMsg  = ok
            ? 'Live → TD'
            : 'Failed to start';
      });
    }
  }

  Future<void> _switchCamera() async {
    setState(() => _isLoading = true);
    await _server.switchCamera();
    if (mounted) {
      setState(() {
        _isLoading = false;
        _statusMsg = 'Camera switched';
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

          // ── Status ───────────────────────
          Padding(
            padding: const EdgeInsets
                .symmetric(
                    horizontal: 16,
                    vertical:   8),
            child: Row(
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
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                if (_isStreaming)
                  Text(
                    _server.streamUrl,
                    style: const TextStyle(
                      color: Color(
                          AppConstants
                              .textSecondary),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}