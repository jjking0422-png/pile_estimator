import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'measure_depth.dart';

void main() {
  runApp(const PileEstimatorApp());
}

class PileEstimatorApp extends StatelessWidget {
  const PileEstimatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pile Estimator',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
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
  final _width = TextEditingController();
  final _height = TextEditingController();
  final _depth = TextEditingController();

  // Tons per cubic yard (rule-of-thumb values; tweak as needed)
  final Map<String, double> _densities = const {
    'Crushed stone (avg)': 1.50,
    'Crushed concrete': 1.40,
    'Pea gravel': 1.45,
    'Sand (damp)': 1.35,
    'Recycled asphalt millings': 1.25,
  };

  String _selectedMaterial = 'Crushed stone (avg)';
  double? _cubicYards;
  double? _tons;
  File? _imageFile;
  bool _picking = false;

  void _calculate() {
    final w = double.tryParse(_width.text) ?? 0;
    final h = double.tryParse(_height.text) ?? 0;
    final d = double.tryParse(_depth.text) ?? 0;

    // Simple rectangular estimate: ft³ → yd³
    final cubicYards = (w * h * d) / 27.0;
    final density = _densities[_selectedMaterial] ?? 1.5;
    final tons = cubicYards * density;

    setState(() {
      _cubicYards = cubicYards;
      _tons = tons;
    });
  }

  Future<void> _pickFromCamera() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (xfile != null) {
        setState(() => _imageFile = File(xfile.path));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    _depth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Pile Estimator')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_imageFile != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  _imageFile!,
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              )
            else
              Container(
                height: 180,
                width: double.infinity,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: const Text('No photo yet'),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _picking ? null : _pickFromCamera,
              icon: const Icon(Icons.photo_camera),
              label: Text(_picking ? 'Opening camera…' : 'Capture pile photo'),
            ),
            if (_imageFile != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final measured = await Navigator.of(context).push<double>(
                    MaterialPageRoute(
                      builder: (_) => MeasureDepthScreen(imageFile: _imageFile!),
                    ),
                  );
                  if (measured != null) {
                    _depth.text = measured.toStringAsFixed(2);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Depth set to ${measured.toStringAsFixed(2)} ft')),
                    );
                  }
                },
                icon: const Icon(Icons.straighten),
                label: const Text('Measure depth'),
              ),
            ],
            const SizedBox(height: 24),

            Text('Enter pile dimensions (feet)', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _numField(controller: _width, label: 'Width')),
                const SizedBox(width: 12),
                Expanded(child: _numField(controller: _height, label: 'Height')),
                const SizedBox(width: 12),
                Expanded(child: _numField(controller: _depth, label: 'Depth')),
              ],
            ),

            const SizedBox(height: 16),
            Row(
              children: [
                Text('Material:', style: theme.textTheme.titleMedium),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedMaterial,
                    items: _densities.keys
                        .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                        .toList(),
                    onChanged: (v) => setState(() => _selectedMaterial = v ?? _selectedMaterial),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),
            FilledButton(
              onPressed: _calculate,
              child: const Text('Calculate'),
            ),
            const SizedBox(height: 12),
            if (_cubicYards != null || _tons != null)
              Card(
                elevation: 0,
                color: theme.colorScheme.surfaceVariant,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_cubicYards != null)
                        Text('Volume: ${_cubicYards!.toStringAsFixed(2)} yd³',
                            style: theme.textTheme.titleMedium),
                      if (_tons != null)
                        Text(
                          'Estimated weight (${_selectedMaterial}): ${_tons!.toStringAsFixed(2)} tons',
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _numField({required TextEditingController controller, required String label}) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
