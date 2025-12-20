import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:video_player/video_player.dart';
import 'dart:io' show Platform;

final String SERVER_URL = Platform.isAndroid
    ? 'http://10.0.2.2:3000'
    : 'http://localhost:3000';

void main() => runApp(const MyApp());

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
  IO.Socket? socket;
  String currentUrl = '';
  String? videoName;
  VideoPlayerController? _videoController;
  bool isConnected = false;

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
    print("Connecting to $SERVER_URL...");
    socket = IO.io(SERVER_URL, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
      'reconnect': true, // Enable auto-reconnect
    });

    socket!.connect();

    socket!.onConnect((_) {
      print('✅ Socket Connected: ${socket?.id}');
      setState(() => isConnected = true);

      // 1. CRITICAL: Register as 'android' so the server knows to send videos here
      socket!.emit('register-device', 'android');
    });

    socket!.onDisconnect((_) {
      print('❌ Socket Disconnected');
      setState(() => isConnected = false);
    });

    socket!.onError((err) => print('Socket Error: $err'));

    socket!.on('mobile-video', (data) {
      print('📱 Video received: $data');
      _handleIncomingVideo(data);
    });
  }

  void _handleIncomingVideo(dynamic data) {
    if (data == null) return;

    String? rawUrl = data['url'];
    String? name = data['name'];

    if (rawUrl != null) {
      // 3. Handle Relative URLs (from uploads) vs Absolute URLs (from direct links)
      String finalUrl = rawUrl;

      // If it's a relative path (starts with /uploads/), prepend the server address
      if (rawUrl.startsWith('/')) {
        finalUrl = '$SERVER_URL$rawUrl';
      } else if (!rawUrl.startsWith('http')) {
        // Fallback for relative paths without slash
        finalUrl = '$SERVER_URL/$rawUrl';
      }

      print("▶ Playing URL: $finalUrl");

      setState(() {
        currentUrl = finalUrl;
        videoName = name ?? "Unknown Video";
      });

      _initializeVideoPlayer(finalUrl);
    }
  }

  void _initializeVideoPlayer(String url) {
    // Dispose previous controller
    if (_videoController != null) {
      _videoController!.dispose();
    }

    _videoController = VideoPlayerController.networkUrl(Uri.parse(url));

    _videoController!
        .initialize()
        .then((_) {
          setState(() {}); // Refresh to show video
          _videoController!.play();
          _videoController!.setLooping(true);
        })
        .catchError((error) {
          print('❌ Video initialization failed: $error');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to load video: $error')),
          );
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // appBar: AppBar(
      //   title: Text(
      //     isConnected
      //         ? 'Connected (${socket?.id?.substring(0, 4)})'
      //         : 'Disconnected',
      //   ),
      //   backgroundColor: isConnected ? Colors.green[700] : Colors.red[700],
      //   foregroundColor: Colors.white,
      // ),
      body: Center(child: _buildVideoContent()),
    );
  }

  Widget _buildVideoContent() {
    if (currentUrl.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.tv_off, size: 80, color: Colors.grey),
          const SizedBox(height: 20),
          const Text(
            'Waiting for video...',
            style: TextStyle(color: Colors.white54, fontSize: 18),
          ),
          const SizedBox(height: 10),
          Text(
            'Server: $SERVER_URL',
            style: const TextStyle(color: Colors.white24, fontSize: 12),
          ),
        ],
      );
    }

    if (_videoController != null && _videoController!.value.isInitialized) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (videoName != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              // child: Text(
              //   videoName!,
              //   style: const TextStyle(
              //     color: Colors.white,
              //     fontSize: 20,
              //     fontWeight: FontWeight.bold,
              //   ),
              // ),
            ),
          Expanded(
            child: AspectRatio(
              aspectRatio: _videoController!.value.aspectRatio,
              child: VideoPlayer(_videoController!),
            ),
          ),
          VideoProgressIndicator(_videoController!, allowScrubbing: true),
        ],
      );
    } else {
      return const CircularProgressIndicator(color: Colors.white);
    }
  }
}
