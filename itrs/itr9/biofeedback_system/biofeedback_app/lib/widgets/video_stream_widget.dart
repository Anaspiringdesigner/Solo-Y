// lib/widgets/video_stream_widget.dart

import 'package:flutter/material.dart';
import 'package:better_player/better_player.dart';
import '../constants.dart';

class VideoStreamWidget extends StatefulWidget {
  const VideoStreamWidget({super.key});

  @override
  State<VideoStreamWidget> createState() =>
      _VideoStreamWidgetState();
}

class _VideoStreamWidgetState extends State<VideoStreamWidget> {
  BetterPlayerController? _controller;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  void _initPlayer() {
    final config = BetterPlayerConfiguration(
      aspectRatio: 1.0,
      fit:         BoxFit.contain,
      autoPlay:    true,
      looping:     true,
      controlsConfiguration:
          const BetterPlayerControlsConfiguration(
        showControls: false,
      ),
    );

    final dataSource = BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      AppConstants.streamUrl,
      liveStream: true,
      bufferingConfiguration:
          const BetterPlayerBufferingConfiguration(
        minBufferMs:                          500,
        maxBufferMs:                          1500,
        bufferForPlaybackMs:                  500,
        bufferForPlaybackAfterRebufferMs:     1000,
      ),
    );

    _controller = BetterPlayerController(config);
    _controller!.setupDataSource(dataSource);
    _controller!.addEventsListener((event) {
      if (event.betterPlayerEventType ==
          BetterPlayerEventType.exception) {
        if (mounted) setState(() => _hasError = true);
      }
    });
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

    return SizedBox(
      width:  size,
      height: size,
      child: _controller != null
          ? BetterPlayer(controller: _controller!)
          : _buildLoadingWidget(size),
    );
  }

  Widget _buildLoadingWidget(double size) {
    return Container(
      width:  size,
      height: size,
      color:  const Color(AppConstants.surfaceColor),
      child:  const Center(
        child: CircularProgressIndicator(
          color: Color(AppConstants.accentColor),
        ),
      ),
    );
  }

  Widget _buildErrorWidget(double size) {
    return Container(
      width:  size,
      height: size,
      color:  const Color(AppConstants.surfaceColor),
      child:  Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.signal_wifi_off,
            color: Color(AppConstants.stressColor),
            size:  48,
          ),
          const SizedBox(height: 12),
          Text(
            'Stream unavailable',
            style: TextStyle(
              color:    const Color(AppConstants.textSecondary),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppConstants.streamUrl,
            style: TextStyle(
              color:    const Color(AppConstants.textSecondary),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}