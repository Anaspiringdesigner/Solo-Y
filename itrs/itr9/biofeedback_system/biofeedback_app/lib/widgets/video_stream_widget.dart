import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../constants.dart';

class VideoStreamWidget extends StatefulWidget {
  const VideoStreamWidget({super.key});

  @override
  State<VideoStreamWidget> createState() =>
      _VideoStreamWidgetState();
}

class _VideoStreamWidgetState
    extends State<VideoStreamWidget> {

  late final Player          _player;
  late final VideoController _controller;
  bool _hasError    = false;
  bool _isBuffering = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      _player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 32 * 1024 * 1024,
          logLevel:   MPVLogLevel.warn,
        ),
      );

      _controller = VideoController(_player);

      // Listen to stream events
      _player.stream.error.listen((error) {
        debugPrint('[VIDEO] Error: $error');
        if (mounted) {
          setState(() => _hasError = true);
        }
      });

      _player.stream.playing.listen((playing) {
        debugPrint('[VIDEO] Playing: $playing');
      });

      _player.stream.buffering.listen((buffering) {
        debugPrint('[VIDEO] Buffering: $buffering');
        if (mounted) {
          setState(() => _isBuffering = buffering);
        }
      });

      _player.stream.completed.listen((completed) {
        debugPrint('[VIDEO] Completed: $completed');
        if (completed && mounted) {
          // Restart stream if it ends
          _restartStream();
        }
      });

      await _player.open(
        Media(
          AppConstants.streamUrl,
          httpHeaders: {
            'User-Agent': 'BiofeedbackApp/1.0',
          },
        ),
        play: true,
      );

    } catch (e) {
      debugPrint('[VIDEO] Init error: $e');
      if (mounted) {
        setState(() => _hasError = true);
      }
    }
  }

  Future<void> _restartStream() async {
    debugPrint('[VIDEO] Restarting stream...');
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      setState(() {
        _hasError    = false;
        _isBuffering = false;
      });
      await _player.open(
        Media(
          AppConstants.streamUrl,
          httpHeaders: {
            'User-Agent': 'BiofeedbackApp/1.0',
          },
        ),
        play: true,
      );
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width;

    if (_hasError) {
      return _buildErrorWidget(size);
    }

    return SizedBox(
      width:  size,
      height: size,
      child: Stack(
        children: [
          // ── Video Player ──────────────────────────
          Video(
            controller:  _controller,
            aspectRatio: 1.0,
            fill:        const Color(
                AppConstants.surfaceColor),
            controls:    NoVideoControls,
          ),

          // ── Buffering Indicator ───────────────────
          if (_isBuffering)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(
                    alpha: 0.3),
                child: const Center(
                  child: CircularProgressIndicator(
                    color: Color(
                        AppConstants.accentColor),
                    strokeWidth: 2,
                  ),
                ),
              ),
            ),

          // ── Retry Button on Error ─────────────────
          if (_hasError)
            Positioned.fill(
              child: _buildErrorWidget(size),
            ),
        ],
      ),
    );
  }

  Widget _buildLoadingWidget(double size) {
    return Container(
      width:  size,
      height: size,
      color:  const Color(AppConstants.surfaceColor),
      child:  const Center(
        child: Column(
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: Color(
                  AppConstants.accentColor),
            ),
            SizedBox(height: 12),
            Text(
              'Connecting to stream...',
              style: TextStyle(
                color: Color(
                    AppConstants.textSecondary),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorWidget(double size) {
    return Container(
      width:  size,
      height: size,
      color:  const Color(AppConstants.surfaceColor),
      child: Column(
        mainAxisAlignment:
            MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.signal_wifi_off,
            color: Color(AppConstants.stressColor),
            size:  48,
          ),
          const SizedBox(height: 12),
          const Text(
            'Stream unavailable',
            style: TextStyle(
              color: Color(
                  AppConstants.textSecondary),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Check OBS + nginx are running',
            style: TextStyle(
              color: Color(
                  AppConstants.textSecondary),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 16),
          // ── Retry Button ────────────────────────
          ElevatedButton(
            onPressed: () {
              setState(() {
                _hasError    = false;
                _isBuffering = false;
              });
              _restartStream();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(
                      AppConstants.accentColor)
                  .withValues(alpha: 0.15),
              foregroundColor: const Color(
                  AppConstants.accentColor),
              side: const BorderSide(
                color: Color(
                    AppConstants.accentColor),
              ),
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(12),
              ),
            ),
            child: const Text('↺  Retry'),
          ),
        ],
      ),
    );
  }
} 