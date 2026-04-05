import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// ============================================================
// 0) Entry point
// ============================================================
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BrainApp());
}

// ============================================================
// 1) App root
// ============================================================
class BrainApp extends StatelessWidget {
  const BrainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Brain Labeler',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const LabelingScreen(),
    );
  }
}

// ============================================================
// 2) Constants
// ============================================================
const Map<int, String> stateNames = {
  0: 'Baseline / Sleep',
  1: 'Panic / Procrastination',
  2: 'Meaningful Focus',
  3: 'Inattention / Wandering',
  4: 'Rigid Hyperfocus',
  5: 'Intervention Needed',
};

const Map<int, Color> stateColors = {
  0: Color(0xFF607D8B),
  1: Color(0xFFE53935),
  2: Color(0xFF43A047),
  3: Color(0xFFFFB300),
  4: Color(0xFF8E24AA),
  5: Color(0xFFFF5722),
};

const Map<int, IconData> stateIcons = {
  0: Icons.bedtime,
  1: Icons.warning_amber_rounded,
  2: Icons.bolt,
  3: Icons.cloud,
  4: Icons.lock,
  5: Icons.sos,
};

// ============================================================
// 3) Data models
// ============================================================
class WindowItem {
  final int id;
  final DateTime startTime;
  final DateTime endTime;
  final List<double> probabilities;
  int? userLabel;

  WindowItem({
    required this.id,
    required this.startTime,
    required this.endTime,
    required this.probabilities,
    this.userLabel,
  });

  double get maxProb => probabilities.reduce((a, b) => a > b ? a : b);
  int get modelGuess => probabilities.indexOf(maxProb);

  bool get isUncertain => maxProb >= 0.35 && maxProb <= 0.65;
}

// ============================================================
// 4) Robust scaler (mirrors brain.py)
// ============================================================
class RobustScaler {
  final List<double> median;
  final List<double> iqr;

  const RobustScaler({required this.median, required this.iqr});

  factory RobustScaler.fromJson(Map<String, dynamic> json) => RobustScaler(
        median: List<double>.from(json['median']),
        iqr: List<double>.from(json['iqr']),
      );

  List<double> transform(List<List<double>> window) {
    final out = <double>[];
    for (final row in window) {
      for (int ch = 0; ch < 3; ch++) {
        out.add((row[ch] - median[ch]) / iqr[ch]);
      }
    }
    return out;
  }
}

// ============================================================
// 5) TFLite inference service
// ============================================================
class InferenceService {
  static const int nClasses     = 6;
  static const int windowSeconds = 120;
  static const int inputDim     = 3;

  Interpreter? _interpreter;
  RobustScaler? _scaler;

  bool get isReady => _interpreter != null && _scaler != null;

  Future<void> init() async {
    // Load scaler
    final scalerJson = await rootBundle.loadString('assets/scaler.json');
    _scaler = RobustScaler.fromJson(jsonDecode(scalerJson));

    // Load TFLite model
    _interpreter = await Interpreter.fromAsset('assets/brain_model.tflite');

    print('InferenceService ready.');
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }

  // Run one window [windowSeconds][inputDim] through the model
  List<double> runWindow(List<List<double>> rawWindow) {
    assert(isReady, 'Call init() first');

    // Scale
    final flat = _scaler!.transform(rawWindow);

    // Reshape to [1, 120, 3]
    final input = List.generate(
      1,
      (_) => List.generate(
        windowSeconds,
        (t) => List.generate(
          inputDim,
          (c) => flat[t * inputDim + c],
        ),
      ),
    );

    // Output buffer [1, 6]
    final output = List.generate(
      1,
      (_) => List<double>.filled(nClasses, 0.0),
    );

    _interpreter!.run(input, output);

    // Already softmax from Keras — return as-is
    return output[0];
  }

