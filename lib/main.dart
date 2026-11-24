import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'LanCast',
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xFF00BFA5),
      scaffoldBackgroundColor: const Color(0xFF0B0F14),
    ),
    home: const CamServer(),
  );
}

class CamServer extends StatefulWidget {
  const CamServer({super.key});
  @override
  State<CamServer> createState() => _CamServerState();
}

class _CamServerState extends State<CamServer> {
  static const int _port = 8080;

  CameraController? _cam;
  List<CameraDescription>? _cameras;
  int _camIndex = 0;
  HttpServer? _server;
  final List<HttpResponse> _clients = [];

  String? _url;
  String? _error;
  bool _starting = true;
  bool _busy = false;
  int _lastMs = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  // ---------- helpers ----------
  Future<String> _getIp() async {
    for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        if (!a.isLoopback) return a.address;
      }
    }
    return 'unknown';
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  // ---------- start / stop ----------
  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      WakelockPlus.enable();
      _cameras ??= await availableCameras();
      _cam = CameraController(
        _cameras![_camIndex % _cameras!.length],
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _cam!.initialize();

      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port,
          shared: true);
      _server!.listen(_handle);

      await _cam!.startImageStream(_onFrame);

      final ip = await _getIp();
      if (!mounted) return;
      setState(() {
        _url = 'http://$ip:$_port/video';
        _starting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _starting = false;
      });
    }
  }

  Future<void> _stop() async {
    for (final c in List.of(_clients)) {
      try {
        await c.close();
      } catch (_) {}
    }
    _clients.clear();
    try {
      if (_cam?.value.isStreamingImages ?? false) {
        await _cam!.stopImageStream();
      }
    } catch (_) {}
    await _cam?.dispose();
    _cam = null;
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _refresh() async {
    await _stop();
    await _start();
    _toast('Refreshed');
  }

  Future<void> _switchCamera() async {
    if ((_cameras?.length ?? 0) < 2) {
      _toast('Onno kono camera nei');
      return;
    }
    _camIndex++;
    await _stop();
    await _start();
  }

  // ---------- server ----------
  void _handle(HttpRequest req) {
    if (req.uri.path == '/video') {
      final res = req.response;
      res.headers.set(
          'Content-Type', 'multipart/x-mixed-replace; boundary=frame');
      res.headers.set('Cache-Control', 'no-cache');
      res.bufferOutput = false;
      _clients.add(res);
      if (mounted) setState(() {});
      res.done.whenComplete(() {
        _clients.remove(res);
        if (mounted) setState(() {});
      });
    } else {
      req.response
        ..headers.contentType = ContentType.html
        ..write('<body style="margin:0;background:#000">'
            '<img src="/video" style="width:100%;max-height:100vh;'
            'object-fit:contain"></body>')
        ..close();
    }
  }

  void _onFrame(CameraImage img) async {
    if (_clients.isEmpty || _busy) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastMs < 66) return; // ~15 fps
    _lastMs = now;
    _busy = true;
    try {
      final bytes = img.planes[0].bytes;
      final header = '--frame\r\nContent-Type: image/jpeg\r\n'
          'Content-Length: ${bytes.length}\r\n\r\n';
      for (final c in List.of(_clients)) {
        try {
          c.add(header.codeUnits);
          c.add(bytes);
          c.add('\r\n'.codeUnits);
        } catch (_) {
          _clients.remove(c);
        }
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _stop();
    WakelockPlus.disable();
    super.dispose();
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final live = _url != null && _error == null;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0B0F14), Color(0xFF12202B)],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cs.primary.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.videocam_rounded, color: cs.primary),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('LanCast',
                            style: TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w700)),
                        Text('Use your phone as a webcam',
                            style: TextStyle(
                                fontSize: 12, color: Colors.white54)),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: _switchCamera,
                    tooltip: 'Switch camera',
                    icon: const Icon(Icons.cameraswitch_rounded),
                  ),
                ]),
                const SizedBox(height: 20),

                // Preview
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    color: Colors.black,
                    child: AspectRatio(
                      aspectRatio: 3 / 4,
                      child: Stack(fit: StackFit.expand, children: [
                        if (_cam?.value.isInitialized ?? false)
                          FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: _cam!.value.previewSize!.height,
                              height: _cam!.value.previewSize!.width,
                              child: CameraPreview(_cam!),
                            ),
                          )
                        else
                          Center(
                            child: _starting
                                ? const CircularProgressIndicator()
                                : const Icon(Icons.videocam_off_rounded,
                                size: 48, color: Colors.white38),
                          ),
                        Positioned(
                          top: 12,
                          left: 12,
                          child: _Badge(
                            color: live ? Colors.redAccent : Colors.grey,
                            label: live ? 'LIVE' : 'OFFLINE',
                          ),
                        ),
                        Positioned(
                          top: 12,
                          right: 12,
                          child: _Badge(
                            color: Colors.black54,
                            icon: Icons.remove_red_eye_rounded,
                            label: '${_clients.length}',
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // URL card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('STREAM URL',
                          style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 1.2,
                              color: Colors.white54)),
                      const SizedBox(height: 8),
                      if (_error != null)
                        Text(_error!,
                            style:
                            const TextStyle(color: Colors.redAccent))
                      else
                        SelectableText(
                          _url ?? 'Starting...',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: cs.primary),
                        ),
                      const SizedBox(height: 16),
                      Row(children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _url == null
                                ? null
                                : () async {
                              await Clipboard.setData(
                                  ClipboardData(text: _url!));
                              _toast('URL copied');
                            },
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: const Text('Copy'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: _url == null
                                ? null
                                : () => Share.share(
                                'Phone camera stream: $_url'),
                            icon: const Icon(Icons.share_rounded, size: 18),
                            label: const Text('Share'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _starting ? null : _refresh,
                            icon: const Icon(Icons.refresh_rounded,
                                size: 18),
                            label: const Text('Refresh'),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Phone ar PC same Wi-Fi te rakho. PC browser e URL er '
                      'shesh theke /video bad diye khulle page view pabe.',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final Color color;
  final String label;
  final IconData? icon;
  const _Badge({required this.color, required this.label, this.icon});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon ?? Icons.circle, size: icon == null ? 8 : 14),
      const SizedBox(width: 6),
      Text(label,
          style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700)),
    ]),
  );
}