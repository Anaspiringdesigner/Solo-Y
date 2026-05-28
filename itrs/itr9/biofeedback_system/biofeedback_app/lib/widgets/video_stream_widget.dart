import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../constants.dart';

class VideoStreamWidget extends StatefulWidget {
  const VideoStreamWidget({super.key});

  @override
  State<VideoStreamWidget> createState() =>
      _VideoStreamWidgetState();
}

class _VideoStreamWidgetState
    extends State<VideoStreamWidget> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _hasError      = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(AppConstants.streamUrl),
        httpHeaders: {
          'Accept': '*/*',
        },
      );

      await _controller!.initialize();
      await _controller!.setLooping(true);
      await _controller!.play();

      if (mounted) {
        setState(() => _isInitialized = true);
      }
    } catch (e) {
      debugPrint('Video error: $e');
      if (mounted) {
        setState(() => _hasError = true);
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width;

    if (_hasError) {
      return _buildErrorWidget(size);
    }

    if (!_isInitialized) {
      return _buildLoadingWidget(size);
    }

    return SizedBox(
      width:  size,
      height: size,
      child:  AspectRatio(
        aspectRatio: 1.0,
        child:       VideoPlayer(_controller!),
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
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: Color(AppConstants.accentColor),
            ),
            SizedBox(height: 12),
            Text(
              'Connecting to stream...',
              style: TextStyle(
                color:    Color(AppConstants.textSecondary),
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
              color:    Color(AppConstants.textSecondary),
              fontSize: 14,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Check OBS + nginx are running',
            style: TextStyle(
              color:    Color(AppConstants.textSecondary),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}