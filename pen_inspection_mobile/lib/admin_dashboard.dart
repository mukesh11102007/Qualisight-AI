import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'dart:async';
import 'utils.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({Key? key}) : super(key: key);
  @override
  _AdminDashboardState createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  late WebSocketChannel _channel;
  late Stream _broadcastStream;
  late FlutterTts _tts;
  List<Map<String, dynamic>> _defects = [];
  bool _autoPilot = false;
  String _serverIp = "iciness-praising-public.ngrok-free.dev";
  String _maintenanceStatus = "SYSTEM_HEALTHY";
  int _performanceIndex = 100;
  String _aiInsight = "Calibrating Neural Engine...";
  Timer? _analyticsTimer;

  String get _baseUrl {
    String host = _serverIp.trim().replaceAll("https://", "").replaceAll("http://", "");
    if (host.contains("/")) host = host.split("/")[0];
    return host.contains("ngrok") ? "https://$host" : "http://$host:3000";
  }

  @override
  void initState() {
    super.initState();
    _initTTS();
    _loadSettings().then((_) {
      _connectWebSocket();
      _loadDefects();
      _startAnalyticsLoop();
    });
  }

  void _startAnalyticsLoop() {
    _analyticsTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      try {
        final resp = await http.get(Uri.parse('$_baseUrl/api/analytics'));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          setState(() {
            _maintenanceStatus = data['maintenanceStatus'];
            _performanceIndex = data['performanceIndex'];
          });
        }

        final insightResp = await http.get(Uri.parse('$_baseUrl/api/analytics/insights'));
        if (insightResp.statusCode == 200) {
          final data = jsonDecode(insightResp.body);
          setState(() {
            _aiInsight = data['insight'];
          });
        }
      } catch (e) {}
    });
  }

  void _initTTS() {
    _tts = FlutterTts();
    _tts.setLanguage("en-US");
    _tts.setSpeechRate(0.5);
    _tts.setPitch(1.0);
    _tts.setVolume(1.0);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoPilot = prefs.getBool('autoPilot') ?? false;
      _serverIp = prefs.getString('serverIp') ?? "iciness-praising-public.ngrok-free.dev";
    });
  }

  Future<void> _saveAutoPilot(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoPilot', value);
    setState(() => _autoPilot = value);
  }

  void _connectWebSocket() {
    final wsUrl = _baseUrl.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');
    _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
    _broadcastStream = _channel.stream.asBroadcastStream();
    _broadcastStream.listen(_handleMessage, onDone: () => Future.delayed(const Duration(seconds: 2), _connectWebSocket));
  }

  void _handleMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String);
      if (data['type'] == 'defect') {
        final defect = data['data'];
        setState(() => _defects.insert(0, defect));
        _handleNewDefect(defect);
      }
    } catch (e) {}
  }

  void _handleNewDefect(Map<String, dynamic> defect) {
    _speak("Incident in ${defect['zone']}. Issue: ${defect['message']}.");
    if (_autoPilot) {
      _dispatchAlert(defect);
    }
  }

  Future<void> _speak(String text) async {
    await _tts.speak(text);
  }

  Future<void> _dispatchAlert(Map<String, dynamic> defect) async {
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl/api/alerts/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'message': defect['message'],
          'image': defect['image'],
          'timestamp': defect['timestamp'],
          'zone': defect['zone'],
        }),
      );
      if (res.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('🤖 AUTO-PILOT: Dispatched alert for ${defect['zone']}'),
              backgroundColor: const Color(0xFF0F172A),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {}
  }

  Future<void> _loadDefects() async {
    try {
      final resp = await http.get(Uri.parse('$_baseUrl/api/defects'));
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        setState(() => _defects = List<Map<String, dynamic>>.from(json['data']));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect to backend: $_baseUrl/api/defects'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  void dispose() {
    _channel.sink.close();
    _tts.stop();
    _analyticsTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: Row(
        children: [
          // Sidebar
          Container(
            width: 280,
            color: Colors.white,
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Text('Q', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 18)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text('QualiSight', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                        Text('ENTERPRISE AI', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.grey, letterSpacing: 1.5)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 40),
                const Text('AUTONOMOUS MODE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Auto-Pilot', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                      Switch(
                        value: _autoPilot,
                        activeColor: const Color(0xFF0F172A),
                        onChanged: (v) => _saveAutoPilot(v),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
                const Text('SYSTEMS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
                const SizedBox(height: 12),
                const _SidebarItem(icon: Icons.dashboard, label: 'Dashboard', isActive: true),
                const _SidebarItem(icon: Icons.camera_alt, label: 'Remote Units', isActive: false),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.logout, color: Colors.grey, size: 18),
                  label: const Text('Exit Admin', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          // Main Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('GLOBAL MONITORING', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.grey, letterSpacing: 3)),
                          Text('Control Center', style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                        ],
                      ),
                      Row(
                        children: [
                          if (_maintenanceStatus == "MAINTENANCE_REQUIRED")
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              margin: const EdgeInsets.only(right: 16),
                              decoration: BoxDecoration(
                                  color: Colors.amber.shade50,
                                  border: Border.all(color: Colors.amber.shade200),
                                  borderRadius: BorderRadius.circular(12)),
                              child: Row(
                                children: [
                                  Icon(Icons.build, size: 14, color: Colors.amber.shade800),
                                  const SizedBox(width: 8),
                                  Text("MAINTENANCE REQ.",
                                      style: TextStyle(
                                          fontSize: 10, fontWeight: FontWeight.black, color: Colors.amber.shade800)),
                                ],
                              ),
                            ),
                          _StatCard(label: 'PERFORMANCE', value: '$_performanceIndex%'),
                          const SizedBox(width: 16),
                          _StatCard(label: 'TOTAL DEFECTS', value: _defects.length.toString()),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 40),
                  Container(
                    height: 200,
                    width: double.infinity,
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Stack(
                      children: [
                        const Center(child: Text('Performance Index Chart', style: TextStyle(color: Colors.grey))),
                        const Align(
                          alignment: Alignment.topRight,
                          child: Text('FACTORY PERFORMANCE INDEX', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.grey, letterSpacing: 1.2)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // AI Neural Insight Banner
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFF0F172A), Color(0xFF1E293B)]),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [BoxShadow(color: Colors.indigo.withOpacity(0.2), blurRadius: 20)],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(color: Colors.indigo.withOpacity(0.2), borderRadius: BorderRadius.circular(12)),
                          child: const Icon(Icons.bolt, color: Colors.indigoAccent, size: 28),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('NEURAL INSIGHT ENGINE', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Colors.indigoAccent, letterSpacing: 2)),
                              const SizedBox(height: 4),
                              Text(_aiInsight, style: const TextStyle(fontSize: 13, color: Colors.white, fontStyle: FontStyle.italic, fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                  Row(
                    children: [
                      Expanded(child: _StreamBox(label: 'Zone 1', stream: _broadcastStream)),
                      const SizedBox(width: 40),
                      Expanded(child: _StreamBox(label: 'Zone 2', stream: _broadcastStream)),
                    ],
                  ),
                  const SizedBox(height: 40),
                  const Text('Recent Incidents', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                  const SizedBox(height: 20),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 32,
                      mainAxisSpacing: 32,
                      childAspectRatio: 0.9,
                    ),
                    itemCount: _defects.length,
                    itemBuilder: (context, index) {
                      final d = _defects[index];
                      return _IncidentCard(
                        defect: d,
                        onDispatch: () => _dispatchAlert(d),
                        onDelete: () async {
                          await http.delete(Uri.parse('$_baseUrl/api/defects/${d['_id']}'));
                          setState(() => _defects.removeAt(index));
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  const _SidebarItem({required this.icon, required this.label, required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFFF8FAFC) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: isActive ? Border.all(color: Colors.grey.shade200) : null,
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: isActive ? const Color(0xFF0F172A) : Colors.grey),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(fontWeight: isActive ? FontWeight.bold : FontWeight.w500, color: isActive ? const Color(0xFF0F172A) : Colors.grey)),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final bool isStatus;
  const _StatCard({required this.label, required this.value, this.isStatus = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
          const SizedBox(height: 4),
          if (isStatus)
            Row(
              children: [
                Container(width: 6, height: 6, decoration: const BoxDecoration(color: const Color(0xFF10B981), shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: const Color(0xFF10B981))),
              ],
            )
          else
            Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
        ],
      ),
    );
  }
}

class _StreamBox extends StatefulWidget {
  final String label;
  final Stream stream;
  const _StreamBox({required this.label, required this.stream});

  @override
  State<_StreamBox> createState() => _StreamBoxState();
}

class _StreamBoxState extends State<_StreamBox> {
  String? _lastFrame;
  late StreamSubscription _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.stream.listen((raw) {
      try {
        final data = jsonDecode(raw as String);
        if (data['type'] == 'stream' && data['zone'] == widget.label) {
          if (mounted) {
            setState(() {
              _lastFrame = data['image'];
            });
          }
        }
      } catch (e) {}
    });
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(widget.label, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(10)),
              child: const Text('ONLINE', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Color(0xFF10B981))),
            ),
          ],
        ),
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(30),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 20, offset: const Offset(0, 10))],
            ),
            clipBehavior: Clip.antiAlias,
            child: _lastFrame != null
                ? Image.memory(
                    base64Decode(_lastFrame!.split(',')[1]),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  )
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        const SizedBox(height: 12),
                        Text('INITIALIZING...',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey.shade500, letterSpacing: 1.2)),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _IncidentCard extends StatelessWidget {
  final Map<String, dynamic> defect;
  final VoidCallback onDispatch;
  final VoidCallback onDelete;
  const _IncidentCard({required this.defect, required this.onDispatch, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.memory(
                    base64Decode((defect['image'] as String).split(',')[1]),
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned(
                  bottom: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.9), borderRadius: BorderRadius.circular(8)),
                    child: Text(defect['zone'], style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: Text(defect['message'], style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A)), maxLines: 1, overflow: TextOverflow.ellipsis)),
              Text(formatTimestamp(defect['timestamp']), style: const TextStyle(fontSize: 9, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: onDispatch,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F172A),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('DISPATCH ALERT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, color: Colors.grey),
                style: IconButton.styleFrom(backgroundColor: const Color(0xFFF8FAFC), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
