import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';

class VideoStreamWidget extends StatefulWidget {
  const VideoStreamWidget({super.key});

  @override
  State<VideoStreamWidget> createState() => _VideoStreamWidgetState();
}

class _VideoStreamWidgetState extends State<VideoStreamWidget> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;

  bool _isLoading = true;
  bool _hasError = false;
  String _errorText = '';

  final String host = '100.67.125.12';
  final String path = 'live';

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      await _renderer.initialize();

      _pc = await createPeerConnection({
        'sdpSemantics': 'unified-plan',
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'}
        ],
      });

      _pc!.onTrack = (event) {
        if (event.track.kind == 'video' && event.streams.isNotEmpty) {
          _renderer.srcObject = event.streams.first;
          if (mounted) {
            setState(() {
              _isLoading = false;
              _hasError = false;
            });
          }
        }
      };

      // recvonly transceiver is important for WHEP
      await _pc!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);

      // Wait a short moment so SDP includes ICE fields
      await Future.delayed(const Duration(milliseconds: 400));

      final local = await _pc!.getLocalDescription();
      final offerSdp = local?.sdp ?? '';
      if (offerSdp.isEmpty) {
        throw Exception('Local SDP is empty');
      }

      final url = Uri.parse('http://$host:8889/$path/whep');
      debugPrint('[WHEP] POST $url');

      final resp = await http.post(
        url,
        headers: const {
          'Content-Type': 'application/sdp',
          'Accept': 'application/sdp',
        },
        body: offerSdp,
      ).timeout(const Duration(seconds: 10));

      debugPrint('[WHEP] status=${resp.statusCode}');
      debugPrint('[WHEP] body=${resp.body}');

      if (resp.statusCode != 201) {
        throw Exception('WHEP failed: ${resp.statusCode} ${resp.body}');
      }

      final answerSdp = resp.body;
      if (!answerSdp.contains('a=ice-ufrag')) {
        throw Exception('Invalid answer SDP (missing ice-ufrag)');
      }

      await _pc!.setRemoteDescription(
        RTCSessionDescription(answerSdp, 'answer'),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
          _errorText = e.toString();
        });
      }
    }
  }

  Future<void> _retry() async {
    await _pc?.close();
    _pc = null;
    _renderer.srcObject = null;
    if (mounted) {
      setState(() {
        _isLoading = true;
        _hasError = false;
        _errorText = '';
      });
    }
    await _connect();
  }

  @override
  void dispose() {
    _pc?.close();
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(color: Colors.black),
          RTCVideoView(
            _renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          ),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(
                color: Color(AppConstants.accentColor),
              ),
            ),
          if (_hasError)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error, color: Colors.redAccent, size: 42),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'WebRTC failed:\n$_errorText',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _retry,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}