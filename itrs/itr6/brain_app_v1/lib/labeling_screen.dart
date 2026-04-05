import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const String kBaseUrl = 'http://127.0.0.1:8000';

const List<String> kStateNames = [
  '0 · Baseline / Sleep',
  '1 · Panic / Procrastination',
  '2 · Meaningful Focus',
  '3 · Inattention / Wandering',
  '4 · Rigid Hyperfocus',
  '5 · Intervention Needed',
];

const List<Color> kStateColors = [
  Color(0xFF607D8B),
  Color(0xFFE53935),
  Color(0xFF43A047),
  Color(0xFFFFB300),
  Color(0xFF8E24AA),
  Color(0xFFFF5722),
];

class LabelingScreen extends StatefulWidget {
  const LabelingScreen({super.key});

  @override
  State<LabelingScreen> createState() => _LabelingScreenState();
}

class _LabelingScreenState extends State<LabelingScreen> {
  List<Map<String, dynamic>> _windows = [];
  int _cursor = 0;
  int _labeledCount = 0;
  bool _loading = true;
  bool _retraining = false;
  String _statusMsg = '';

  @override
  void initState() {
    super.initState();
    _fetchWindows();
  }

  Future<void> _fetchWindows() async {
    setState(() => _loading = true);
    try {
      final res = await http.get(Uri.parse('$kBaseUrl/windows'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['windows'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        setState(() {
          _windows = list;
          _cursor = 0;
          _loading = false;
          _statusMsg = '${list.length} uncertain windows loaded';
        });
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _statusMsg = 'Error: $e';
      });
    }
  }

  Future<void> _submitLabel(int windowId, int label) async {
    try {
      await http.post(
        Uri.parse('$kBaseUrl/label'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'window_id': windowId, 'label': label}),
      );

      setState(() {
        _labeledCount++;
        _cursor++;
        _statusMsg = '$_labeledCount labeled';
      });

      if (_labeledCount > 0 && _labeledCount % 20 == 0) {
        await _retrain();
      }
    } catch (e) {
      setState(() => _statusMsg = 'Label error: $e');
    }
  }

  Future<void> _retrain() async {
    setState(() {
      _retraining = true;
      _statusMsg = 'Retraining model with $_labeledCount labels...';
    });

    try {
      final res = await http.post(Uri.parse('$kBaseUrl/retrain'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['ok'] == true) {
          await _fetchWindows();
          setState(() {
            _statusMsg =
                'Retrained ✓  ${data['uncertain_left']} windows remaining';
          });
        } else {
          setState(() => _statusMsg = 'Retrain skipped: ${data['reason']}');
        }
      }
    } catch (e) {
      setState(() => _statusMsg = 'Retrain error: $e');
    } finally {
      setState(() => _retraining = false);
    }
  }

  String _formatTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}:'
          '${dt.second.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text(
          'Brain Labeler',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF21262D),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$_labeledCount labeled',
                style: const TextStyle(color: Colors.greenAccent),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: _fetchWindows,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.greenAccent))
          : _retraining
              ? _buildRetrainingOverlay()
              : _buildBody(),
    );
  }

  Widget _buildRetrainingOverlay() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Colors.purpleAccent),
          const SizedBox(height: 24),
          Text(
            _statusMsg,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_windows.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline,
                color: Colors.greenAccent, size: 64),
            const SizedBox(height: 16),
            const Text(
              'All windows labeled!',
              style: TextStyle(color: Colors.white, fontSize: 20),
            ),
            const SizedBox(height: 8),
            Text(
              '$_labeledCount total labels submitted',
              style: const TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purpleAccent),
              onPressed: _retrain,
              icon: const Icon(Icons.model_training),
              label: const Text('Final Retrain'),
            ),
          ],
        ),
      );
    }

    if (_cursor >= _windows.length) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.done_all, color: Colors.greenAccent, size: 64),
            const SizedBox(height: 16),
            Text(
              'Session complete — $_labeledCount labeled',
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purpleAccent),
              onPressed: _retrain,
              icon: const Icon(Icons.model_training),
              label: const Text('Retrain Now'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _fetchWindows,
              child: const Text('Fetch More Windows',
                  style: TextStyle(color: Colors.white54)),
            ),
          ],
        ),
      );
    }

    final win = _windows[_cursor];
    final probs = (win['probabilities'] as List).map((e) => (e as num).toDouble()).toList();
    final modelGuess = win['model_guess'] as int;
    final windowId = win['id'] as int;
    final startTime = _formatTime(win['start_time'] as String);
    final endTime = _formatTime(win['end_time'] as String);
    final date = _formatDate(win['start_time'] as String);

    return Column(
      children: [
        _buildStatusBar(),
        LinearProgressIndicator(
          value: _cursor / _windows.length,
          backgroundColor: const Color(0xFF21262D),
          valueColor:
              const AlwaysStoppedAnimation<Color>(Colors.greenAccent),
          minHeight: 3,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: _buildTimeCard(date, startTime, endTime, windowId),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildProbCard(probs, modelGuess),
        ),
        const SizedBox(height: 16),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'What was this actually?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 2.2,
                children: List.generate(
                  6,
                  (i) => _buildLabelButton(i, modelGuess, windowId),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () => setState(() => _cursor++),
                  child: const Text(
                    'Skip (model is correct)',
                    style: TextStyle(color: Colors.white38),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: const Color(0xFF161B22),
      child: Text(
        _statusMsg,
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
    );
  }

  Widget _buildTimeCard(String date, String start, String end, int id) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Row(
        children: [
          const Icon(Icons.calendar_today, color: Colors.white38, size: 16),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                date,
                style: const TextStyle(
                    color: Colors.white54, fontSize: 11),
              ),
              const SizedBox(height: 2),
              Text(
                '$start  →  $end',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15),
              ),
            ],
          ),
          const Spacer(),
          Text(
            '#$id',
            style: const TextStyle(color: Colors.white24, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildProbCard(List<double> probs, int modelGuess) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Model confidence',
            style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),...List.generate(6, (i) {
            final pct = probs[i];
            final isGuess = i == modelGuess;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 160,
                    child: Text(
                      kStateNames[i],
                      style: TextStyle(
                        color:
                            isGuess ? kStateColors[i] : Colors.white54,
                        fontSize: 11,
                        fontWeight: isGuess
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: pct,
                        minHeight: 8,
                        backgroundColor: const Color(0xFF21262D),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isGuess
                              ? kStateColors[i]
                              : kStateColors[i].withOpacity(0.35),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(pct * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      color:
                          isGuess ? Colors.white : Colors.white38,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildLabelButton(int label, int modelGuess, int windowId) {
    final isGuess = label == modelGuess;
    return GestureDetector(
      onTap: () => _submitLabel(windowId, label),
      child: Container(
        decoration: BoxDecoration(
          color: isGuess
              ? kStateColors[label].withOpacity(0.2)
              : const Color(0xFF21262D),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isGuess
                ? kStateColors[label]
                : const Color(0xFF30363D),
            width: isGuess ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: kStateColors[label],
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    kStateNames[label],
                    style: TextStyle(
                      color: isGuess ? Colors.white : Colors.white70,
                      fontWeight: isGuess
                          ? FontWeight.bold
                          : FontWeight.normal,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (isGuess)...[
              const SizedBox(height: 4),
              const Text(
                '← model guess',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }
}