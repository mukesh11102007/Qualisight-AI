import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:image/image.dart' as img;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  CameraDescription? selectedCamera;
  for (var camera in cameras) {
    if (camera.lensDirection == CameraLensDirection.back) {
      selectedCamera = camera;
      break;
    }
  }
  selectedCamera ??= cameras.first;

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyanAccent,
          brightness: Brightness.dark,
        ),
      ),
      home: CameraScreen(camera: selectedCamera),
    ),
  );
}

class CameraScreen extends StatefulWidget {
  final CameraDescription camera;

  const CameraScreen({super.key, required this.camera});

  @override
  CameraScreenState createState() => CameraScreenState();
}

class CameraScreenState extends State<CameraScreen> with SingleTickerProviderStateMixin {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  late AnimationController _scanController;
  
  bool _isStreaming = false;
  bool _isProcessing = false;
  String _status = "STANDBY";
  Timer? _streamTimer;
  Timer? _analysisTimer;
  
  String selectedZone = "Zone 1";
  String serverIp = "iciness-praising-public.ngrok-free.dev"; 
  final String geminiApiKey = "AIzaSyDNmyebWIkM3c74aXZNgNuywhZYtFbjym4";

  String get baseUrl {
    String trimmed = serverIp.trim();
    
    // Remove "http://" or "https://" if present for parsing
    String host = trimmed.replaceAll("https://", "").replaceAll("http://", "");
    
    // Remove any trailing paths (like /test.html)
    if (host.contains("/")) {
      host = host.split("/")[0];
    }
    
    // Standardize to https for ngrok, or http:3000 for local
    if (host.contains("ngrok")) {
      return "https://$host";
    }
    
    return "http://$host:3000";
  }
  
  // Updated to v1beta which is more stable for flash models
  String get geminiUrl => "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$geminiApiKey";

