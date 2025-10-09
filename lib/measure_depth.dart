// lib/measure_depth.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MeasureDepthScreen extends StatefulWidget {
  final File imageFile;
  const MeasureDepthScreen({super.key, required this.imageFile});

  @override
  State<MeasureDepthScreen> createState() => _MeasureDepthScreenState();
}

enum MeasureMode { calibrate, measure }
enum _Handle { none, calibA, calibB, measA, measB }

class _MeasureDepthScreenState extends State<MeasureDepthScreen>
    with TickerProviderStateMixin {
  final TextEditingController _knownLengthFt =
      TextEditingController(text: '4.0');

  MeasureMode _mode = MeasureMode.calibrate;

  // Points in image-canvas coordinates (unscaled child space)
  Offset? _calibA, _calibB, _measA, _measB;

  // Drag state
  _Handle _dragging = _Handle.none;

  // Calibration
  double? _pxPerFt;
  double? _measuredFeet;

  // Intrinsic image size
  Size? _imageSize;

  // ===== Visual tuning (smaller) =====
  static const double _dotRadius = 8;   // smaller markers
  static const double _haloRadius = 10;
  static const double _stroke = 4;
  static const double _midTickR = 3;
  static const double _hitRadius = 36;  // big hitbox for tiny dots

  bool get _calibrationReady => _calibA != null && _calibB != null;
  bool get _measurementReady => _measA != null && _measB != null;

  // ===== Zoom / Pan =====
  late final TransformationController _xfm;
  Animation<Matrix4>? _zoomAnim;
  AnimationController? _animCtrl;

  // Track fingers on the OVERLAY so we can let the viewer own multi-touch
  int _overlayPointers = 0;
  bool get _isZoomed => _xfm.value.getMaxScaleOnAxis() > 1.01;

  @override
  void initState() {
    super.initState();
    _xfm = TransformationController();
    _resolveImageSize();
  }

  @override
  void dispose() {
    _animCtrl?.dispose();
    _xfm.dispose();
    _knownLengthFt.dispose();
    super.dispose();
  }

  void _resolveImageSize() {
    final provider = FileImage(widget.imageFile);
    final stream = provider.resolve(const ImageConfiguration());
    ImageStreamListener? listener;
    listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() {
        _imageSize =
            Size(info.image.width.toDouble(), info.image.height.toDouble());
      });
      stream.removeListener(listener!);
    }, onError: (e, st) {
      if (!mounted) return;
      setState(() => _imageSize = const Size(400, 300));
      stream.removeListener(listener!);
    });
    stream.addListener(listener);
  }

  // ---------- Gesture logic ----------
  _Handle _hitTest(Offset p) {
    double d(Offset? a) => a == null ? 1e9 : (p - a).distance;
    final map = <_Handle, double>{
      _Handle.calibA: d(_calibA),
      _Handle.calibB: d(_calibB),
      _Handle.measA:  d(_measA),
      _Handle.measB:  d(_measB),
    };

    _Handle best = _Handle.none;
    double bestD = _hitRadius;
    map.forEach((h, dist) {
      if (dist < bestD) {
        best = h;
        bestD = dist;
      }
    });

    // Only handles from the current mode are draggable
    if (_mode == MeasureMode.calibrate &&
        (best == _Handle.measA || best == _Handle.measB)) return _Handle.none;
    if (_mode == MeasureMode.measure &&
        (best == _Handle.calibA || best == _Handle.calibB)) return _Handle.none;
    return best;
  }

  void _onPanStart(DragStartDetails d) {
    if (_overlayPointers >= 2) return; // overlay yields when 2+ fingers
    final p = d.localPosition;

    final grabbed = _hitTest(p);
    if (grabbed != _Handle.none) {
      HapticFeedback.selectionClick();
      setState(() => _dragging = grabbed);
      return;
    }

    // Start new segment in the active mode
    setState(() {
      if (_mode == MeasureMode.calibrate) {
        if (_calibA == null || (_calibA != null && _calibB != null)) {
          _calibA = p; _calibB = p; _dragging = _Handle.calibB;
        } else {
          _calibB = p; _dragging = _Handle.calibB;
        }
      } else {
        if (_measA == null || (_measA != null && _measB != null)) {
          _measA = p; _measB = p; _dragging = _Handle.measB;
        } else {
          _measB = p; _dragging = _Handle.measB;
        }
      }
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_overlayPointers >= 2 || _dragging == _Handle.none) return;
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
    if (_overlayPointers >= 2) return;
    setState(() => _dragging = _Handle.none);
  }

  // Tap: if on a handle, arm it for drag; otherwise place or move nearest
  void _onTapDown(TapDownDetails d) {
    if (_overlayPointers >= 2) return;
    final p = d.localPosition;

    final grabbed = _hitTest(p);
    if (grabbed != _Handle.none) {
      setState(() => _dragging = grabbed); // arm it; user can drag right away
      return;
    }

    setState(() {
      if (_mode == MeasureMode.calibrate) {
        if (_calibA == null) {
          _calibA = p;
        } else if (_calibB == null) {
          _calibB = p;
        } else {
          final dA = (_calibA! - p).distance;
          final dB = (_calibB! - p).distance;
          if (dA <= dB) {
            _calibA = p;
          } else {
            _calibB = p;
          }
        }
      } else {
        if (_measA == null) {
          _measA = p;
        } else if (_measB == null) {
          _measB = p;
        } else {
          final dA = (_measA! - p).distance;
          final dB = (_measB! - p).distance;
          if (dA <= dB) {
            _measA = p;
          } else {
            _measB = p;
          }
        }
      }
    });
  }

  // ---------- Calc / flow ----------
  double _dist(Offset a, Offset b) => (a - b).distance;

  void _setCalibration() {
    if (!_calibrationReady) { _snack('Tap/drag two calibration points first.'); return; }
    final known = double.tryParse(_knownLengthFt.text);
    if (known == null || known <= 0) { _snack('Enter a valid known length (ft).'); return; }

    final px = _dist(_calibA!, _calibB!);
    if (px <= 0) { _snack('Calibration points overlap.'); return; }

    setState(() {
      _pxPerFt = px / known;
      _mode = MeasureMode.measure;
      _measA = _measB = null;
      _measuredFeet = null;
    });
    _snack('Calibration set: ${_pxPerFt!.toStringAsFixed(2)} px/ft. Now measure.');
  }

  void _compute() {
    if (_pxPerFt == null) { _snack('Set calibration first.'); return; }
    if (!_measurementReady) { _snack('Place two measurement points (tap or drag).'); return; }

    final ft = _dist(_measA!, _measB!) / _pxPerFt!;
    setState(() => _measuredFeet = ft);
    _snack('Depth = ${ft.toStringAsFixed(2)} ft');
  }

  void _finish() {
    if (_measuredFeet == null || _measuredFeet! <= 0) { _snack('No depth computed yet.'); return; }
    Navigator.of(context).pop<double>(_measuredFeet!);
  }

  void _resetAll() {
    setState(() {
      _calibA = _calibB = _measA = _measB = null;
      _pxPerFt = null; _measuredFeet = null;
      _mode = MeasureMode.calibrate;
      _knownLengthFt.text = '4.0';
      _dragging = _Handle.none;
    });
    _snack('Reset. Calibrate again.');
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // ===== Zoom helpers =====
  void _animateTo(Matrix4 target) {
    _animCtrl?.dispose();
    _animCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
    _zoomAnim = Matrix4Tween(begin: _xfm.value, end: target).animate(
      CurvedAnimation(parent: _animCtrl!, curve: Curves.easeOutCubic),
    )..addListener(() => setState(() => _xfm.value = _zoomAnim!.value));
    _animCtrl!.forward();
  }

  void _resetZoom() => _animateTo(Matrix4.identity());

  // Double-tap: zoom in/out around tap
  void _onDoubleTapDown(TapDownDetails d) {
    final currentScale = _xfm.value.getMaxScaleOnAxis();
    final target = currentScale < 2.0 ? 2.5 : 1.0;
    final f = d.localPosition;
    final m = Matrix4.identity()
      ..translate(f.dx, f.dy)
      ..scale(target)
      ..translate(-f.dx, -f.dy);
    _animateTo(m);
  }

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
          Expanded(
            child: Center(
              // Stack: bottom = InteractiveViewer (pinch/pan), top = overlay (single-finger)
              child: Stack(
                children: [
                  // Bottom: viewer always listening for scale;
                  // pan only when zoomed to avoid drifting at 1x.
                  InteractiveViewer(
                    transformationController: _xfm,
                    minScale: 1.0,
                    maxScale: 10.0,
                    scaleEnabled: true,
                    panEnabled: _isZoomed,
                    boundaryMargin: EdgeInsets.zero,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: imgW,
                      height: imgH,
                      child: Image.file(widget.imageFile, fit: BoxFit.fill),
                    ),
                  ),

                  // Top: overlay that handles single-finger work.
                  // It *ignores* events as soon as 2+ fingers touch,
                  // so the InteractiveViewer underneath wins pinch/drag.
                  Positioned.fill(
                    child: Listener(
                      onPointerDown: (_) => setState(() => _overlayPointers++),
                      onPointerUp: (_) => setState(() =>
                          _overlayPointers = (_overlayPointers - 1).clamp(0, 10)),
                      onPointerCancel: (_) => setState(() =>
                          _overlayPointers = (_overlayPointers - 1).clamp(0, 10)),
                      child: AbsorbPointer(
                        absorbing: _overlayPointers >= 2, // yield to viewer while pinching
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onDoubleTapDown: _onDoubleTapDown,
                          onDoubleTap: () {},
                          onTapDown: _onTapDown,
                          onPanStart: _onPanStart,
                          onPanUpdate: _onPanUpdate,
                          onPanEnd: _onPanEnd,
                          child: CustomPaint(
                            painter: _OverlayPainter(
                              calibA: _calibA, calibB: _calibB,
                              measA: _measA,   measB: _measB,
                              dotRadius: _dotRadius,
                              haloRadius: _haloRadius,
                              stroke: _stroke,
                              midTickR: _midTickR,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
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
                        ButtonSegment(value: MeasureMode.measure,   label: Text('Measure')),
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
  final double dotRadius, haloRadius, stroke, midTickR;

  _OverlayPainter({
    required this.calibA,
    required this.calibB,
    required this.measA,
    required this.measB,
    required this.dotRadius,
    required this.haloRadius,
    required this.stroke,
    required this.midTickR,
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

    final lineHalo = Paint()
      ..color = Colors.black.withOpacity(0.35)
      ..strokeWidth = stroke + 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    final blueLine = Paint()
      ..color = const Color(0xFF1565C0)
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    final greenLine = Paint()
      ..color = const Color(0xFF2E7D32)
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    void point(Offset? p, Paint color) {
      if (p == null) return;
      canvas.drawCircle(p, haloRadius, whiteHalo);
      canvas.drawCircle(p, dotRadius, color);
    }

    void drawSegment(Offset? a, Offset? b, Paint line) {
      if (a == null || b == null) return;
      canvas.drawLine(a, b, lineHalo);
      canvas.drawLine(a, b, line);

      // midpoint tick
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      final midFill = Paint()
        ..color = (line == blueLine) ? const Color(0xFF1565C0) : const Color(0xFF2E7D32)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;
      final midStroke = Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      canvas.drawCircle(mid, midTickR, midFill);
      canvas.drawCircle(mid, midTickR, midStroke);
    }

    // Calib (blue)
    point(calibA, blue);
    point(calibB, blue);
    drawSegment(calibA, calibB, blueLine);

    // Measure (green)
    point(measA, green);
    point(measB, green);
    drawSegment(measA, measB, greenLine);
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) {
    return old.calibA != calibA ||
        old.calibB != calibB ||
        old.measA != measA ||
        old.measB != measB ||
        old.dotRadius != dotRadius ||
        old.haloRadius != haloRadius ||
        old.stroke != stroke ||
        old.midTickR != midTickR;
  }
}
