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
enum _Handle { none, calibA, calibB, calibC, calibD, measA, measB }
enum _GestureMode { none, singleEdit, pinchZoom }
enum _CalibKind { singleScale, plane } // 2-pt vs 4-pt (homography)

class _MeasureDepthScreenState extends State<MeasureDepthScreen>
    with TickerProviderStateMixin {
  // -------- Calibration inputs (imperial) --------
  final TextEditingController _knownLengthCtrl =
      TextEditingController(text: '21.5 in'); // single-scale known length
  final TextEditingController _knownWidthCtrl =
      TextEditingController(text: '4 ft');    // plane known rect width
  final TextEditingController _knownHeightCtrl =
      TextEditingController(text: '2 ft');    // plane known rect height

  _CalibKind _calibKind = _CalibKind.singleScale;
  MeasureMode _mode = MeasureMode.calibrate;

  // Points in scene (image) space
  Offset? _calibA, _calibB;           // single-scale: two points
  Offset? _calibC, _calibD;           // plane: four points (TL, TR, BR, BL)
  Offset? _measA, _measB;
  _Handle _dragging = _Handle.none;

  // Calibration state
  double? _pxPerInch;         // single-scale pixels per inch
  List<double>? _H;           // plane homography (3x3, length 9, row-major)
  double? _measuredInches;    // last result

  // Diagnostics caches
  double? _knownInchesCache, _calibPxCache, _measPxCache;
  String _diagCalib = 'none';

  // Image / viewport
  Size? _imageSize;
  Size _viewportSize = const Size(0, 0);

  // Visual tuning (constant on screen)
  static const double _dotRadiusBase = 6;
  static const double _haloRadiusBase = 8;
  static const double _strokeBase = 3;
  static const double _midTickBase = 3;
  static const double _hitRadiusScreen = 36;

  bool get _calibrationReady2 => _calibA != null && _calibB != null;
  bool get _calibrationReady4 =>
      _calibA != null && _calibB != null && _calibC != null && _calibD != null;
  bool get _measurementReady => _measA != null && _measB != null;

  // Transform / gesture
  final TransformationController _xfm = TransformationController();
  AnimationController? _animCtrl;
  Animation<Matrix4>? _zoomAnim;

  _GestureMode _gMode = _GestureMode.none;
  Matrix4? _startMatrix;
  double _startScale = 1.0;
  Offset _startSceneFocal = Offset.zero;

  int _activePointers = 0;
  bool _everMultitouch = false;
  int _gestureMaxPointers = 0;

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
    _knownWidthCtrl.dispose();
    _knownHeightCtrl.dispose();
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

  // -------- Math helpers --------
  Offset _toScene(Offset viewportPoint, [Matrix4? matrix]) {
    final m = (matrix ?? _xfm.value).clone()..invert();
    final v = m.transform3(Vector3(viewportPoint.dx, viewportPoint.dy, 0));
    return Offset(v.x, v.y);
  }

  Offset _clampToImage(Offset p) {
    final sz = _imageSize!;
    return Offset(p.dx.clamp(0.0, sz.width), p.dy.clamp(0.0, sz.height));
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

  double _dist(Offset a, Offset b) => (a - b).distance;

  // -------- Imperial parsing / formatting --------
  double? _parseImperialToInches(String raw) {
    String s = raw.trim().toLowerCase().replaceAll(',', ' ');
    if (s.isEmpty) return null;
    s = s
        .replaceAll('feet', 'ft')
        .replaceAll('foot', 'ft')
        .replaceAll('inches', 'in')
        .replaceAll('inch', 'in')
        .replaceAll('”', 'in')
        .replaceAll('″', 'in')
        .replaceAll('"', 'in')
        .replaceAll('’', "'")
        .replaceAll('′', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // ft-in e.g. 5' 7.5", 5ft 7.5in, 5-7.5
    final ftIn = RegExp(
      "^\\s*(\\d+(?:\\.\\d+)?)\\s*(?:ft|'|-)\\s*(\\d+(?:\\.\\d+)?)\\s*(?:in)?\\s*\$",
      caseSensitive: false,
    );
    final m1 = ftIn.firstMatch(s);
    if (m1 != null) {
      final ft = double.tryParse(m1.group(1)!);
      final inch = double.tryParse(m1.group(2)!);
      if (ft != null && inch != null) return ft * 12 + inch;
    }

    // feet only (decimal ok): "4.5 ft" or "4.5" (assume feet)
    final justFt = RegExp("^\\s*(\\d+(?:\\.\\d+)?)\\s*(?:ft)?\\s*\$");
    final m2 = justFt.firstMatch(s);
    if (m2 != null && s.contains('ft')) {
      final ft = double.tryParse(m2.group(1)!);
      if (ft != null) return ft * 12;
    }
    if (m2 != null && !s.contains('in') && !s.contains("'")) {
      final ft = double.tryParse(m2.group(1)!);
      if (ft != null) return ft * 12;
    }

    // inches with simple fraction: "21 1/2 in"
    final fracIn = RegExp("^\\s*(\\d+)\\s+(\\d+)\\s*/\\s*(\\d+)\\s*in\\s*\$");
    final m3f = fracIn.firstMatch(s);
    if (m3f != null) {
      final whole = double.tryParse(m3f.group(1)!);
      final num = double.tryParse(m3f.group(2)!);
      final den = double.tryParse(m3f.group(3)!);
      if (whole != null && num != null && den != null && den != 0) {
        return whole + (num / den);
      }
    }

    // inches only
    final justIn = RegExp("^\\s*(\\d+(?:\\.\\d+)?)\\s*in\\s*\$");
    final m3 = justIn.firstMatch(s);
    if (m3 != null) {
      final inch = double.tryParse(m3.group(1)!);
      if (inch != null) return inch;
    }

    return null;
  }

  String _formatFeetInches(double inches, {bool withParenInches = true}) {
    if (inches.isNaN || inches.isInfinite) return '--';
    final sixteenths = (inches * 16).round();
    final wholeInches = sixteenths ~/ 16;
    final frac16 = sixteenths % 16;

    final feet = wholeInches ~/ 12;
    final inchesPart = wholeInches % 12;

    int num = frac16, den = 16;
    int gcd(int a, int b) => b == 0 ? a.abs() : gcd(b, a % b);
    if (num != 0) {
      final g = gcd(num, den);
      num ~/= g; den ~/= g;
    }

    final main = (num == 0)
        ? "$feet′ $inchesPart″"
        : "$feet′ $inchesPart ${num}/${den}″";
    return withParenInches ? "$main (${inches.toStringAsFixed(2)} in)" : main;
  }

  // -------- Homography (DLT) for plane calibration --------
  List<double> _computeHomography(List<Offset> ptsImg, double W, double H) {
    final A = List.generate(8, (_) => List<double>.filled(8, 0));
    final b = List<double>.filled(8, 0.0);

    final ptsReal = <Offset>[
      const Offset(0, 0),
      Offset(W, 0),
      Offset(W, H),
      Offset(0, H),
    ];

    for (int i = 0; i < 4; i++) {
      final x = ptsImg[i].dx, y = ptsImg[i].dy;
      final X = ptsReal[i].dx, Y = ptsReal[i].dy;

      // X row
      A[2 * i][0] = -x;  A[2 * i][1] = -y;  A[2 * i][2] = -1;
      A[2 * i][3] =  0;  A[2 * i][4] =  0;  A[2 * i][5] =  0;
      A[2 * i][6] =  x * X; A[2 * i][7] = y * X;
      b[2 * i]     = -X;

      // Y row
      A[2 * i + 1][0] =  0;  A[2 * i + 1][1] =  0;  A[2 * i + 1][2] =  0;
      A[2 * i + 1][3] = -x;  A[2 * i + 1][4] = -y;  A[2 * i + 1][5] = -1;
      A[2 * i + 1][6] =  x * Y; A[2 * i + 1][7] = y * Y;
      b[2 * i + 1]     = -Y;
    }

    final h = _solveLinear8x8(A, b); // [h11..h32], h33 = 1
    return <double>[
      h[0], h[1], h[2],
      h[3], h[4], h[5],
      h[6], h[7], 1.0,
    ];
  }

  List<double> _solveLinear8x8(List<List<double>> A, List<double> b) {
    for (int i = 0; i < 8; i++) {
      A[i] = [...A[i], b[i]];
    }
    for (int col = 0; col < 8; col++) {
      int pivot = col;
      double best = A[pivot][col].abs();
      for (int r = col + 1; r < 8; r++) {
        final v = A[r][col].abs();
        if (v > best) { best = v; pivot = r; }
      }
      if (best < 1e-12) throw Exception('Singular matrix in homography.');
      if (pivot != col) {
        final tmp = A[col]; A[col] = A[pivot]; A[pivot] = tmp;
      }
      final piv = A[col][col];
      for (int c = col; c <= 8; c++) A[col][c] /= piv;
      for (int r = 0; r < 8; r++) {
        if (r == col) continue;
        final f = A[r][col];
        if (f == 0) continue;
        for (int c = col; c <= 8; c++) A[r][c] -= f * A[col][c];
      }
    }
    return List<double>.generate(8, (i) => A[i][8]);
  }

  Offset _applyH(List<double> H, Offset p) {
    final x = p.dx, y = p.dy;
    final X = H[0] * x + H[1] * y + H[2];
    final Y = H[3] * x + H[4] * y + H[5];
    final W = H[6] * x + H[7] * y + 1.0;
    return Offset(X / W, Y / W);
  }

  // -------- Hit testing --------
  _Handle _hitTestScene(Offset sceneP) {
    double d(Offset? a) => a == null ? 1e9 : (sceneP - a).distance;
    final hitScene = _hitRadiusScreen / _scale.clamp(1.0, 100.0);

    _Handle best = _Handle.none;
    double bestD = hitScene;

    void check(_Handle h, Offset? p) {
      final dist = d(p);
      if (dist < bestD) { best = h; bestD = dist; }
    }

    if (_mode == MeasureMode.calibrate) {
      if (_calibKind == _CalibKind.singleScale) {
        check(_Handle.calibA, _calibA);
        check(_Handle.calibB, _calibB);
      } else {
        check(_Handle.calibA, _calibA);
        check(_Handle.calibB, _calibB);
        check(_Handle.calibC, _calibC);
        check(_Handle.calibD, _calibD);
      }
    } else {
      check(_Handle.measA, _measA);
      check(_Handle.measB, _measB);
    }
    return best;
  }

  // -------- Gestures --------
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
    if (grabbed != _Handle.none) HapticFeedback.selectionClick();
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_imageSize == null) return;
    if (d.pointerCount > _gestureMaxPointers) _gestureMaxPointers = d.pointerCount;

    if (_gMode == _GestureMode.singleEdit) {
      if (_gestureMaxPointers >= 2 || _everMultitouch) {
        _gMode = _GestureMode.pinchZoom;
        _startMatrix = _xfm.value.clone();
        _startScale = _startMatrix!.getMaxScaleOnAxis();
        _startSceneFocal = _toScene(d.localFocalPoint, _startMatrix);
        _dragging = _Handle.none;
        return;
      }

      final curViewport = d.localFocalPoint;
      if ((curViewport - _singleStartViewport).distance > _tapSlop) _singleMoved = true;
      final curScene = _clampToImage(_toScene(curViewport));

      if (_dragging != _Handle.none) {
        setState(() {
          switch (_dragging) {
            case _Handle.calibA: _calibA = curScene; break;
            case _Handle.calibB: _calibB = curScene; break;
            case _Handle.calibC: _calibC = curScene; break;
            case _Handle.calibD: _calibD = curScene; break;
            case _Handle.measA:  _measA  = curScene; break;
            case _Handle.measB:  _measB  = curScene; break;
            case _Handle.none: break;
          }
        });
      } else if (_singleMoved) {
        setState(() {
          if (_mode == MeasureMode.calibrate) {
            if (_calibKind == _CalibKind.singleScale) {
              if (_calibA == null || (_calibA != null && _calibB != null)) {
                _calibA = _clampToImage(_singleStartScene); _calibB = curScene; _dragging = _Handle.calibB;
              } else { _calibB = curScene; _dragging = _Handle.calibB; }
            } else {
              if (_calibA == null) { _calibA = _clampToImage(_singleStartScene); _calibB = curScene; _dragging = _Handle.calibB; }
              else if (_calibB == null) { _calibB = curScene; _dragging = _Handle.calibB; }
              else if (_calibC == null) { _calibC = curScene; _dragging = _Handle.calibC; }
              else { _calibD = curScene; _dragging = _Handle.calibD; }
            }
          } else {
            if (_measA == null || (_measA != null && _measB != null)) {
              _measA = _clampToImage(_singleStartScene); _measB = curScene; _dragging = _Handle.measB;
            } else { _measB = curScene; _dragging = _Handle.measB; }
          }
        });
      }
      return;
    }

    if (_gMode == _GestureMode.pinchZoom) {
      final desiredScale = (_startScale * d.scale).clamp(_minScale, _maxScale);
      final focalV = d.localFocalPoint;
      Matrix4 next = Matrix4.identity()
        ..translate(focalV.dx, focalV.dy) // <-- fixed typo here
        ..scale(desiredScale)
        ..translate(-_startSceneFocal.dx, -_startSceneFocal.dy);
      _xfm.value = next;
      setState(() {});
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_imageSize == null) return;

    if (_gMode == _GestureMode.pinchZoom) {
      setState(() => _xfm.value = _clampMatrix(_xfm.value, _viewportSize, _imageSize!));
      _gMode = _GestureMode.none;
      _startMatrix = null;
      _gestureMaxPointers = 0;
      return;
    }

    if (_gMode == _GestureMode.singleEdit) {
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
          setState(() => _dragging = grabbed);
        } else {
          setState(() {
            if (_mode == MeasureMode.calibrate) {
              if (_calibKind == _CalibKind.singleScale) {
                if (_calibA == null) _calibA = sceneP;
                else if (_calibB == null) _calibB = sceneP;
                else {
                  final dA = (_calibA! - sceneP).distance, dB = (_calibB! - sceneP).distance;
                  if (dA <= dB) _calibA = sceneP; else _calibB = sceneP;
                }
              } else {
                if (_calibA == null) _calibA = sceneP;
                else if (_calibB == null) _calibB = sceneP;
                else if (_calibC == null) _calibC = sceneP;
                else if (_calibD == null) _calibD = sceneP;
                else {
                  final ds = <double>[
                    (_calibA! - sceneP).distance,
                    (_calibB! - sceneP).distance,
                    (_calibC! - sceneP).distance,
                    (_calibD! - sceneP).distance,
                  ];
                  final i = ds.indexOf(ds.reduce((a, b) => a < b ? a : b));
                  switch (i) {
                    case 0: _calibA = sceneP; break;
                    case 1: _calibB = sceneP; break;
                    case 2: _calibC = sceneP; break;
                    case 3: _calibD = sceneP; break;
                  }
                }
              }
            } else {
              if (_measA == null) _measA = sceneP;
              else if (_measB == null) _measB = sceneP;
              else {
                final dA = (_measA! - sceneP).distance, dB = (_measB! - sceneP).distance;
                if (dA <= dB) _measA = sceneP; else _measB = sceneP;
              }
            }
          });
        }
      }
      _gMode = _GestureMode.none;
      _dragging = _Handle.none;
      _gestureMaxPointers = 0;
    }
  }

  // -------- Double-tap zoom --------
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
    setState(() => _xfm.value = _clampMatrix(Matrix4.identity(), _viewportSize, _imageSize!));
  }

  void _onDoubleTapDown(TapDownDetails d) {
    if (_imageSize == null) return;
    final currentScale = _scale;
    final targetScale = currentScale < 2.0 ? 2.5 : 1.0;
    final f = d.localPosition;
    final sceneAtTap = _toScene(f);
    Matrix4 m = Matrix4.identity()
      ..translate(f.dx, f.dy)
      ..scale(targetScale)
      ..translate(-sceneAtTap.dx, -sceneAtTap.dy);
    m = _clampMatrix(m, _viewportSize, _imageSize!);
    _animateTo(m);
  }

  // -------- Calc / flow --------
  void _setCalibration() {
    if (_calibKind == _CalibKind.singleScale) {
      if (!_calibrationReady2) { _snack('Place two blue calibration points.'); return; }
      final inches = _parseImperialToInches(_knownLengthCtrl.text);
      if (inches == null || inches <= 0) { _snack('Enter valid length (e.g., 21.5", 21 1/2 in, 1\' 9.5").'); return; }
      final px = _dist(_calibA!, _calibB!);
      if (px <= 0) { _snack('Calibration points overlap.'); return; }

      setState(() {
        _pxPerInch = px / inches;
        _H = null;
        _diagCalib = 'Single scale';
        _knownInchesCache = inches;
        _calibPxCache = px;

        _mode = MeasureMode.measure;
        _calibA = _calibB = null; _calibC = _calibD = null;
        _measA = _measB = null;
        _measuredInches = null; _measPxCache = null;
      });
      _snack('Calibrated single-scale: ${_pxPerInch!.toStringAsFixed(3)} px/in.');
    } else {
      if (!_calibrationReady4) { _snack('Place 4 blue points around a known rectangle (TL, TR, BR, BL).'); return; }
      final wIn = _parseImperialToInches(_knownWidthCtrl.text);
      final hIn = _parseImperialToInches(_knownHeightCtrl.text);
      if (wIn == null || hIn == null || wIn <= 0 || hIn <= 0) { _snack('Enter valid width & height (e.g., 4 ft, 2 ft).'); return; }

      final H = _computeHomography([_calibA!, _calibB!, _calibC!, _calibD!], wIn, hIn);

      setState(() {
        _H = H;
        _pxPerInch = null;
        _diagCalib = 'Plane (homography)';
        _knownInchesCache = null;
        _calibPxCache = null;

        _mode = MeasureMode.measure;
        _calibA = _calibB = _calibC = _calibD = null;
        _measA = _measB = null;
        _measuredInches = null; _measPxCache = null;
      });
      _snack('Plane calibrated. Measurements now account for perspective.');
    }
  }

  void _compute() {
    if (!_measurementReady) { _snack('Place two green measurement points.'); return; }

    double inches;
    if (_H != null) {
      final a = _applyH(_H!, _measA!);
      final b = _applyH(_H!, _measB!);
      inches = (a - b).distance;
      setState(() { _measuredInches = inches; _measPxCache = _dist(_measA!, _measB!); });
    } else if (_pxPerInch != null) {
      final px = _dist(_measA!, _measB!);
      inches = px / _pxPerInch!;
      setState(() { _measuredInches = inches; _measPxCache = px; });
    } else {
      _snack('Calibrate first.'); return;
    }

    _snack('Depth = ${_formatFeetInches(inches)}');
  }

  void _finish() {
    if (_measuredInches == null || _measuredInches! <= 0) { _snack('No depth computed yet.'); return; }
    Navigator.of(context).pop<double>(_measuredInches!);
  }

  void _resetAll() {
    setState(() {
      _calibKind = _CalibKind.singleScale;
      _calibA = _calibB = _calibC = _calibD = null;
      _measA = _measB = null;
      _pxPerInch = null; _H = null; _measuredInches = null;
      _knownInchesCache = null; _calibPxCache = null; _measPxCache = null;
      _diagCalib = 'none';
      _mode = MeasureMode.calibrate;
      _knownLengthCtrl.text = '21.5 in';
      _knownWidthCtrl.text = '4 ft';
      _knownHeightCtrl.text = '2 ft';
      _dragging = _Handle.none;
      _xfm.value = Matrix4.identity();
      _activePointers = 0; _everMultitouch = false;
    });
    _snack('Reset. Choose calibration type and set points.');
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // -------- UI --------
  @override
  Widget build(BuildContext context) {
    final imgW = _imageSize?.width ?? 400;
    final imgH = _imageSize?.height ?? 300;

    // Live label while dragging/placing measurement
    String? liveLabel;
    if (_measA != null && _measB != null) {
      double? inches;
      if (_H != null) {
        final a = _applyH(_H!, _measA!);
        final b = _applyH(_H!, _measB!);
        inches = (a - b).distance;
      } else if (_pxPerInch != null) {
        inches = _dist(_measA!, _measB!) / _pxPerInch!;
      }
      if (inches != null) liveLabel = _formatFeetInches(inches, withParenInches: false);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Measure Depth'),
        actions: [IconButton(onPressed: _resetAll, tooltip: 'Reset', icon: const Icon(Icons.refresh))],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Approx: reserve space for controls/readouts
          _viewportSize = Size(constraints.maxWidth, constraints.maxHeight - 240);
          final pxPer = _pxPerInch == null ? (_H != null ? 'plane' : '--') : _pxPerInch!.toStringAsFixed(3);
          final depthText = _measuredInches == null ? '--' : _formatFeetInches(_measuredInches!, withParenInches: true);

          return Column(
            children: [
              // IMAGE + OVERLAY
              Expanded(
                child: Center(
                  child: ClipRect(
                    child: SizedBox(
                      width: imgW, height: imgH,
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
                          // Pointer + gesture + overlay
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
                                        calibKind: _calibKind,
                                        calibA: _calibA, calibB: _calibB,
                                        calibC: _calibC, calibD: _calibD,
                                        measA: _measA, measB: _measB,
                                        dotRadiusScene: _dotRadiusBase / _scale,
                                        haloRadiusScene: _haloRadiusBase / _scale,
                                        strokeScene: (_strokeBase / _scale).clamp(1.0, 999),
                                        midTickRScene: (_midTickBase / _scale).clamp(1.0, 999),
                                        liveLabel: liveLabel,
                                        sceneFontPx: (13.0 / _scale).clamp(10.0, 18.0),
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
                    _Box(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<_CalibKind>(
                          value: _calibKind,
                          onChanged: (k) => setState(() => _calibKind = k!),
                          items: const [
                            DropdownMenuItem(value: _CalibKind.singleScale, child: Text('Single scale (2 pts)')),
                            DropdownMenuItem(value: _CalibKind.plane, child: Text('Plane (4 pts)')),
                          ],
                        ),
                      ),
                    ),
                    if (_mode == MeasureMode.calibrate && _calibKind == _CalibKind.singleScale) ...[
                      ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
                        child: TextField(
                          controller: _knownLengthCtrl,
                          keyboardType: TextInputType.text,
                          decoration: const InputDecoration(
                            labelText: 'Known length (ft/in)',
                            hintText: 'e.g., 21.5", 21 1/2 in, 1\' 9.5"',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ),
                    ],
                    if (_mode == MeasureMode.calibrate && _calibKind == _CalibKind.plane) ...[
                      ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 180, maxWidth: 240),
                        child: TextField(
                          controller: _knownWidthCtrl,
                          keyboardType: TextInputType.text,
                          decoration: const InputDecoration(
                            labelText: 'Rect width (ft/in)',
                            hintText: 'e.g., 4 ft',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 180, maxWidth: 240),
                        child: TextField(
                          controller: _knownHeightCtrl,
                          keyboardType: TextInputType.text,
                          decoration: const InputDecoration(
                            labelText: 'Rect height (ft/in)',
                            hintText: 'e.g., 2 ft',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ),
                    ],
                    if (_mode == MeasureMode.calibrate)
                      FilledButton(
                        onPressed: (_calibKind == _CalibKind.singleScale ? _calibrationReady2 : _calibrationReady4)
                            ? _setCalibration
                            : null,
                        child: const Text('Set calibration'),
                      ),
                    FilledButton.icon(
                      onPressed: _resetZoom,
                      icon: const Icon(Icons.zoom_out_map),
                      label: const Text('Reset zoom'),
                    ),
                  ],
                ),
              ),

              // READOUTS + DIAGNOSTICS
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: _statTile('Calibration', _diagCalib, Icons.tune)),
                        const SizedBox(width: 8),
                        Expanded(child: _statTile('Scale / Mode', pxPer, Icons.straighten)),
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
                    _diagCard(),
                    const SizedBox(height: 8),
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
          );
        },
      ),
    );
  }

  Widget _diagCard() {
    final pxPerIn = _pxPerInch == null ? (_H != null ? '(plane)' : '--') : _pxPerInch!.toStringAsFixed(6);
    final knownIn = _knownInchesCache == null ? '--' : _knownInchesCache!.toStringAsFixed(4);
    final calibPx = _calibPxCache == null ? '--' : _calibPxCache!.toStringAsFixed(3);
    final measPx  = _measPxCache  == null ? '--' : _measPxCache!.toStringAsFixed(3);
    final measIn  = _measuredInches == null ? '--' : _measuredInches!.toStringAsFixed(3);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(10),
      ),
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodySmall!,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Diagnostics', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Calibration kind:  $_diagCalib'),
            Text('Known length (in): $knownIn'),
            Text('Calibration px:    $calibPx'),
            Text('Pixels / inch:     $pxPerIn'),
            Text('Measurement px:    $measPx'),
            Text('Measurement (in):  $measIn'),
          ],
        ),
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
  final _CalibKind calibKind;
  final Offset? calibA, calibB, calibC, calibD, measA, measB;
  final double dotRadiusScene, haloRadiusScene, strokeScene, midTickRScene;
  final String? liveLabel;
  final double sceneFontPx;

  _OverlayPainter({
    required this.calibKind,
    required this.calibA,
    required this.calibB,
    required this.calibC,
    required this.calibD,
    required this.measA,
    required this.measB,
    required this.dotRadiusScene,
    required this.haloRadiusScene,
    required this.strokeScene,
    required this.midTickRScene,
    required this.liveLabel,
    required this.sceneFontPx,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final whiteHalo = Paint()..color = Colors.white..style = PaintingStyle.fill..isAntiAlias = true;
    final blue  = Paint()..color = const Color(0xFF1565C0)..style = PaintingStyle.fill..isAntiAlias = true;
    final blueLine = Paint()..color = const Color(0xFF1565C0)..strokeWidth = strokeScene..strokeCap = StrokeCap.round..style = PaintingStyle.stroke..isAntiAlias = true;

    final green = Paint()..color = const Color(0xFF2E7D32)..style = PaintingStyle.fill..isAntiAlias = true;
    final greenLine = Paint()..color = const Color(0xFF2E7D32)..strokeWidth = strokeScene..strokeCap = StrokeCap.round..style = PaintingStyle.stroke..isAntiAlias = true;

    final lineHalo = Paint()
      ..color = Colors.black.withOpacity(0.35)
      ..strokeWidth = strokeScene + 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    void point(Offset? p, Paint color) {
      if (p == null) return;
      canvas.drawCircle(p, haloRadiusScene, whiteHalo);
      canvas.drawCircle(p, dotRadiusScene, color);
    }

    void segment(Offset? a, Offset? b, Paint line) {
      if (a == null || b == null) return;
      canvas.drawLine(a, b, lineHalo);
      canvas.drawLine(a, b, line);
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      final midFill = Paint()..color = line == blueLine ? const Color(0xFF1565C0) : const Color(0xFF2E7D32)..style = PaintingStyle.fill..isAntiAlias = true;
      final midStroke = Paint()..color = Colors.white..strokeWidth = 2..style = PaintingStyle.stroke..isAntiAlias = true;
      canvas.drawCircle(mid, midTickRScene, midFill);
      canvas.drawCircle(mid, midTickRScene, midStroke);
    }

    // Calibration in blue
    point(calibA, blue); point(calibB, blue);
    segment(calibA, calibB, blueLine);
    if (calibKind == _CalibKind.plane) {
      point(calibC, blue); point(calibD, blue);
      segment(calibB, calibC, blueLine);
      segment(calibC, calibD, blueLine);
      segment(calibD, calibA, blueLine);
    }

    // Measurement in green
    point(measA, green); point(measB, green);
    segment(measA, measB, greenLine);

    // Live label near the green segment midpoint
    if (liveLabel != null && measA != null && measB != null) {
      final mid = Offset((measA!.dx + measB!.dx) / 2, (measA!.dy + measB!.dy) / 2);
      // Perpendicular offset so it doesn't overlap line
      final dir = (measB! - measA!);
      Offset n = dir == Offset.zero ? const Offset(0, -1) : Offset(-dir.dy, dir.dx);
      final len = n.distance;
      if (len != 0) n = n / len;
      final labelPos = mid + n * 12.0;

      final tp = TextPainter(
        text: TextSpan(
          text: liveLabel!,
          style: TextStyle(
            color: Colors.white,
            fontSize: sceneFontPx,
            fontWeight: FontWeight.w600,
            shadows: const [Shadow(blurRadius: 2, color: Colors.black54, offset: Offset(0, 1))],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final padding = 6.0;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          labelPos.dx - tp.width / 2 - padding,
          labelPos.dy - tp.height / 2 - padding,
          tp.width + padding * 2,
          tp.height + padding * 2,
        ),
        const Radius.circular(6),
      );

      final bg = Paint()..color = Colors.black.withOpacity(0.55);
      canvas.drawRRect(r, bg);
      tp.paint(canvas, Offset(labelPos.dx - tp.width / 2, labelPos.dy - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) {
    return old.calibKind != calibKind ||
        old.calibA != calibA || old.calibB != calibB ||
        old.calibC != calibC || old.calibD != calibD ||
        old.measA != measA || old.measB != measB ||
        old.dotRadiusScene != dotRadiusScene ||
        old.haloRadiusScene != haloRadiusScene ||
        old.strokeScene != strokeScene ||
        old.midTickRScene != midTickRScene ||
        old.liveLabel != liveLabel ||
        old.sceneFontPx != sceneFontPx;
  }
}