  final List<Map<String, dynamic>> _logs = [];

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    _initializeControllerFuture = _controller.initialize();
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scanController.dispose();
    _streamTimer?.cancel();
    _analysisTimer?.cancel();
    super.dispose();
  }

  void _addLog(String msg, {Color color = Colors.white70}) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, {
        "time": DateFormat('HH:mm:ss').format(DateTime.now()),
        "msg": msg,
        "color": color
      });
      if (_logs.length > 15) _logs.removeLast();
    });
  }

  Future<void> _toggleStreaming() async {
    setState(() {
      _isStreaming = !_isStreaming;
    });

    if (_isStreaming) {
      _addLog("SYSTEM: SCANNING_MODE_ACTIVE", color: Colors.cyanAccent);
      _status = "ACTIVE // $selectedZone";
      
      _streamTimer = Timer.periodic(const Duration(milliseconds: 1000), (timer) async {
        if (!_isStreaming) return;
        await _uploadFrame();
      });

      _analysisTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
        if (!_isStreaming) return;
        await _analyzeFrame();
      });
      
      _analyzeFrame();
    } else {
      _streamTimer?.cancel();
      _analysisTimer?.cancel();
      _addLog("SYSTEM: STANDBY", color: Colors.white38);
      setState(() {
        _status = "STANDBY";
      });
    }
  }

  Future<void> _uploadFrame() async {
    if (_isProcessing || !_controller.value.isInitialized) return;
    try {
      final XFile image = await _controller.takePicture();
      final bytes = await image.readAsBytes();
      
      img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return;
      List<int> compressed = img.encodeJpg(decoded, quality: 40);
      String dataUrl = "data:image/jpeg;base64,${base64Encode(compressed)}";

      await http.post(
        Uri.parse("$baseUrl/v1/camera"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"zone": selectedZone, "image": dataUrl}),
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint("Stream error: $e");
    }
  }

  Future<void> _analyzeFrame() async {
    if (!_controller.value.isInitialized) return;
    _addLog("NEURAL: ANALYZING...", color: Colors.cyanAccent.withOpacity(0.5));

    try {
      final XFile image = await _controller.takePicture();
      final bytes = await image.readAsBytes();
      img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return;
      List<int> compressed = img.encodeJpg(decoded, quality: 50);
      String base64Content = base64Encode(compressed);

      const prompt = """Perform Industrial Quality Check:
1. Is the primary object a standard ink pen? 
   - Note: MECHANICAL PENCILS are NOT pens. If it is a mechanical pencil, respond 'NO_PEN_DETECTED'.
   - If NO pen is detected, respond ONLY 'NO_PEN_DETECTED'.
2. If it IS a valid pen, check for:
   - Ink Leak (smudges/liquid on barrel): respond 'INK_LEAK'
   - Missing Cap (exposed nib): respond 'CAP_MISSING'
   - Damaged Tip: respond 'TIP_DAMAGED'
   - Perfect condition: respond 'PEN_OK'
Respond ONLY with one of the labels.""";

      final response = await http.post(
        Uri.parse(geminiUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "contents": [
            {
              "parts": [
                {"text": prompt},
                {"inline_data": {"mime_type": "image/jpeg", "data": base64Content}}
              ]
            }
          ]
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final result = data['candidates'][0]['content']['parts'][0]['text'].toString().trim().toUpperCase();
        
        if (result == "PEN_OK") {
          _addLog("QUALITY: PASSED (OK)", color: Colors.greenAccent);
        } else if (result == "UNKNOWN") {
          _addLog("STATUS: NO_OBJECT", color: Colors.white30);
        } else {
          _addLog("DEFECT: $result", color: Colors.redAccent);
          http.post(
            Uri.parse("$baseUrl/api/defects"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({
              "image": "data:image/jpeg;base64,$base64Content", 
              "message": result, 
              "zone": selectedZone
            }),
          );
        }
      } else {
        _addLog("NEURAL: ERR_${response.statusCode}", color: Colors.orangeAccent);
      }
    } catch (e) {
      _addLog("ERROR: NEURAL_TIMEOUT", color: Colors.redAccent);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: FutureBuilder<void>(
              future: _initializeControllerFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done) {
                  return CameraPreview(_controller);
                } else {
                  return const Center(child: CircularProgressIndicator(color: Colors.cyanAccent));
                }
              },
            ),
          ),
          _buildHUD(),
          Positioned.fill(
            child: Column(
              children: [
                _buildHeader(),
                const Spacer(),
                if (_isStreaming) _buildScanningFrame(),
                const Spacer(),
                _buildZoneSelector(), // ADDED ZONE SELECTOR
                _buildLogs(),
                _buildControls(),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHUD() {
    return IgnorePointer(
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [Colors.transparent, Colors.black.withOpacity(0.5)],
                stops: const [0.6, 1.0],
              ),
            ),
          ),
          CustomPaint(
            size: Size.infinite,
            painter: HUDPainter(isActive: _isStreaming),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 60, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  border: Border.all(color: Colors.white10),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_isStreaming)
                          Container(
                            width: 8, height: 8,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                          ),
                        Text(
                          "LIVE // $_status",
                          style: const TextStyle(
                            color: Colors.cyanAccent, 
                            fontSize: 10, 
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      DateFormat('yyyy.MM.dd HH:mm:ss').format(DateTime.now()),
                      style: const TextStyle(color: Colors.white38, fontSize: 10, fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: _showSettings,
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            style: IconButton.styleFrom(backgroundColor: Colors.black26),
          ),
        ],
      ),
    );
  }

  Widget _buildScanningFrame() {
    return Center(
      child: AnimatedBuilder(
        animation: _scanController,
        builder: (context, child) {
          return Container(
            width: 280,
            height: 350,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white10),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Stack(
              children: [
                Positioned(
                  top: _scanController.value * 350,
                  left: 20,
                  right: 20,
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      color: Colors.cyanAccent,
                      boxShadow: [
                        BoxShadow(color: Colors.cyanAccent.withOpacity(0.5), blurRadius: 15, spreadRadius: 2),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildZoneSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.white10),
            ),
            child: DropdownButton<String>(
              value: selectedZone,
              dropdownColor: Colors.grey[900],
              underline: const SizedBox(),
              isExpanded: true,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              items: ["Zone 1", "Zone 2"].map((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value.toUpperCase()),
                );
              }).toList(),
              onChanged: (val) {
                setState(() {
                  selectedZone = val!;
                  if (_isStreaming) _status = "ACTIVE // $selectedZone";
                });
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogs() {
    return Container(
      height: 120,
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      child: ListView.builder(
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          final log = _logs[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                children: [
                  TextSpan(text: "[${log['time']}] ", style: const TextStyle(color: Colors.white24)),
                  TextSpan(text: log['msg'], style: TextStyle(color: log['color'])),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton(
              onPressed: _toggleStreaming,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isStreaming ? Colors.redAccent : Colors.cyanAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 20),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                elevation: 0,
              ),
              child: Text(
                _isStreaming ? "STOP INSPECTION" : "START INSPECTION",
                style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1),
              ),
            ),
          ),
          const SizedBox(width: 15),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: IconButton(
              onPressed: () {}, 
              icon: const Icon(Icons.flash_on_rounded, color: Colors.white70),
              padding: const EdgeInsets.all(18),
            ),
          ),
        ],
      ),
    );
  }

  void _showSettings() {
    final controller = TextEditingController(text: serverIp);
    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text("Station Config", style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: "Remote Server IP",
              labelStyle: TextStyle(color: Colors.white38),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white10)),
            ),
            style: const TextStyle(color: Colors.white),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL", style: TextStyle(color: Colors.white38))),
            ElevatedButton(
              onPressed: () {
                setState(() => serverIp = controller.text.trim());
                _addLog("SYSTEM: REMOTE_HOST_UPDATED");
                Navigator.pop(context);
              },
              child: const Text("APPLY"),
            ),
          ],
        ),
      ),
    );
  }
}

class HUDPainter extends CustomPainter {
  final bool isActive;
  HUDPainter({required this.isActive});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isActive ? Colors.cyanAccent.withOpacity(0.5) : Colors.white10
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    const cornerSize = 40.0;
    const padding = 30.0;

    // Top Left
    canvas.drawPath(Path()..moveTo(padding, padding + cornerSize)..lineTo(padding, padding)..lineTo(padding + cornerSize, padding), paint);
    // Top Right
    canvas.drawPath(Path()..moveTo(size.width - padding - cornerSize, padding)..lineTo(size.width - padding, padding)..lineTo(size.width - padding, padding + cornerSize), paint);
    // Bottom Left
    canvas.drawPath(Path()..moveTo(padding, size.height - padding - cornerSize)..lineTo(padding, size.height - padding)..lineTo(padding + cornerSize, size.height - padding), paint);
    // Bottom Right
    canvas.drawPath(Path()..moveTo(size.width - padding - cornerSize, size.height - padding)..lineTo(size.width - padding, size.height - padding)..lineTo(size.width - padding, size.height - padding - cornerSize), paint);
  }

  @override
  bool shouldRepaint(HUDPainter oldDelegate) => oldDelegate.isActive != isActive;
}
