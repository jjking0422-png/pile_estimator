import 'dart:io';
import 'package:flutter/material.dart';

class MeasureDepthScreen extends StatefulWidget {
  final File imageFile;
  const MeasureDepthScreen({super.key, required this.imageFile});

  @override
  State<MeasureDepthScreen> createState() => _MeasureDepthScreenState();
}

enum MeasureMode { calibrate, measure }
enum _Handle { none, calibA, calibB, measA, measB }

class _MeasureDepthScreenState extends State<MeasureDepthScreen> {
  final TextEditingController _knownLengthFt = TextEditingController(text: '4.0');

  MeasureMode _mode = MeasureMode.calibrate;

  // Points in image-canvas coordinates
  Offset? _calibA, _calibB, _measA, _measB;

  // Drag state
  _Handle _dragging = _Handle.none;

  // Calibration
  double? _pxPerFt;
  double? _measuredFeet;

  // Intrinsic image size for exact canvas sizing
  Size? _imageSize;

  // Visual tuning
  static const double _dotRadius = 18;     // doubled
  static const double _haloRadius = 24;    // doubled
  static const double _stroke = 10;        // doubled
  static const double _hitRadius = 28;     // radius for grabbing a handle

  bool get _calibrationReady => _calibA != null && _calibB != null;
  bool get _measurementReady => _measA != null && _measB != null;

  @override
  void initState() {
    super.initState();
    _resolveImageSize();
  }

  void _resolveImageSize() {
    final provider = FileImage(widget.imageFile);
    final stream = provider.resolve(const ImageConfiguration());
    ImageStreamListener? listener;
    listener = ImageStreamListener((info, _) {
      setState(() {
        _imageSize = Size(info.image.width.toDouble(), info.image.height.toDouble());
      });
      stream.removeListener(listener!);
    }, onError: (e, st) {
      setState(() => _imageSize = const Size(400, 300));
      stream.removeListener(listener!);
    });
    stream.addListener(listener);
  }

  // ---------- Gesture logic (tap + drag, adjustable endpoints) ----------

  _Handle _hitTest(Offset p) {
    double d(Offset? a) => a == null ? 1e9 : (p - a).distance;
    final entries = <_Handle, double>{
      _Handle.calibA: d(_calibA),
      _Handle.calibB: d(_calibB),
      _Handle.measA:  d(_measA),
      _Handle.measB:  d(_measB),
    };
    _Handle best = _Handle.none;
    double bestD = _hitRadius;
    entries.forEach((h, dist) {
      if (dist < bestD) {
        bestD = dist;
        best = h;
      }
    });
    // Only allow dragging handles relevant to the current mode
    if (_mode == MeasureMode.calibrate &&
        (best == _Handle.measA || best == _Handle.measB)) return _Handle.none;
    if (_mode == MeasureMode.measure &&
        (best == _Handle.calibA || best == _Handle.calibB)) return _Handle.none;
    return best;
  }

