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

class _VideoStreamWidgetState extends State<VideoStreamWidget> {
  late final Player _player;
  late final VideoController _controller;

  bool _hasError = false;
  bool _isBuffering = true;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      _player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 2 * 1024 * 1024,
          logLevel:   MPVLogLevel.info,
        ),
      );

      _controller = VideoController(_player);

      _player.stream.buffering.listen((b) {
        if (mounted) {
          setState(() => _isBuffering = b);
        }
      });

      _player.stream.error.listen((e) {
        debugPrint('[VIDEO] Error: $e');
        if (mounted) {
          setState(() => _hasError = true);
        }
      });

      _player.stream.playing.listen((p) {
        debugPrint('[VIDEO] Playing: $p');
      });

      _player.stream.completed.listen(
          (completed) {
        if (completed && mounted) {
          _restartStream();
        }
      });

      await _openStream();

    } catch (e) {
      debugPrint('[VIDEO] Init error: $e');
      if (mounted) {
        setState(() => _hasError = true);
      }
    }
  }

  Future<void> _openStream() async {
    try {
      debugPrint('[VIDEO] Opening: '
          '${AppConstants.streamUrl}');

      await _player.open(
        Media(AppConstants.streamUrl),
        play: true,
      );

      await _player.setPlaylistMode(
          PlaylistMode.none);

    } catch (e) {
      debugPrint('[VIDEO] Open error: $e');
      if (mounted) {
        setState(() => _hasError = true);
      }
    }
  }

  Future<void> _restartStream() async {
    if (!mounted) return;
    setState(() {
      _hasError = false;
      _isBuffering = true;
    });
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted) await _openStream();
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
      width: size,
      height: size,
      child: Stack(
        children: [
          Video(
            controller: _controller,
            aspectRatio: 1.0, // keep your current square UI
            fill: const Color(AppConstants.surfaceColor),
            controls: NoVideoControls,
          ),
          if (_isBuffering)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.35),
                child: const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(
                        color: Color(AppConstants.accentColor),
                        strokeWidth: 2,
                      ),
                      SizedBox(height: 12),
                      Text(
                        'Connecting SRT...',
                        style: TextStyle(
                          color: Color(AppConstants.textSecondary),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorWidget(double size) {
    return Container(
      width: size,
      height: size,
      color: const Color(AppConstants.surfaceColor),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.signal_wifi_off,
            color: Color(AppConstants.stressColor),
            size: 48,
          ),
          const SizedBox(height: 12),
          const Text(
            'SRT stream unavailable',
            style: TextStyle(
              color: Color(AppConstants.textSecondary),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppConstants.streamUrl,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(AppConstants.textSecondary),
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _hasError = false;
                _isBuffering = true;
              });
              _restartStream();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  const Color(AppConstants.accentColor).withValues(alpha: 0.15),
              foregroundColor: const Color(AppConstants.accentColor),
              side: const BorderSide(
                color: Color(AppConstants.accentColor),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('↺ Retry'),
          ),
        ],
      ),
    );
  }
}