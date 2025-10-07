import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Two-point calibration workflow:
/// 1) Tap two points on something with a known real-world length (e.g., a 4 ft board).
///    Enter that known length (in feet) and press "Set calibration".
/// 2) Switch to "Measure" and tap two points marking the pile's depth on the photo.
///    The app converts pixels → feet using the calibration and returns the depth.

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

  // Tapped points (image-space in logical pixels)
  Offset? _calibA;
  Offset? _calibB;
  Offset? _measA;
  Offset? _measB;

  // Pixels-per-foot scale after calibration
  double? _pixelsPerFoot;

  // Latest computed measurement (in feet)
  double? _measuredFeet;

  // Image display size tracking
  final GlobalKey _imageKey = GlobalKey();
  Size? _imagePaintSize;

  @override
  void dispose() {
    _knownLengthFt.dispose();
    super.dispose();
  }

  void _onImageLayout() {
    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null) {
      setState(() => _imagePaintSize = box.size);
    }
  }

  void _onTapDown(TapDownDetails d) {
    if (_imagePaintSize == null) return;

    final local = (d.localPosition);
    setState(() {
      if (_mode == MeasureMode.calibrate) {
        if (_calibA == null) {
          _calibA = local;
        } else if (_calibB == null) {
          _calibB = local;
        } else {
          // Reset if both points already set
          _calibA = local;
          _calibB = null;
        }
      } else {
        if (_measA == null) {
          _measA = local;
        } else if (_measB == null) {
          _measB = local;
        } else {
          _measA = local;
          _measB = null;
        }
      }
    });
  }

  double _dist(Offset a, Offset b) => (a - b).distance;

  void _setCalibration() {
    if (_calibA == null || _calibB == null) {
      _showSnack('Tap two calibration points first.');
      return;
    }
    final knownFt = double.tryParse(_knownLengthFt.text);
    if (knownFt == null || knownFt <= 0) {
      _showSnack('Enter a valid known length (ft).');
      return;
    }
    final pixels = _dist(_calibA!, _calibB!);
    if (pixels <= 0) {
      _showSnack('Calibration points are too close.');
      return;
    }
    setState(() {
      _pixelsPerFoot = pixels / knownFt; // px per ft
    });
    _showSnack('Calibration set: ${(_pixelsPerFoot!).toStringAsFixed(2)} px/ft');
  }

  void _computeMeasurement() {
    if (_pixelsPerFoot == null) {
      _showSnack('Set calibration first.');
      return;
    }
    if (_measA == null || _measB == null) {
      _showSnack('Tap two measurement points.');
      return;
    }
    final pixels = _dist(_measA!, _measB!);
    final feet = pixels / _pixelsPerFoot!;
    setState(() => _measuredFeet = feet);
  }

  void _finish() {
    if (_measuredFeet == null || _measuredFeet! <= 0) {
      _showSnack('No depth measured yet.');
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
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Re-measure image widget after layout
    WidgetsBinding.instance.addPostFrameCallback((_) => _onImageLayout());

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
          // Image + overlay
          AspectRatio(
            aspectRatio: 4 / 3,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: [
                    // The photo
                    SizedBox(
                      key: _imageKey,
                      width: double.infinity,
                      height: double.infinity,
                      child: Image.file(
                        Image.file(
                         widget.imageFile,
                         fit: BoxFit.contain, // shows the full photo inside the frame
),

                      ),
                    ),
                    // Tap layer
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
                );
              },
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
                      onSelectionChanged: (s) {
                        setState(() => _mode = s.first);
                      },
                    ),
                    const SizedBox(width: 12),
                    if (_mode == MeasureMode.calibrate)
                      Expanded(
                        child: TextField(
                          controller: _knownLengthFt,
                          keyboardType:
                              const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Known length (ft)',
                            border: OutlineInputBorder(),
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ),
                    const SizedBox(width: 8),
                    if (_mode == MeasureMode.calibrate)
                      FilledButton(
                        onPressed: _setCalibration,
                        child: const Text('Set calibration'),
                      ),
                  ],
                ),

                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _infoTile(
                        title: 'Calibration',
                        value: _pixelsPerFoot == null
                            ? 'Not set'
                            : '${_pixelsPerFoot!.toStringAsFixed(1)} px/ft',
                        icon: Icons.tune,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _infoTile(
                        title: 'Depth',
                        value: _measuredFeet == null
                            ? '-- ft'
                            : '${_measuredFeet!.toStringAsFixed(2)} ft',
                        icon: Icons.straighten,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _computeMeasurement,
                      icon: const Icon(Icons.calculate),
                      label: const Text('Compute depth'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _finish,
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
      ..color = const Color(0xFF1565C0)
      ..strokeWidth = 3;

    final paintMeas = Paint()
      ..color = const Color(0xFF2E7D32)
      ..strokeWidth = 3;

    final dotCal = Paint()..color = const Color(0xFF1565C0);
    final dotMeas = Paint()..color = const Color(0xFF2E7D32);

    // Calibration line
    if (calibA != null) {
      canvas.drawCircle(calibA!, 5, dotCal);
    }
    if (calibB != null) {
      canvas.drawCircle(calibB!, 5, dotCal);
    }
    if (calibA != null && calibB != null) {
      canvas.drawLine(calibA!, calibB!, paintCal);
    }

    // Measurement line
    if (measA != null) {
      canvas.drawCircle(measA!, 5, dotMeas);
    }
    if (measB != null) {
      canvas.drawCircle(measB!, 5, dotMeas);
    }
    if (measA != null && measB != null) {
      canvas.drawLine(measA!, measB!, paintMeas);
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) {
    return oldDelegate.calibA != calibA ||
        oldDelegate.calibB != calibB ||
        oldDelegate.measA != measA ||
        oldDelegate.measB != measB;
  }
}
