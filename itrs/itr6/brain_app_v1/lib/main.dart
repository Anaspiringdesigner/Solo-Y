// main.dart
import 'package:flutter/material.dart';

void main() {
  runApp(const BrainApp());
}

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
// DATA MODELS
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

/// One uncertain window that needs a label
class WindowItem {
  final int id;
  final DateTime startTime;
  final DateTime endTime;
  final List<double> probabilities; // length 6, softmax output
  int? userLabel;

  WindowItem({
    required this.id,
    required this.startTime,
    required this.endTime,
    required this.probabilities,
    this.userLabel,
  });

  double get maxProb =>
      probabilities.reduce((a, b) => a > b ? a : b);

  int get modelGuess =>
      probabilities.indexOf(maxProb);
}

// ============================================================
// MOCK DATA  (replace with real model output later)
// ============================================================

List<WindowItem> generateMockWindows() {
  final base = DateTime(2025, 4, 5, 9, 0, 0);
  final mockProbs = [
    [0.18, 0.42, 0.15, 0.10, 0.08, 0.07], // uncertain ✓
    [0.05, 0.03, 0.85, 0.04, 0.02, 0.01], // confident ✗
    [0.20, 0.20, 0.20, 0.20, 0.10, 0.10], // very uncertain ✓
    [0.10, 0.55, 0.12, 0.10, 0.08, 0.05], // borderline ✓
    [0.02, 0.01, 0.01, 0.94, 0.01, 0.01], // confident ✗
    [0.22, 0.18, 0.30, 0.15, 0.10, 0.05], // uncertain ✓
    [0.15, 0.38, 0.20, 0.12, 0.10, 0.05], // uncertain ✓
    [0.01, 0.02, 0.01, 0.01, 0.94, 0.01], // confident ✗
    [0.17, 0.17, 0.17, 0.17, 0.16, 0.16], // max uncertain ✓
    [0.60, 0.10, 0.10, 0.10, 0.05, 0.05], // borderline ✗
  ];

  return List.generate(mockProbs.length, (i) {
    final start = base.add(Duration(minutes: i * 30));
    final end   = start.add(const Duration(minutes: 2));
    return WindowItem(
      id:           i,
      startTime:    start,
      endTime:      end,
      probabilities: List<double>.from(mockProbs[i]),
    );
  });
}

// ============================================================
// LABELING SCREEN
// ============================================================

class LabelingScreen extends StatefulWidget {
  const LabelingScreen({super.key});

  @override
  State<LabelingScreen> createState() => _LabelingScreenState();
}

class _LabelingScreenState extends State<LabelingScreen> {
  late List<WindowItem> _allWindows;
  late List<WindowItem> _uncertainWindows;

  int _currentIndex = 0;
  int _labeled      = 0;
  bool _done        = false;

  // Uncertainty band
  static const double _lowThreshold  = 0.35;
  static const double _highThreshold = 0.65;

  @override
  void initState() {
    super.initState();
    _allWindows = generateMockWindows();
    _uncertainWindows = _allWindows.where((w) =>
            w.maxProb >= _lowThreshold && w.maxProb <= _highThreshold).toList();
  }

  WindowItem get _current => _uncertainWindows[_currentIndex];

  String _formatTime(DateTime dt) {
    final h   = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$h:$min';
  }

  String _formatDuration(DateTime start, DateTime end) {
    final diff = end.difference(start);
    return '${diff.inMinutes} min';
  }

  void _submitLabel(int label) {
    setState(() {
      _current.userLabel = label;
      _labeled++;

      if (_currentIndex < _uncertainWindows.length - 1) {
        _currentIndex++;
      } else {
        _done = true;
      }
    });
  }

