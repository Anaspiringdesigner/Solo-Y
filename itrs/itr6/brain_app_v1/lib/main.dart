import 'package:flutter/material.dart';
import 'labeling_screen.dart';

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
      theme: ThemeData.dark(),
      home: const LabelingScreen(),
    );
  }
}