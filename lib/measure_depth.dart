import 'dart:io';
import 'package:flutter/material.dart';

class MeasureDepthScreen extends StatefulWidget {
  final File imageFile;

  const MeasureDepthScreen({super.key, required this.imageFile});

  @override
  State<MeasureDepthScreen> createState() => _MeasureDepthScreenState();
}

class _MeasureDepthScreenState extends State<MeasureDepthScreen> {
  double _measuredFeet = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Measure Depth')),
      body: Column(
        children: [
          // show the photo
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Image.file(widget.imageFile, fit: BoxFit.cover, width: double.infinity),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Stub for now: use the buttons below to return a test value.\n'
              'Next step we’ll add tap-to-set points + ruler overlay.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final v in [2.0, 4.0, 6.0, 8.0])
                FilledButton(
                  onPressed: () => setState(() => _measuredFeet = v),
                  child: Text('${v.toStringAsFixed(0)} ft'),
                ),
            ],
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _measuredFeet > 0
                  ? () => Navigator.of(context).pop<double>(_measuredFeet)
                  : null,
              icon: const Icon(Icons.check),
              label: Text(
                _measuredFeet > 0 ? 'Use $_measuredFeet ft' : 'Pick a value',
              ),
            ),
          )
        ],
      ),
    );
  }
}