  void _onPanStart(DragStartDetails d) {
    final p = d.localPosition;
    // Try to grab a nearby handle first
    final grabbed = _hitTest(p);
    if (grabbed != _Handle.none) {
      setState(() => _dragging = grabbed);
      return;
    }

    // Otherwise start laying out a new segment in the active mode
    setState(() {
      if (_mode == MeasureMode.calibrate) {
        // Start new calibration line
        if (_calibA == null || (_calibA != null && _calibB != null)) {
          _calibA = p;
          _calibB = p;      // live-drag to set B
          _dragging = _Handle.calibB;
        } else {
          // A is set, start dragging B
          _calibB = p;
          _dragging = _Handle.calibB;
        }
      } else {
        if (_measA == null || (_measA != null && _measB != null)) {
          _measA = p;
          _measB = p;
          _dragging = _Handle.measB;
        } else {
          _measB = p;
          _dragging = _Handle.measB;
        }
      }
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_dragging == _Handle.none) return;
    final p = d.localPosition;
    setState(() {
      switch (_dragging) {
        case _Handle.calibA: _calibA = p; break;
        case _Handle.calibB: _calibB = p; break;
        case _Handle.measA:  _measA  = p; break;
        case _Handle.measB:  _measB  = p; break;
        case _Handle.none: break;
      }
    });
  }

  void _onPanEnd(DragEndDetails d) {
    setState(() => _dragging = _Handle.none);
  }

  // Fallback tap (single taps without dragging)
  void _onTapDown(TapDownDetails d) {
    final p = d.localPosition;
    setState(() {
      if (_mode == MeasureMode.calibrate) {
        if (_calibA == null) _calibA = p;
        else if (_calibB == null) _calibB = p;
        else { _calibA = p; _calibB = null; }
      } else {
        if (_measA == null) _measA = p;
        else if (_measB == null) _measB = p;
        else { _measA = p; _measB = null; }
      }
    });
  }

  // ---------- Calc / flow ----------

  double _dist(Offset a, Offset b) => (a - b).distance;

  void _setCalibration() {
    if (!_calibrationReady) {
      _snack('Tap/drag two calibration points first.');
      return;
    }
    final known = double.tryParse(_knownLengthFt.text);
    if (known == null || known <= 0) {
      _snack('Enter a valid known length (ft).');
      return;
    }
    final px = _dist(_calibA!, _calibB!);
    if (px <= 0) {
      _snack('Calibration points overlap.');
      return;
    }
    setState(() {
      _pxPerFt = px / known;
      _mode = MeasureMode.measure;
      _measA = _measB = null;
      _measuredFeet = null;
    });
    _snack('Calibration set: ${_pxPerFt!.toStringAsFixed(2)} px/ft. Now measure.');
  }

  void _compute() {
    if (_pxPerFt == null) {
      _snack('Set calibration first.');
      return;
    }
    if (!_measurementReady) {
      _snack('Place two measurement points (tap or drag).');
      return;
    }
    final px = _dist(_measA!, _measB!);
    final ft = px / _pxPerFt!;
    setState(() => _measuredFeet = ft);
    _snack('Depth = ${ft.toStringAsFixed(2)} ft');
  }

  void _finish() {
    final v = _measuredFeet;
    if (v == null || v <= 0) {
      _snack('No depth computed yet.');
      return;
    }
    Navigator.of(context).pop<double>(v);
  }

  void _resetAll() {
    setState(() {
      _calibA = _calibB = _measA = _measB = null;
      _pxPerFt = null;
      _measuredFeet = null;
      _mode = MeasureMode.calibrate;
      _knownLengthFt.text = '4.0';
      _dragging = _Handle.none;
    });
    _snack('Reset. Calibrate again.');
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final imgW = _imageSize?.width ?? 400;
    final imgH = _imageSize?.height ?? 300;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Measure Depth'),
        actions: [
          IconButton(onPressed: _resetAll, tooltip: 'Reset', icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          // Full image, no cropping; overlay shares exact canvas size.
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: imgW, height: imgH,
                  child: Listener( // ensures gesture coords are in this box
                    behavior: HitTestBehavior.deferToChild,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: _onTapDown,
                      onPanStart: _onPanStart,
                      onPanUpdate: _onPanUpdate,
                      onPanEnd: _onPanEnd,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Image.file(widget.imageFile, fit: BoxFit.fill),
                          ),
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _OverlayPainter(
                                calibA: _calibA, calibB: _calibB,
                                measA: _measA,   measB: _measB,
                                dotRadius: _dotRadius,
                                haloRadius: _haloRadius,
                                stroke: _stroke,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
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
                    if (_mode == MeasureMode.calibrate) ...[
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
                      FilledButton(
                        onPressed: _calibrationReady ? _setCalibration : null,
                        child: const Text('Set calibration'),
                      ),
                    ],
                  ],
                ),

                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _statTile('Calibration pts', _calibrationReady ? '2/2 ✓' : (_calibA == null ? '0/2' : '1/2'), Icons.tune)),
                    const SizedBox(width: 8),
                    Expanded(child: _statTile('Pixels / ft', _pxPerFt == null ? '--' : _pxPerFt!.toStringAsFixed(1), Icons.straighten)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _statTile('Measure pts', _measurementReady ? '2/2 ✓' : (_measA == null ? '0/2' : '1/2'), Icons.straighten_outlined)),
                    const SizedBox(width: 8),
                    Expanded(child: _statTile('Depth (ft)', _measuredFeet == null ? '--' : _measuredFeet!.toStringAsFixed(2), Icons.calculate)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _measurementReady ? _compute : null,
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

  Widget _statTile(String title, String value, IconData icon) {
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
  final Offset? calibA, calibB, measA, measB;
  final double dotRadius, haloRadius, stroke;

  _OverlayPainter({
    required this.calibA,
    required this.calibB,
    required this.measA,
    required this.measB,
    required this.dotRadius,
    required this.haloRadius,
    required this.stroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final whiteHalo = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final blue = Paint()
      ..color = const Color(0xFF1565C0)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final green = Paint()
      ..color = const Color(0xFF2E7D32)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final blueLineHalo = Paint()
      ..color = Colors.white.withOpacity(0.9)
      ..strokeWidth = stroke + 3
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final blueLine = Paint()
      ..color = const Color(0xFF1565C0)
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final greenLineHalo = Paint()
      ..color = Colors.white.withOpacity(0.9)
      ..strokeWidth = stroke + 3
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final greenLine = Paint()
      ..color = const Color(0xFF2E7D32)
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    void point(Offset? p, Paint color) {
      if (p == null) return;
      canvas.drawCircle(p, haloRadius, whiteHalo);
      canvas.drawCircle(p, dotRadius, color);
    }

    // Calib (blue)
    point(calibA, blue);
    point(calibB, blue);
    if (calibA != null && calibB != null) {
      canvas.drawLine(calibA!, calibB!, blueLineHalo);
      canvas.drawLine(calibA!, calibB!, blueLine);
    }

    // Measure (green)
    point(measA, green);
    point(measB, green);
    if (measA != null && measB != null) {
      canvas.drawLine(measA!, measB!, greenLineHalo);
      canvas.drawLine(measA!, measB!, greenLine);
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) {
    return old.calibA != calibA ||
        old.calibB != calibB ||
        old.measA != measA ||
        old.measB != measB ||
        old.dotRadius != dotRadius ||
        old.haloRadius != haloRadius ||
        old.stroke != stroke;
  }
}
