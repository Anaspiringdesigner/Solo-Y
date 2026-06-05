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

  late final Player         _player;
  late final VideoController _controller;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      _player     = Player();
      _controller = VideoController(_player);

      await _player.open(
        Media(AppConstants.streamUrl),
        play: true,
      );

      _player.stream.error.listen((error) {
        debugPrint('MediaKit error: $error');
        if (mounted) {
          setState(() => _hasError = true);
        }
      });
    } catch (e) {
      debugPrint('Player init error: $e');
      if (mounted) {
        setState(() => _hasError = true);
      }
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
      child:  Video(
        controller:  _controller,
        aspectRatio: 1.0,
        fill:        const Color(
            AppConstants.surfaceColor),
        controls:    NoVideoControls,
      ),
    );
  }

  Widget _buildErrorWidget(double size) {
    return Container(
      width:  size,
      height: size,
      color:  const Color(AppConstants.surfaceColor),
      child:  const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.signal_wifi_off,
            color: Color(AppConstants.stressColor),
            size:  48,
          ),
          SizedBox(height: 12),
          Text(
            'Stream unavailable',
            style: TextStyle(
              color:    Color(
                  AppConstants.textSecondary),
              fontSize: 14,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Check OBS + nginx are running',
            style: TextStyle(
              color:    Color(
                  AppConstants.textSecondary),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}