  // Run inference on a list of raw windows
  List<WindowItem> inferWindows(List<_RawWindow> rawWindows) {
    final results = <WindowItem>[];
    for (int i = 0; i < rawWindows.length; i++) {
      final rw    = rawWindows[i];
      final probs = runWindow(rw.data);
      results.add(WindowItem(
        id:            i,
        startTime:     rw.startTime,
        endTime:       rw.endTime,
        probabilities: probs,
      ));
    }
    return results;
  }
}

// ============================================================
// 6) Raw window holder
// ============================================================
class _RawWindow {
  final DateTime startTime;
  final DateTime endTime;
  final List<List<double>> data; // [120][3]

  const _RawWindow({
    required this.startTime,
    required this.endTime,
    required this.data,
  });
}

// ============================================================
// 7) Mock data generator (replace with real CSV later)
// ============================================================
List<_RawWindow> generateMockRawWindows() {
  final rng  = math.Random(42);
  final base = DateTime(2025, 4, 5, 9, 0, 0);
  final windows = <_RawWindow>[];

  for (int i = 0; i < 20; i++) {
    final start = base.add(Duration(minutes: i * 30));
    final end   = start.add(const Duration(minutes: 2));

    // Simulate 120 seconds of [hr, hrv, br]
    final data = List.generate(
      120,
      (_) => [
        60.0 + rng.nextDouble() * 40,  // hr: 60–100
        30.0 + rng.nextDouble() * 50,  // hrv: 30–80
        12.0 + rng.nextDouble() * 8,   // br: 12–20
      ],
    );

    windows.add(_RawWindow(startTime: start, endTime: end, data: data));
  }
  return windows;
}

// ============================================================
// 8) Labeling screen
// ============================================================
class LabelingScreen extends StatefulWidget {
  const LabelingScreen({super.key});

  @override
  State<LabelingScreen> createState() => _LabelingScreenState();
}

class _LabelingScreenState extends State<LabelingScreen> {
  final _inference = InferenceService();

  List<WindowItem> _uncertainWindows = [];
  int  _currentIndex = 0;
  int  _labeled      = 0;
  bool _loading      = true;
  bool _done         = false;
  String? _error;

  // In-memory label store: windowId → label
  final Map<int, int> _labels = {};

  @override
  void initState() {
    super.initState();
    _initAndInfer();
  }

  @override
  void dispose() {
    _inference.dispose();
    super.dispose();
  }

  Future<void> _initAndInfer() async {
    try {
      await _inference.init();

      // Generate mock windows — replace with real data later
      final rawWindows = generateMockRawWindows();

      // Run inference
      final allWindows = _inference.inferWindows(rawWindows);

      // Filter uncertain only (35%–65%)
      final uncertain = allWindows.where((w) => w.isUncertain).toList();

      setState(() {
        _uncertainWindows = uncertain;
        _loading          = false;
      });
    } catch (e) {
      setState(() {
        _error   = e.toString();
        _loading = false;
      });
    }
  }

  WindowItem get _current => _uncertainWindows[_currentIndex];

  void _submitLabel(int label) {
    setState(() {
      _current.userLabel    = label;
      _labels[_current.id]  = label;
      _labeled++;
      _advance();
    });
  }

  void _skip() {
    setState(() {
      _advance();
    });
  }

