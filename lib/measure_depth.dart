// lib/measure_depth.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4, Vector3;

class MeasureDepthScreen extends StatefulWidget {
  final File imageFile;
  const MeasureDepthScreen({super.key, required this.imageFile});

  @override
  State<MeasureDepthScreen> createState() => _MeasureDepthScreenState();
}

enum MeasureMode { calibrate, measure }
enum _Handle { none, calibA, calibB, measA, measB }
enum _GestureMode { none, singleEdit, pinchZoom }

class _MeasureDepthScreenState extends State<MeasureDepthScreen>
    with TickerProviderStateMixin {
  // --- Calibration input (imperial: feet & inches parsed into inches)
  final TextEditingController _knownLengthCtrl =
      TextEditingController(text: '4 ft'); // flexible input

  MeasureMode _mode = MeasureMode.calibrate;

  // Scene-space points (image pixel space)
  Offset? _calibA, _calibB, _measA, _measB;
  _Handle _dragging = _Handle.none;

  // Calibration
  double? _pxPerInch;      // pixels per inch (imperial)
  double? _measuredInches; // result in inches

  // Image size (intrinsic)
  Size? _imageSize;

  // Visual tuning (screen-space base sizes; painter keeps them constant on screen)
  static const double _dotRadiusBase = 6;
  static const double _haloRadiusBase = 8;
  static const double _strokeBase = 3;
  static const double _midTickBase = 3;
  static const double _hitRadiusScreen = 36;

  bool get _calibrationReady => _calibA != null && _calibB != null;
  bool get _measurementReady => _measA != null && _measB != null;

  // Transform / gesture state
  final TransformationController _xfm = TransformationController();
  AnimationController? _animCtrl;
  Animation<Matrix4>? _zoomAnim;

  _GestureMode _gMode = _GestureMode.none;
  Matrix4? _startMatrix;
  double _startScale = 1.0;
  Offset _startSceneFocal = Offset.zero;

  // Pointer tracking to suppress accidental taps on pinch
  int _activePointers = 0;
  bool _everMultitouch = false;

  // Track fingers across a gesture to suppress accidental taps
  int _gestureMaxPointers = 0;

  // Single-finger placement/drag state
  Offset _singleStartViewport = Offset.zero;
  Offset _singleStartScene = Offset.zero;
  bool _singleMoved = false;

  static const double _minScale = 1.0;
  static const double _maxScale = 10.0;
  static const double _tapSlop = 8.0;

  double get _scale => _xfm.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    _resolveImageSize();
  }

  @override
  void dispose() {
    _animCtrl?.dispose();
    _xfm.dispose();
    _knownLengthCtrl.dispose();
    super.dispose();
  }

  void _resolveImageSize() {
    final provider = FileImage(widget.imageFile);
    final stream = provider.resolve(const ImageConfiguration());
    ImageStreamListener? listener;
    listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() {
        _imageSize = Size(info.image.width.toDouble(), info.image.height.toDouble());
      });
      stream.removeListener(listener!);
    }, onError: (_, __) {
      if (!mounted) return;
      setState(() => _imageSize = const Size(400, 300));
      stream.removeListener(listener!);
    });
    stream.addListener(listener);
  }

  // ---------- Math helpers
  Offset _toScene(Offset viewportPoint, [Matrix4? matrix]) {
    final m = (matrix ?? _xfm.value).clone()..invert();
    final v = m.transform3(Vector3(viewportPoint.dx, viewportPoint.dy, 0));
    return Offset(v.x, v.y);
  }

  Offset _clampToImage(Offset p) {
    final sz = _imageSize!;
    return Offset(
      p.dx.clamp(0.0, sz.width),
      p.dy.clamp(0.0, sz.height),
    );
  }

  Matrix4 _clampMatrix(Matrix4 m, Size viewport, Size image) {
    final scale = m.getMaxScaleOnAxis().clamp(_minScale, _maxScale);
    final tx = m.storage[12], ty = m.storage[13];
    final scaledW = image.width * scale, scaledH = image.height * scale;

    double minTx, maxTx, minTy, maxTy;
    if (scaledW <= viewport.width) {
      final cx = (viewport.width - scaledW) / 2.0; minTx = maxTx = cx;
    } else { maxTx = 0.0; minTx = viewport.width - scaledW; }

    if (scaledH <= viewport.height) {
      final cy = (viewport.height - scaledH) / 2.0; minTy = maxTy = cy;
    } else { maxTy = 0.0; minTy = viewport.height - scaledH; }

    return Matrix4.identity()
      ..translate(tx.clamp(minTx, maxTx), ty.clamp(minTy, maxTy))
      ..scale(scale);
  }

  // ---------- Hit testing (scene space)
  _Handle _hitTestScene(Offset sceneP) {
    double d(Offset? a) => a == null ? 1e9 : (sceneP - a).distance;
    final hitScene = _hitRadiusScreen / _scale.clamp(1.0, 100.0);

    _Handle best = _Handle.none;
    double bestD = hitScene;

    void check(_Handle h, Offset? p) {
      final dist = d(p);
      if (dist < bestD) { best = h; bestD = dist; }
    }

    // Only hit-test points for the active mode
    if (_mode == MeasureMode.calibrate) {
      check(_Handle.calibA, _calibA);
      check(_Handle.calibB, _calibB);
    } else {
      check(_Handle.measA, _measA);
      check(_Handle.measB, _measB);
    }
    return best;
  }

  // ---------- Pointer listener: detects second finger ASAP
  void _onPointerDown(PointerDownEvent e) {
    _activePointers++;
    if (_activePointers >= 2) {
      _everMultitouch = true;
      if (_gMode == _GestureMode.singleEdit) {
        _gMode = _GestureMode.pinchZoom;
        _startMatrix = _xfm.value.clone();
        _startScale = _startMatrix!.getMaxScaleOnAxis();
        _startSceneFocal = _toScene(e.localPosition, _startMatrix);
        _dragging = _Handle.none;
      }
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _activePointers = (_activePointers - 1).clamp(0, 10);
    if (_activePointers == 0) _everMultitouch = false;
  }

  // ---------- Unified gestures
  void _onScaleStart(ScaleStartDetails d) {
    if (_imageSize == null) return;

    _gestureMaxPointers = d.pointerCount;

    if (d.pointerCount >= 2) {
      _gMode = _GestureMode.pinchZoom;
      _startMatrix = _xfm.value.clone();
      _startScale = _startMatrix!.getMaxScaleOnAxis();
      _startSceneFocal = _toScene(d.localFocalPoint, _startMatrix);
      _dragging = _Handle.none;
      return;
    }

    _gMode = _GestureMode.singleEdit;
    _singleStartViewport = d.localFocalPoint;
    _singleStartScene = _toScene(_singleStartViewport);
    _singleMoved = false;

    final grabbed = _hitTestScene(_singleStartScene);
    _dragging = grabbed;
    if (grabbed != _Handle.none) {
      HapticFeedback.selectionClick();
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_imageSize == null) return;

    // Track the maximum fingers used during this gesture
    if (d.pointerCount > _gestureMaxPointers) {
      _gestureMaxPointers = d.pointerCount;
    }

    final img = _imageSize!;

    if (_gMode == _GestureMode.singleEdit) {
      // If a second finger joins, switch to pinch mode and cancel edit (no point placement)
      if (_gestureMaxPointers >= 2 || _everMultitouch) {
        _gMode = _GestureMode.pinchZoom;
        _startMatrix = _xfm.value.clone();
        _startScale = _startMatrix!.getMaxScaleOnAxis();
        _startSceneFocal = _toScene(d.localFocalPoint, _startMatrix);
        _dragging = _Handle.none;
        return;
      }

      // Normal single-finger edit/placement
      final curViewport = d.localFocalPoint;
      if ((curViewport - _singleStartViewport).distance > _tapSlop) {
        _singleMoved = true;
      }
      final curSceneRaw = _toScene(curViewport);
      final curScene = _clampToImage(curSceneRaw);

      if (_dragging != _Handle.none) {
        setState(() {
          switch (_dragging) {
            case _Handle.calibA: _calibA = curScene; break;
            case _Handle.calibB: _calibB = curScene; break;
            case _Handle.measA:  _measA  = curScene; break;
            case _Handle.measB:  _measB  = curScene; break;
            case _Handle.none: break;
          }
        });
      } else if (_singleMoved) {
        setState(() {
          if (_mode == MeasureMode.calibrate) {
            if (_calibA == null || (_calibA != null && _calibB != null)) {
              _calibA = _clampToImage(_singleStartScene); _calibB = curScene; _dragging = _Handle.calibB;
            } else {
              _calibB = curScene; _dragging = _Handle.calibB;
            }
          } else {
            if (_measA == null || (_measA != null && _measB != null)) {
              _measA = _clampToImage(_singleStartScene); _measB = curScene; _dragging = _Handle.measB;
            } else {
              _measB = curScene; _dragging = _Handle.measB;
            }
          }
        });
      }
      return;
    }

    if (_gMode == _GestureMode.pinchZoom) {
      // Keep the same scene point under the fingers (no drift)
      final desiredScale = (_startScale * d.scale).clamp(_minScale, _maxScale);
      final focalV = d.localFocalPoint;

      Matrix4 next = Matrix4.identity()
        ..translate(focalV.dx, focalV.dy)
        ..scale(desiredScale)
        ..translate(-_startSceneFocal.dx, -_startSceneFocal.dy);

      _xfm.value = next;          // update continuously
      setState(() {});            // ensure overlay repaints same frame
      return;
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_imageSize == null) return;

    final img = _imageSize!;
    final vp = Size(img.width, img.height);

    if (_gMode == _GestureMode.pinchZoom) {
      // Clamp once at the end so content stays in-bounds
      setState(() => _xfm.value = _clampMatrix(_xfm.value, vp, img));
      _gMode = _GestureMode.none;
      _startMatrix = null;
      _gestureMaxPointers = 0;
      // _everMultitouch resets when all pointers are up
      return;
    }

    if (_gMode == _GestureMode.singleEdit) {
      // If at any time during this gesture we had 2+ fingers, or pointer listener saw multitouch: cancel tap
      if (_gestureMaxPointers >= 2 || _everMultitouch) {
        _gMode = _GestureMode.none;
        _dragging = _Handle.none;
        _gestureMaxPointers = 0;
        return;
      }

      if (!_singleMoved) {
        final sceneP = _clampToImage(_singleStartScene);
        final grabbed = _hitTestScene(sceneP);
        if (grabbed != _Handle.none) {
          setState(() => _dragging = grabbed); // will drag on next move
        } else {
          setState(() {
            if (_mode == MeasureMode.calibrate) {
              if (_calibA == null) _calibA = sceneP;
              else if (_calibB == null) _calibB = sceneP;
              else {
                final dA = (_calibA! - sceneP).distance;
                final dB = (_calibB! - sceneP).distance;
                if (dA <= dB) _calibA = sceneP; else _calibB = sceneP;
              }
            } else {
              if (_measA == null) _measA = sceneP;
              else if (_measB == null) _measB = sceneP;
              else {
                final dA = (_measA! - sceneP).distance;
                final dB = (_measB! - sceneP).distance;
                if (dA <= dB) _measA = sceneP; else _measB = sceneP;
              }
            }
          });
        }
      }
      _gMode = _GestureMode.none;
      _dragging = _Handle.none;
      _gestureMaxPointers = 0;
      return;
    }
  }

  // ----- Double-tap zoom
  void _animateTo(Matrix4 target) {
    _animCtrl?.dispose();
    _animCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
    _zoomAnim = Matrix4Tween(begin: _xfm.value, end: target).animate(
      CurvedAnimation(parent: _animCtrl!, curve: Curves.easeOutCubic),
    )..addListener(() => setState(() => _xfm.value = _zoomAnim!.value));
    _animCtrl!.forward();
  }

  void _resetZoom() {
    if (_imageSize == null) return;
    final img = _imageSize!;
    final vp = Size(img.width, img.height);
    setState(() => _xfm.value = _clampMatrix(Matrix4.identity(), vp, img));
  }

  void _onDoubleTapDown(TapDownDetails d) {
    if (_imageSize == null) return;
    final img = _imageSize!;
    final vp = Size(img.width, img.height);

    final currentScale = _scale;
    final targetScale = currentScale < 2.0 ? 2.5 : 1.0;
    final f = d.localPosition;
    final sceneAtTap = _toScene(f);
    Matrix4 m = Matrix4.identity()
      ..translate(f.dx, f.dy)
      ..scale(targetScale)
      ..translate(-sceneAtTap.dx, -sceneAtTap.dy);
    m = _clampMatrix(m, vp, img);
    _animateTo(m);
  }

  // ----- Imperial parsing/formatting
  // Accepts:  "4' 6\"", "4-6", "4 ft 6 in", "4.5 ft", "54 in", "54\"", "4'6.5\"", "4.5"
  // Returns inches, or null if invalid.
  double? _parseImperialToInches(String raw) {
    String s = raw.trim().toLowerCase().replaceAll(',', ' ');
    if (s.isEmpty) return null;

    // Replace common tokens
    s = s
        .replaceAll('feet', 'ft')
        .replaceAll('foot', 'ft')
        .replaceAll('inches', 'in')
        .replaceAll('inch', 'in')
        .replaceAll('"', 'in')
        .replaceAll("''", 'in')
        .replaceAll("’", "'")
        .replaceAll('”', 'in')
        .replaceAll('″', 'in')
        .replaceAll('′', "'")
        .replaceAll('  ', ' ');

    // Patterns to try:
    // 1) ft-in: e.g., 5' 7.5", 5ft 7.5in, 5-7.5
    final ftIn = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(?:ft|\'|-)\s*(\d+(?:\.\d+)?)\s*(?:in)?\s*$');
    final m1 = ftIn.firstMatch(s);
    if (m1 != null) {
      final ft = double.tryParse(m1.group(1)!);
      final inch = double.tryParse(m1.group(2)!);
      if (ft != null && inch != null) return ft * 12 + inch;
    }

    // 2) just feet (possibly decimal): "4.5 ft" or "4.5"
    final justFt = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(?:ft)?\s*$');
    final m2 = justFt.firstMatch(s);
    if (m2 != null && s.contains('ft')) {
      final ft = double.tryParse(m2.group(1)!);
      if (ft != null) return ft * 12;
    }
    // If "4.5" without units—assume feet by default for convenience
    if (m2 != null && !s.contains('in') && !s.contains("'")) {
      final ft = double.tryParse(m2.group(1)!);
      if (ft != null) return ft * 12;
    }

    // 3) just inches: "54 in"
    final justIn = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*in\s*$');
    final m3 = justIn.firstMatch(s);
    if (m3 != null) {
      final inch = double.tryParse(m3.group(1)!);
      if (inch != null) return inch;
    }

    return null;
  }

  // Format inches as feet-inches to nearest 1/16"
  String _formatFeetInches(double inches, {bool withParenInches = true}) {
    if (inches.isNaN || inches.isInfinite) return '--';
    // Round to nearest 1/16"
    final sixteenths = (inches * 16).round();
    int wholeSixteenths = sixteenths;

    final wholeInches = wholeSixteenths ~/ 16;
    final frac16 = wholeSixteenths % 16;

    final feet = wholeInches ~/ 12;
    int inchesPart = wholeInches % 12;

    // Reduce fraction (e.g., 8/16 -> 1/2)
    int num = frac16;
    int den = 16;
    int gcd(int a, int b) => b == 0 ? a.abs() : gcd(b, a % b);
    if (num != 0) {
      final g = gcd(num, den);
      num ~/= g; den ~/= g;
    }

    final pieces = <String>[];
    pieces.add("$feet′");
    if (num == 0) {
      pieces.add(" $inchesPart″");
    } else {
      pieces.add(" $inchesPart ${num}/${den}″");
    }

    final main = pieces.join();
    return withParenInches ? "$main (${inches.toStringAsFixed(2)} in)" : main;
  }

  // ----- Calc / flow
  double _dist(Offset a, Offset b) => (a - b).distance;

  void _setCalibration() {
    if (!_calibrationReady) { _snack('Place two blue calibration points.'); return; }
    final inches = _parseImperialToInches(_knownLengthCtrl.text);
    if (inches == null || inches <= 0) {
      _snack('Enter a valid length (e.g., 4′ 6″, 4.5 ft, 54 in).');
      return;
    }
    final px = _dist(_calibA!, _calibB!);
    if (px <= 0) { _snack('Calibration points overlap.'); return; }

    setState(() {
      _pxPerInch = px / inches; // pixels per inch
      _mode = MeasureMode.measure;
      // Clear calibration points per your request
      _calibA = null;
      _calibB = null;
      _measA = _measB = null;
      _measuredInches = null;
    });
    _snack('Calibrated: ${_pxPerInch!.toStringAsFixed(2)} px/in. Now measure (green).');
  }

  void _compute() {
    if (_pxPerInch == null) { _snack('Set calibration first.'); return; }
    if (!_measurementReady) { _snack('Place two green measurement points.'); return; }
    final px = _dist(_measA!, _measB!);
    final inches = px / _pxPerInch!;
    setState(() => _measuredInches = inches);
    _snack('Depth = ${_formatFeetInches(inches)}');
  }

  void _finish() {
    if (_measuredInches == null || _measuredInches! <= 0) { _snack('No depth computed yet.'); return; }
    // Return inches as the canonical value
    Navigator.of(context).pop<double>(_measuredInches!);
  }

  void _resetAll() {
    setState(() {
      _calibA = _calibB = _measA = _measB = null;
      _pxPerInch = null; _measuredInches = null;
      _mode = MeasureMode.calibrate;
      _knownLengthCtrl.text = '4 ft';
      _dragging = _Handle.none;
      _xfm.value = Matrix4.identity();
      _activePointers = 0;
      _everMultitouch = false;
    });
    _snack('Reset. Enter known length (ft/in), then set two blue points.');
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // ---------- UI
  @override
  Widget build(BuildContext context) {
    final imgW = _imageSize?.width ?? 400;
    final imgH = _imageSize?.height ?? 300;

    final pixelsPer = _pxPerInch == null ? '--' : _pxPerInch!.toStringAsFixed(2);
    final depthText = _measuredInches == null ? '--' : _formatFeetInches(_measuredInches!, withParenInches: true);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Measure Depth'),
        actions: [
          IconButton(onPressed: _resetAll, tooltip: 'Reset', icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          // IMAGE + OVERLAY (hard clipped so it never paints over controls)
          Expanded(
            child: Center(
              child: ClipRect(
                child: SizedBox(
                  width: imgW,
                  height: imgH,
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      AnimatedBuilder(
                        animation: _xfm,
                        builder: (_, __) => Transform(
                          transform: _xfm.value,
                          child: SizedBox(
                            width: imgW, height: imgH,
                            child: Image.file(widget.imageFile, fit: BoxFit.fill),
                          ),
                        ),
                      ),
                      // Pointer listener wraps gestures to catch second finger ASAP
                      Positioned.fill(
                        child: Listener(
                          onPointerDown: _onPointerDown,
                          onPointerUp: _onPointerUp,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onScaleStart: _onScaleStart,
                            onScaleUpdate: _onScaleUpdate,
                            onScaleEnd: _onScaleEnd,
                            onDoubleTapDown: _onDoubleTapDown,
                            onDoubleTap: () {},
                            child: AnimatedBuilder(
                              animation: _xfm,
                              builder: (_, __) => Transform(
                                transform: _xfm.value,
                                child: CustomPaint(
                                  size: Size(imgW, imgH),
                                  painter: _OverlayPainter(
                                    calibA: _calibA, calibB: _calibB,
                                    measA: _measA,   measB: _measB,
                                    // keep visuals constant on-screen by dividing by scale
                                    dotRadiusScene: _dotRadiusBase / _scale,
                                    haloRadiusScene: _haloRadiusBase / _scale,
                                    strokeScene: (_strokeBase / _scale).clamp(1.0, double.infinity),
                                    midTickRScene: (_midTickBase / _scale).clamp(1.0, double.infinity),
                                  ),
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
            ),
          ),

          // CONTROLS
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Wrap(
              spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Box(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<MeasureMode>(
                      value: _mode,
                      onChanged: (m) => setState(() => _mode = m!),
                      items: const [
                        DropdownMenuItem(value: MeasureMode.calibrate, child: Text('Calibrate')),
                        DropdownMenuItem(value: MeasureMode.measure,   child: Text('Measure')),
                      ],
                    ),
                  ),
                ),
                if (_mode == MeasureMode.calibrate) ...[
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
                    child: TextField(
                      controller: _knownLengthCtrl,
                      keyboardType: TextInputType.text,
                      decoration: const InputDecoration(
                        labelText: 'Known length (feet & inches)',
                        hintText: 'e.g., 4′ 6″  |  4.5 ft  |  54 in',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: _calibrationReady ? _setCalibration : null,
                    child: const Text('Set calibration'),
                  ),
                ],
                FilledButton.icon(
                  onPressed: _resetZoom,
                  icon: const Icon(Icons.zoom_out_map),
                  label: const Text('Reset zoom'),
                ),
              ],
            ),
          ),

          // READOUTS
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: _statTile('Calibration pts', _calibrationReady ? '2/2 ✓' : (_calibA == null ? '0/2' : '1/2'), Icons.tune)),
                    const SizedBox(width: 8),
                    Expanded(child: _statTile('Pixels / inch', pixelsPer, Icons.straighten)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _statTile('Measure pts', _measurementReady ? '2/2 ✓' : (_measA == null ? '0/2' : '1/2'), Icons.straighten_outlined)),
                    const SizedBox(width: 8),
                    Expanded(child: _statTile('Depth', depthText, Icons.calculate)),
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
                      onPressed: (_measuredInches != null && _measuredInches! > 0) ? _finish : null,
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

class _Box extends StatelessWidget {
  final Widget child;
  const _Box({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      height: 44,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final Offset? calibA, calibB, measA, measB;
  // already converted to scene units (constant on screen)
  final double dotRadiusScene, haloRadiusScene, strokeScene, midTickRScene;

  _OverlayPainter({
    required this.calibA,
    required this.calibB,
    required this.measA,
    required this.measB,
    required this.dotRadiusScene,
    required this.haloRadiusScene,
    required this.strokeScene,
    required this.midTickRScene,
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
      ..strokeWidth = strokeScene + 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    final blueLine = Paint()
      ..color = const Color(0xFF1565C0)
      ..strokeWidth = strokeScene
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    final greenLine = Paint()
      ..color = const Color(0xFF2E7D32)
      ..strokeWidth = strokeScene
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    void point(Offset? p, Paint color) {
      if (p == null) return;
      canvas.drawCircle(p, haloRadiusScene, whiteHalo);
      canvas.drawCircle(p, dotRadiusScene, color);
    }

    void drawSegment(Offset? a, Offset? b, Paint line) {
      if (a == null || b == null) return;
      canvas.drawLine(a, b, lineHalo);
      canvas.drawLine(a, b, line);

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
      canvas.drawCircle(mid, midTickRScene, midFill);
      canvas.drawCircle(mid, midTickRScene, midStroke);
    }

    // Calibrate (blue)
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
        old.dotRadiusScene != dotRadiusScene ||
        old.haloRadiusScene != haloRadiusScene ||
        old.strokeScene != strokeScene ||
        old.midTickRScene != midTickRScene;
  }
}
