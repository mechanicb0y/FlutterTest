import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:video_player/video_player.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io' show Platform;

// Server WebSocket URL (explicit):
final String serverUrl =
    'ws://172.100.0.118:3000'; // Use ws://<ip>:3000/socket.io/ as requested

void main() {
  // Configure logging
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // Use debugPrint to avoid truncation in Flutter logs and avoid blocking the UI
    debugPrint(
      '${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}',
    );
    if (record.error != null) debugPrint('Error: ${record.error}');
    if (record.stackTrace != null) debugPrint('Stack: ${record.stackTrace}');
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Media Broadcast Screen',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const MediaDisplayScreen(),
    );
  }
}

class MediaDisplayScreen extends StatefulWidget {
  const MediaDisplayScreen({super.key});

  @override
  State<MediaDisplayScreen> createState() => _MediaDisplayScreenState();
}

class _MediaDisplayScreenState extends State<MediaDisplayScreen> {
  io.Socket? socket;
  String currentUrl = '';
  String currentType = 'image';
  VideoPlayerController? _videoController;
  final Logger _logger = Logger('MediaDisplayScreen');

  // Device identifier (replace with your actual device ID like 'Z4Hos7xh')
  String deviceId = 'Z4Hos7xh';

  @override
  void initState() {
    super.initState();
    _connectSocket();
  }

  @override
  void dispose() {
    socket?.disconnect();
    _videoController?.dispose();
    super.dispose();
  }

  void _connectSocket() {
    socket = io.io(serverUrl, <String, dynamic>{
      'path': '/socket.io/',
      'transports': ['websocket'],
      'autoConnect': false,
      'reconnection': true,
      'reconnectionAttempts': 999999,
      'reconnectionDelay': 1000,
      'reconnectionDelayMax': 5000,
      'timeout': 20000, // milliseconds
    });

    socket!.connect();

    // Prefer explicit event listeners for richer diagnostics
    socket!.onConnect((_) {
      _logger.info('Socket Connected to $serverUrl');
      _sendRegistrationAndStatus();
    });
    socket!.onDisconnect((_) => _logger.warning('Socket Disconnected!'));
    socket!.onError((err) => _logger.severe('Socket Error: $err'));

    // Additional event handlers (socket_io server events)
    socket!.on(
      'connect_error',
      (err) => _logger.severe('Socket Connect Error: $err'),
    );
    socket!.on(
      'reconnect',
      (attempt) => _logger.info('Socket Reconnected (attempt: $attempt)'),
    );
    socket!.on(
      'reconnect_attempt',
      (attempt) => _logger.info('Reconnect attempt: $attempt'),
    );
    socket!.on(
      'reconnect_error',
      (err) => _logger.warning('Reconnect Error: $err'),
    );
    socket!.on('reconnect_failed', (_) => _logger.severe('Reconnect failed'));

    socket!.on('media_update', (data) {
      _logger.info('Received media update: $data');
      final newUrl = data['url'];
      final newType = data['mediaType'];

      if (newUrl != null && newUrl != currentUrl) {
        setState(() {
          currentUrl = newUrl;
          currentType = newType;
        });

        if (newType == 'video') {
          _handleVideoUrl(newUrl);
        } else {
          _videoController?.dispose();
          _videoController = null;
        }
      }
    });

    // Listen for mobile-video events (server command to play URL)
    socket!.on('mobile-video', (data) {
      _logger.info('mobile-video event: $data');

      String? url;
      if (data == null) {
        _logger.warning('mobile-video event had null payload');
        return;
      }

      if (data is String) {
        url = data;
      } else if (data is Map && data['url'] != null) {
        url = data['url'];
      } else {
        _logger.warning('mobile-video payload missing url: $data');
      }

      if (url != null && url.isNotEmpty) {
        try {
          socket?.emit('mobile_video_received', {
            'deviceId': deviceId,
            'url': url,
          });
        } catch (e) {
          _logger.warning('Failed to emit mobile_video_received: $e');
        }
        _handleVideoUrl(url);
      }
    });
  }

