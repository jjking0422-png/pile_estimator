import 'dart:io';
import 'package:flutter/material.dart';

/// Two-step measuring:
/// 1) Calibrate: tap TWO points on a known-length object in the photo (e.g., 4 ft),
///    enter that length, then press "Set calibration".
/// 2) Measure: tap TWO points spanning the pile depth, press "Compute depth", then "Use depth".

class MeasureDepthScreen extends StatefulWidget {
  final File imageFile;

  const MeasureDepthScreen({super.key, required this.imageFile});

  @override
  State<MeasureDepthScreen> createState() => _MeasureDepthScreenState();
}

enum MeasureMode { calibrate, measure }

class _MeasureDepthScreenState extends State<MeasureDepthScreen> {
  final TextEditingController _knownLengthFt = TextEditingController(text: '4.0');

  MeasureMode _mode = MeasureMode.calibrate;

  // Tapped points (image-space in widget logical pixels)
  Offset? _calibA;
  Offset? _calibB;
  Offset? _measA;
  Offset? _measB;

  // Pixels-per-foot after calibration
  double? _pixelsPerFoot;

  // Latest computed measurement (in feet)
  double? _measuredFeet;

  bool get _calibrationReady => _calibA != null && _calibB != null;
  bool get _measurementReady => _measA != null && _measB != null;

  void _onTapDown(TapDownDetails d) {
    final p = d.localPosition;
    setState(() {
      if (_mode == MeasureMode.calibrate) {
        if (_calibA == null) {
          _calibA = p;
        } else if (_calibB == null) {
          _calibB = p;
        } else {
          // start over after two points
          _calibA = p;
          _calibB = null;
        }
      } else {
        if (_measA == null) {
          _measA = p;
        } else if (_measB == null) {
          _measB = p;
        } else {
          _measA = p;
          _measB = null;
        }
      }
    });
  }

  double _dist(Offset a, Offset b) => (a - b).distance;

  void _setCalibration() {
    if (!_calibrationReady) {
      _show('Tap two calibration points first.');
      return;
    }
    final knownFt = double.tryParse(_knownLengthFt.text);
    if (knownFt == null || knownFt <= 0) {
      _show('Enter a valid known length (ft).');
      return;
    }
    final pixels = _dist(_calibA!, _calibB!);
    if (pixels <= 0) {
      _show('Calibration points are too close.');
      return;
    }
    setState(() {
      _pixelsPerFoot = pixels / knownFt; // px per ft
      // switch to measuring after calibration
      _mode = MeasureMode.measure;
      // clear any prior measurement points
      _measA = _measB = null;
      _measuredFeet = null;
    });
    _show('Calibration set: ${_pixelsPerFoot!.toStringAsFixed(2)} px/ft. Now tap two points to measure.');
  }

  void _computeMeasurement() {
    if (_pixelsPerFoot == null) {
      _show('Set calibration first.');
      return;
    }
    if (!_measurementReady) {
      _show('Tap two measurement points.');
      return;
    }
    final pixels = _dist(_measA!, _measB!);
    final feet = pixels / _pixelsPerFoot!;
    setState(() => _measuredFeet = feet);
    _show('Depth = ${feet.toStringAsFixed(2)} ft');
  }

  void _finish() {
    if (_measuredFeet == null || _measuredFeet! <= 0) {
      _show('No depth measured yet.');
      return;
    }
    Navigator.of(context).pop<double>(_measuredFeet);
  }

  void _resetAll() {
    setState(() {
      _calibA = _calibB = _measA = _measB = null;
      _pixelsPerFoot = null;
      _measuredFeet = null;
      _mode = MeasureMode.calibrate;
      _knownLengthFt.text = '4.0';
    });
    _show('Reset. Tap two points to calibrate.');
  }

  void _show(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Measure Depth'),
        actions: [
          IconButton(
            tooltip: 'Reset',
            onPressed: _resetAll,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          // Image + overlay (contain so full image is visible)
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Image.file(
                    widget.imageFile,
                    fit: BoxFit.contain, // <— show the whole photo, no cropping
                  ),
                ),
                // Tap/paint layer
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: _onTapDown,
                    child: CustomPaint(
                      painter: _OverlayPainter(
                        calibA: _calibA,
                        calibB: _calibB,
                        measA: _measA,
                        measB: _measB,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Controls
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    SegmentedButton<MeasureMode>(
                      segments: const [
                        ButtonSegment(value: MeasureMode.calibrate, label: Text('Calibrate')),
                        ButtonSegment(value: MeasureMode.measure, label: Text('Measure')),
                      ],
                      selected: <MeasureMode>{_mode},
                      onSelectionChanged: (s) => setState(() => _mode = s.first),
                    ),
                    const SizedBox(width: 12),
                    if (_mode == MeasureMode.calibrate)
                      Expanded(
                        child: TextField(
                          controller: _knownLengthFt,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Known length (ft)',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ),
                    const SizedBox(width: 8),
                    if (_mode == MeasureMode.calibrate)
                      FilledButton(
                        onPressed: _calibrationReady ? _setCalibration : null,
                        child: const Text('Set calibration'),
                      ),
                  ],
                ),

                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _infoTile(
                        title: 'Calibration points',
                        value: _calibrationReady ? '2/2 ✓' : (_calibA == null ? '0/2' : '1/2'),
                        icon: Icons.tune,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _infoTile(
                        title: 'Pixels per ft',
                        value: _pixelsPerFoot == null ? '--' : _pixelsPerFoot!.toStringAsFixed(1),
                        icon: Icons.straighten,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _infoTile(
                        title: 'Measure points',
                        value: _measurementReady ? '2/2 ✓' : (_measA == null ? '0/2' : '1/2'),
                        icon: Icons.straighten_outlined,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _infoTile(
                        title: 'Depth (ft)',
                        value: _measuredFeet == null ? '--' : _measuredFeet!.toStringAsFixed(2),
                        icon: Icons.calculate,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _measurementReady ? _computeMeasurement : null,
                      icon: const Icon(Icons.calculate),
                      label: const Text('Compute depth'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: (_measuredFeet != null && _measuredFeet! > 0) ? _finish : null,
                      icon: const Icon(Icons.check),
                      label: const Text('Use depth'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoTile({required String title, required String value, required IconData icon}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelMedium),
                Text(value, style: theme.textTheme.titleMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final Offset? calibA;
  final Offset? calibB;
  final Offset? measA;
  final Offset? measB;

  _OverlayPainter({
    required this.calibA,
    required this.calibB,
    required this.measA,
    required this.measB,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paintCal = Paint()
      ..color = const Color(0xFF1565C0) // blue
      ..strokeWidth = 3;

    final paintMeas = Paint()
      ..color = const Color(0xFF2E7D32) // green
      ..strokeWidth = 3;

    final dotCal = Paint()..color = const Color(0xFF1565C0);
    final dotMeas = Paint()..color = const Color(0xFF2E7D32);

    // Calibration line (blue)
    if (calibA != null) canvas.drawCircle(calibA!, 5, dotCal);
    if (calibB != null) canvas.drawCircle(calibB!, 5, dotCal);
    if (calibA != null && calibB != null) canvas.drawLine(calibA!, calibB!, paintCal);

    // Measurement line (green)
    if (measA != null) canvas.drawCircle(measA!, 5, dotMeas);
    if (measB != null) canvas.drawCircle(measB!, 5, dotMeas);
    if (measA != null && measB != null) canvas.drawLine(measA!, measB!, paintMeas);
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) {
    return old.calibA != calibA ||
        old.calibB != calibB ||
        old.measA != measA ||
        old.measB != measB;
  }
}