  void _advance() {
    if (_currentIndex < _uncertainWindows.length - 1) {
      _currentIndex++;
    } else {
      _done = true;
    }
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String _dateString(DateTime dt) {
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec',
    ];
    return '${months[dt.month - 1]} ${dt.day}';
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) return _buildLoading();
    if (_error != null) return _buildError();
    if (_uncertainWindows.isEmpty) return _buildEmpty();
    if (_done) return _buildDone();
    return _buildLabeler();
  }

  // ── Loading ────────────────────────────────────────────────────────────

  Widget _buildLoading() {
    return const Scaffold(
      backgroundColor: Color(0xFF0F0F0F),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading model...', style: TextStyle(color: Colors.white54)),
          ],
        ),
      ),
    );
  }

  // ── Error ──────────────────────────────────────────────────────────────

  Widget _buildError() {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Error: $_error',
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  // ── Empty ──────────────────────────────────────────────────────────────

  Widget _buildEmpty() {
    return const Scaffold(
      backgroundColor: Color(0xFF0F0F0F),
      body: Center(
        child: Text(
          'No uncertain windows found.\nModel is confident on all data.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 16),
        ),
      ),
    );
  }

  // ── Done ───────────────────────────────────────────────────────────────

  Widget _buildDone() {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.check_circle_outline,
                color: Color(0xFF43A047),
                size: 72,
              ),
              const SizedBox(height: 24),
              const Text(
                'Labeling Complete',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                'You labeled $_labeled of ${_uncertainWindows.length} uncertain windows.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 15),
              ),
              const SizedBox(height: 16),
              Text(
                'Labels stored in memory: ${_labels.length}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Main labeler ───────────────────────────────────────────────────────

  Widget _buildLabeler() {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        elevation: 0,
        title: const Text(
          'Label Your Data',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${_currentIndex + 1} / ${_uncertainWindows.length}',
                style: const TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Progress bar
          LinearProgressIndicator(
            value: (_currentIndex + 1) / _uncertainWindows.length,
            backgroundColor: Colors.white12,
            color: const Color(0xFF43A047),
            minHeight: 3,
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildTimeCard(),
                  const SizedBox(height: 20),
                  _buildModelGuessCard(),
                  const SizedBox(height: 20),
                  _buildProbabilityBars(),
                  const SizedBox(height: 28),
                  const Text(
                    'What were you doing\nduring this time?',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildLabelGrid(),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _skip,
                    child: const Text(
                      "I don't remember — skip",
                      style: TextStyle(color: Colors.white30, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Time card ──────────────────────────────────────────────────────────

  Widget _buildTimeCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _TimeBlock(
            label: 'FROM',
            time: _formatTime(_current.startTime),
            date: _dateString(_current.startTime),
          ),
          Column(
            children: [
              const Icon(Icons.arrow_forward, color: Colors.white38, size: 20),
              const SizedBox(height: 4),
              Text(
                '${_current.endTime.difference(_current.startTime).inMinutes} min',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
          _TimeBlock(
            label: 'TO',
            time: _formatTime(_current.endTime),
            date: _dateString(_current.endTime),
          ),
        ],
      ),
    );
  }

  // ── Model guess card ───────────────────────────────────────────────────

  Widget _buildModelGuessCard() {
    final guess      = _current.modelGuess;
    final guessColor = stateColors[guess]!;
    final pct        = (_current.maxProb * 100).toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: guessColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: guessColor.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(stateIcons[guess], color: guessColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Model's best guess",
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 2),
                Text(
                  stateNames[guess]!,
                  style: TextStyle(
                    color: guessColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: guessColor.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$pct%',
              style: TextStyle(
                color: guessColor,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Probability bars ───────────────────────────────────────────────────

  Widget _buildProbabilityBars() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Probability breakdown',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
        const SizedBox(height: 8),...List.generate(6, (i) {
          final p     = _current.probabilities[i];
          final color = stateColors[i]!;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 130,
                  child: Text(
                    stateNames[i]!,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: p,
                      minHeight: 8,
                      color: color,
                      backgroundColor: Colors.white10,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${(p * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  // ── Label grid ─────────────────────────────────────────────────────────

  Widget _buildLabelGrid() {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 2.4,
      children: List.generate(6, (i) {
        return _LabelButton(
          name:  stateNames[i]!,
          color: stateColors[i]!,
          icon:  stateIcons[i]!,
          onTap: () => _submitLabel(i),
        );
      }),
    );
  }
}

// ============================================================
// 9) Reusable widgets
// ============================================================
class _TimeBlock extends StatelessWidget {
  final String label;
  final String time;
  final String date;

  const _TimeBlock({
    required this.label,
    required this.time,
    required this.date,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          time,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          date,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }
}

class _LabelButton extends StatelessWidget {
  final String   name;
  final Color    color;
  final IconData icon;
  final VoidCallback onTap;

  const _LabelButton({
    required this.name,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(0.35)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}