  void _initializeVideoPlayer(String url) {
    _videoController?.dispose();
    _videoController = VideoPlayerController.networkUrl(Uri.parse(url));

    // Try initializing with a generous timeout so we can fallback if the stream is unplayable
    _videoController!
        .initialize()
        .timeout(const Duration(seconds: 20))
        .then((_) {
          setState(() {});
          _videoController!.play();
          _videoController!.setLooping(true);
          _logger.info('Video playback started (internal player): $url');

          // Notify server that playback is ready
          try {
            socket?.emit('playback_ready', {
              'deviceId': deviceId,
              'url': url,
              'method': 'internal',
            });
          } catch (e, st) {
            _logger.warning('Failed to emit playback_ready: $e', e, st);
          }
        })
        .catchError((error, stackTrace) async {
          _logger.warning(
            'Video initialization failed (internal): $error',
            error,
            stackTrace,
          );

          // Attempt to launch an external player (VLC/ExoPlayer/Browser) as a fallback
          final launched = await _launchExternalPlayer(url);
          if (launched) {
            _logger.info('Launched external player for URL: $url');
            try {
              socket?.emit('playback_ready', {
                'deviceId': deviceId,
                'url': url,
                'method': 'external',
              });
            } catch (e, st) {
              _logger.warning(
                'Failed to emit playback_ready after external launch: $e',
                e,
                st,
              );
            }
          } else {
            _logger.severe(
              'Unable to play or launch the provided video URL: $url',
            );
            setState(() {
              currentUrl = '';
              currentType = 'image'; // revert
            });

            try {
              socket?.emit('playback_failed', {
                'deviceId': deviceId,
                'url': url,
                'error': error.toString(),
              });
            } catch (e, st) {
              _logger.warning('Failed to emit playback_failed: $e', e, st);
            }
          }
        });
  }

  // Try to launch an external player for the provided URL
  Future<bool> _launchExternalPlayer(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      }
      return false;
    } catch (e, st) {
      _logger.warning('Error launching external player: $e', e, st);
      return false;
    }
  }

  /// Handles incoming 'video' media update (URL expected)
  void _handleVideoUrl(String url) {
    _logger.info('Handling video URL command: $url');

    // Stream directly via network player (no pre-download)
    currentUrl = url;
    currentType = 'video';

    setState(() {});

    _initializeVideoPlayer(url);
  }

  /// Check whether a public URL is reachable (HEAD request)
  Future<bool> _checkUrlAccessible(String url) async {
    try {
      final uri = Uri.parse(url);
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 6);
      final request = await httpClient
          .headUrl(uri)
          .timeout(const Duration(seconds: 6));
      final response = await request.close();
      final ok = response.statusCode >= 200 && response.statusCode < 400;
      httpClient.close(force: true);
      _logger.info(
        'URL check $url -> ${response.statusCode} (accessible: $ok)',
      );
      return ok;
    } catch (e, st) {
      _logger.warning('URL accessibility check failed for $url: $e', e, st);
      return false;
    }
  }

  /// Send registration + device status back to server
  Future<void> _sendRegistrationAndStatus() async {
    final reg = {
      'device': 'android',
      'isSender': false,
      'type': 'receiver',
      'deviceId': deviceId,
    };
    try {
      socket?.emit('register', reg);
      _logger.info('Sent registration: $reg');
    } catch (e, st) {
      _logger.warning('Failed to send registration event: $e', e, st);
    }

    final testUrl = 'https://www.w3schools.com/html/mov_bbb.mp4';
    final canSee = await _checkUrlAccessible(testUrl);

    final status = {
      'connected': socket != null && socket!.connected,
      'deviceType': 'android',
      'registeredAs': reg,
      'testUrlAccessible': canSee,
      'serverUrl': serverUrl,
      'deviceId': deviceId,
    };

    try {
      socket?.emit('device_status', status);
      _logger.info('Sent device_status: $status');
    } catch (e, st) {
      _logger.warning('Failed to emit device_status: $e', e, st);
    }
  }

  Widget _buildMediaContent() {
    if (currentUrl.isEmpty) {
      return const Center(
        child: Text(
          'Awaiting Media Deployment...',
          style: TextStyle(fontSize: 24, color: Colors.white),
        ),
      );
    }

    if (currentType == 'video') {
      if (_videoController != null && _videoController!.value.isInitialized) {
        return Center(
          child: AspectRatio(
            aspectRatio: _videoController!.value.aspectRatio,
            child: VideoPlayer(_videoController!),
          ),
        );
      } else {
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      }
    }
    // --- IMAGE RENDERING LOGIC ---

    return Image.network(
      currentUrl,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return const Center(
          child: Icon(Icons.error, size: 100, color: Colors.red),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Real-Time Media Screen')),
      body: Container(
        color: Colors.black, // Typical digital signage background
        width: double.infinity,
        height: double.infinity,
        child: _buildMediaContent(),
      ),
    );
  }
}
