import 'package:flutter/material.dart';

void main() {
  runApp(const PileEstimatorApp());
}

class PileEstimatorApp extends StatelessWidget {
  const PileEstimatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pile Estimator',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const PileEstimatorScreen(),
    );
  }
}

class PileEstimatorScreen extends StatefulWidget {
  const PileEstimatorScreen({super.key});

  @override
  State<PileEstimatorScreen> createState() => _PileEstimatorScreenState();
}

class _PileEstimatorScreenState extends State<PileEstimatorScreen> {
  final _widthController = TextEditingController();
  final _heightController = TextEditingController();
  final _depthController = TextEditingController();
  double? _tons;

  void _calculateTons() {
    final width = double.tryParse(_widthController.text) ?? 0;
    final height = double.tryParse(_heightController.text) ?? 0;
    final depth = double.tryParse(_depthController.text) ?? 0;

    // Volume in cubic yards (27 cubic feet per yard)
    final cubicYards = (width * height * depth) / 27;

    // Assume average density of crushed stone = 1.5 tons per cubic yard
    final tons = cubicYards * 1.5;

    setState(() => _tons = tons);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pile Estimator')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter Pile Dimensions (in feet):',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 10),
            TextField(
              controller: _widthController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Width'),
            ),
            TextField(
              controller: _heightController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Height'),
            ),
            TextField(
              controller: _depthController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Depth'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _calculateTons,
              child: const Text('Calculate'),
            ),
            const SizedBox(height: 20),
            if (_tons != null)
              Text(
                'Estimated Weight: ${_tons!.toStringAsFixed(2)} tons',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
          ],
        ),
      ),
    );
  }
}