  void _skip() {
    setState(() {
      if (_currentIndex < _uncertainWindows.length - 1) {
        _currentIndex++;
      } else {
        _done = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_uncertainWindows.isEmpty) {
      return const _EmptyState(
        message: 'No uncertain windows found.\nModel is confident on all data.',
      );
    }

    if (_done) {
      return _DoneScreen(
        total:   _uncertainWindows.length,
        labeled: _labeled,
        windows: _uncertainWindows,
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildProgressBar(),
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
                  _buildProbabilityBar(),
                  const SizedBox(height: 28),
                  _buildQuestion(),
                  const SizedBox(height: 16),
                  _buildLabelGrid(),
                  const SizedBox(height: 16),
                  _buildSkipButton(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── App bar ─────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
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
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Progress bar ─────────────────────────────────────────────────────────

  Widget _buildProgressBar() {
    final progress = (_currentIndex + 1) / _uncertainWindows.length;
    return LinearProgressIndicator(
      value:            progress,
      backgroundColor:  Colors.white12,
      color:            const Color(0xFF43A047),
      minHeight:        3,
    );
  }

  // ── Time card ────────────────────────────────────────────────────────────

  Widget _buildTimeCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:        const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _TimeBlock(
            label: 'FROM',
            time:  _formatTime(_current.startTime),
            date:  _dateString(_current.startTime),
          ),
          Column(
            children: [
              const Icon(Icons.arrow_forward,
                  color: Colors.white38, size: 20),
              const SizedBox(height: 4),
              Text(
                _formatDuration(_current.startTime, _current.endTime),
                style: const TextStyle(
                    color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
          _TimeBlock(
            label: 'TO',
            time:  _formatTime(_current.endTime),
            date:  _dateString(_current.endTime),
          ),
        ],
      ),
    );
  }

  String _dateString(DateTime dt) {
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}';
  }

  // ── Model guess card ─────────────────────────────────────────────────────

  Widget _buildModelGuessCard() {
    final guess      = _current.modelGuess;
    final guessColor = stateColors[guess]!;
    final guessName  = stateNames[guess]!;
    final pct        = (_current.maxProb * 100).toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color:        guessColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: guessColor.withOpacity(0.4)),
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
                  style: TextStyle(
                      color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 2),
                Text(
                  guessName,
                  style: TextStyle(
                    color:      guessColor,
                    fontWeight: FontWeight.w600,
                    fontSize:   15,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color:        guessColor.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$pct%',
              style: TextStyle(
                color:      guessColor,
                fontWeight: FontWeight.bold,
                fontSize:   14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Probability bar ───────────────────────────────────────────────────────

  Widget _buildProbabilityBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Probability breakdown',
          style: TextStyle(
              color: Colors.white38, fontSize: 12),
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
                      value:           p,
                      minHeight:       8,
                      color:           color,
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

  // ── Question ──────────────────────────────────────────────────────────────

  Widget _buildQuestion() {
    return const Text(
      'What were you doing\nduring this time?',
      style: TextStyle(
        fontSize:   22,
        fontWeight: FontWeight.bold,
        color:      Colors.white,
        height:     1.3,
      ),
    );
  }

  // ── Label grid ────────────────────────────────────────────────────────────

  Widget _buildLabelGrid() {
    return GridView.count(
      crossAxisCount:   2,
      shrinkWrap:       true,
      physics:          const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing:  12,
      childAspectRatio: 2.4,
      children: List.generate(6, (i) {
        return _LabelButton(
          label:    i,
          name:     stateNames[i]!,
          color:    stateColors[i]!,
          icon:     stateIcons[i]!,
          onTap:    () => _submitLabel(i),
        );
      }),
    );
  }

  // ── Skip button ───────────────────────────────────────────────────────────

  Widget _buildSkipButton() {
    return TextButton(
      onPressed: _skip,
      child: const Text(
        "I don't remember — skip",
        style: TextStyle(color: Colors.white30, fontSize: 13),
      ),
    );
  }
}

// ============================================================
// REUSABLE WIDGETS
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
        Text(label,
            style: const TextStyle(
                color: Colors.white38, fontSize: 11,
                letterSpacing: 1.5)),
        const SizedBox(height: 4),
        Text(time,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                fontFeatures: [FontFeature.tabularFigures()])),
        const SizedBox(height: 2),
        Text(date,
            style: const TextStyle(
                color: Colors.white38, fontSize: 12)),
      ],
    );
  }
}

class _LabelButton extends StatelessWidget {
  final int      label;
  final String   name;
  final Color    color;
  final IconData icon;
  final VoidCallback onTap;

  const _LabelButton({
    required this.label,
    required this.name,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color:        color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap:        onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(0.35)),
          ),
          padding: const EdgeInsets.symmetric(
              horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    color:      color,
                    fontSize:   12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines:  2,
                  overflow:  TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// DONE SCREEN
// ============================================================

class _DoneScreen extends StatelessWidget {
  final int              total;
  final int              labeled;
  final List<WindowItem> windows;

  const _DoneScreen({
    required this.total,
    required this.labeled,
    required this.windows,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.check_circle_outline,
                  color: Color(0xFF43A047), size: 72),
              const SizedBox(height: 24),
              const Text(
                'Labeling Complete',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                'You labeled $labeled of $total uncertain windows.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white54, fontSize: 15),
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF43A047),
                  padding: const EdgeInsets.all(16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon:    const Icon(Icons.download),
                label:   const Text('Export Labels as CSV',
                    style: TextStyle(fontSize: 16)),
                onPressed: () => _exportCsv(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _exportCsv(BuildContext context) {
    // TODO: wire up file_picker / share_plus to write to disk
    final labeled = windows.where((w) => w.userLabel != null);
    final rows    = labeled.map((w) =>
        '${w.startTime.toIso8601String()},'
        '${w.endTime.toIso8601String()},'
        '${w.userLabel},'
        '${stateNames[w.userLabel!]}');

    final csv = 'start_time,end_time,label,label_name\n${rows.join('\n')}';
    debugPrint(csv); // replace with actual file write

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Labels exported (check console for now)')),
    );
  }
}

// ============================================================
// EMPTY STATE
// ============================================================

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 16),
        ),
      ),
    );
  }
}