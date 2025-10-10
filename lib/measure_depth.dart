import 'dart:math' as math;
import 'package:flutter/material.dart';

enum MeasureMode { calibrate, measure }
enum Unit { feet, meters }

class MeasureDepthScreen extends StatefulWidget {
  const MeasureDepthScreen({
    super.key,
    required this.imageProvider,
    this.initialMode = MeasureMode.calibrate,
    this.initialUnit = Unit.feet,
    this.initialManualLength,
    this.title = 'Measure Depth',
  });

  final ImageProvider imageProvider;
  final MeasureMode initialMode;
  final Unit initialUnit;
  final double? initialManualLength;
  final String title;

  @override
  State<MeasureDepthScreen> createState() => _MeasureDepthScreenState();
}

class _MeasureDepthScreenState extends State<MeasureDepthScreen>
    with TickerProviderStateMixin {
  final TransformationController _controller = TransformationController();
  late AnimationController _zoomAnimCtrl;

  Size? _imageSize; // in image pixels
  bool _isScaling = false; // true when pinch/pan gesture is active
  bool _draggingPoint = false;

  // Points stored in IMAGE PIXEL SPACE (so they stay glued during zoom/pan)
  Offset? _calibA;
  Offset? _calibB;
  Offset? _measA;
  Offset? _measB;

  // UI state
  MeasureMode _mode = MeasureMode.calibrate;
  Unit _unit = Unit.feet;
  final TextEditingController _manualLenCtrl = TextEditingController();

  // Calibration result
  double? _pixelsPerUnit;

  // Tap/drag config
  static const double _hitRadius = 22; // in screen px for hit-testing
  static const double _pointRadius = 6; // visual radius on screen (polished smaller)

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _unit = widget.initialUnit;
    if (widget.initialManualLength != null) {
      _manualLenCtrl.text = widget.initialManualLength!.toString();
    }
    _zoomAnimCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _resolveImageSize();
  }

  @override
  void dispose() {
    _zoomAnimCtrl.dispose();
    _manualLenCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _resolveImageSize() {
    final stream = widget.imageProvider.resolve(const ImageConfiguration());
    ImageStreamListener? listener;
    listener = ImageStreamListener((ImageInfo info, _) {
      _imageSize = Size(
        info.image.width.toDouble(),
        info.image.height.toDouble(),
      );
      setState(() {});
      stream.removeListener(listener!);
    });
    stream.addListener(listener);
  }

  // ---------- Coordinate transforms ----------

  /// Child space == image pixel space because we size the child to _imageSize exactly.
  /// _controller.value maps child(image) -> viewport(screen). To go screen->image, invert.
  Offset _screenToImage(Offset screenPos, RenderBox box) {
    final Matrix4 m = _controller.value.clone();
    final Matrix4 inv = Matrix4.inverted(m);
    // Convert screen to local (viewport) first
    final Offset local = box.globalToLocal(screenPos);
    final Vector3 v = Vector3(local.dx, local.dy, 0);
    final Vector3 r = inv.transform3(v);
    return Offset(r.x, r.y);
  }

  Offset _imageToScreen(Offset imagePos) {
    final Vector3 v = Vector3(imagePos.dx, imagePos.dy, 0);
    final Vector3 r = _controller.value.transform3(v);
    return Offset(r.x, r.y);
  }

  // ---------- Point helpers ----------

  Offset? _nearestPointOnScreen(Offset screenTap) {
    final candidates = <Offset>[];
    if (_mode == MeasureMode.calibrate) {
      if (_calibA != null) candidates.add(_imageToScreen(_calibA!));
      if (_calibB != null) candidates.add(_imageToScreen(_calibB!));
    } else {
      if (_measA != null) candidates.add(_imageToScreen(_measA!));
      if (_measB != null) candidates.add(_imageToScreen(_measB!));
    }
    if (candidates.isEmpty) return null;

    Offset best = candidates.first;
    double bestD2 = (best - screenTap).distanceSquared;
    for (final c in candidates.skip(1)) {
      final d2 = (c - screenTap).distanceSquared;
      if (d2 < bestD2) {
        best = c;
        bestD2 = d2;
      }
    }
    if (math.sqrt(bestD2) <= _hitRadius) return best;
    return null;
  }

  /// Returns a reference to the actual image-space point to mutate (by identity).
  Offset? _getPointByScreen(Offset screenPt) {
    if (_mode == MeasureMode.calibrate) {
      if (_calibA != null && (_imageToScreen(_calibA!) - screenPt).distance <= _hitRadius) {
        return _calibA;
      }
      if (_calibB != null && (_imageToScreen(_calibB!) - screenPt).distance <= _hitRadius) {
        return _calibB;
      }
    } else {
      if (_measA != null && (_imageToScreen(_measA!) - screenPt).distance <= _hitRadius) {
        return _measA;
      }
      if (_measB != null && (_imageToScreen(_measB!) - screenPt).distance <= _hitRadius) {
        return _measB;
      }
    }
    return null;
  }

  void _setPointForMode(int index, Offset imgPos) {
    if (_mode == MeasureMode.calibrate) {
      if (index == 0) {
        _calibA = imgPos;
      } else {
        _calibB = imgPos;
      }
    } else {
      if (index == 0) {
        _measA = imgPos;
      } else {
        _measB = imgPos;
      }
    }
  }

  List<Offset?> _pointsForMode() {
    return _mode == MeasureMode.calibrate ? [_calibA, _calibB] : [_measA, _measB];
  }

  // ---------- Gesture handling ----------

  void _onDoubleTapDown(TapDownDetails d, RenderBox box) {
    // Center zoom on the double-tap location
    final Offset tapLocal = box.globalToLocal(d.globalPosition);
    final double currentScale = _currentScale();
    final double targetScale = (currentScale <= 1.01) ? 2.5 : 1.0;

    final Matrix4 begin = _controller.value.clone();
    final Matrix4 end = _zoomToPoint(begin, tapLocal, targetScale);

    Animation<Matrix4> tween = Matrix4Tween(begin: begin, end: end).animate(_zoomAnimCtrl);
    _zoomAnimCtrl.removeListener(_applyAnimatedMatrix);
    _zoomAnimCtrl.addListener(() {
      _controller.value = tween.value;
    });
    _zoomAnimCtrl.forward(from: 0);
  }

  Matrix4 _zoomToPoint(Matrix4 base, Offset focalOnViewport, double scale) {
    // Compute current child-space focal point
    final Matrix4 inv = Matrix4.inverted(base);
    final Vector3 focalLocal = inv.transform3(Vector3(focalOnViewport.dx, focalOnViewport.dy, 0));

    final Matrix4 m = Matrix4.identity();
    m.translate(focalOnViewport.dx, focalOnViewport.dy);
    final double currentScale = _currentScale();
    final double delta = scale / currentScale;
    m.scale(delta, delta);
    m.translate(-focalOnViewport.dx, -focalOnViewport.dy);

    // Apply around the focal point in child-space to keep that point under finger
    final Vector3 focalAfter = m.transform3(Vector3(focalOnViewport.dx, focalOnViewport.dy, 0));
    final Offset focalAfterLocal = Offset(focalAfter.x, focalAfter.y);
    final Vector3 focalLocalAfter = Matrix4.inverted(base.multiplied(m))
        .transform3(Vector3(focalAfterLocal.dx, focalAfterLocal.dy, 0));

    // Adjust so that the same child pixel stays under the same viewport pixel
    final Offset childShift = Offset(focalLocal.dx - focalLocalAfter.x, focalLocal.dy - focalLocalAfter.y);
    final Matrix4 adjust = Matrix4.identity()..translate(childShift.dx, childShift.dy);
    return base.multiplied(m).multiplied(adjust);
  }

  double _currentScale() {
    final m = _controller.value;
    // sqrt of upper-left 2x2 determinant approximates uniform scale
    final sx = m.row0[0];
    final sy = m.row1[1];
    return (sx + sy) / 2.0;
  }

  void _applyAnimatedMatrix() {
    // no-op; listener body set inline to write controller.value
  }

  // ---------- Actions ----------

  double? _distanceImage(Offset? a, Offset? b) {
    if (a == null || b == null) return null;
    return (a - b).distance;
    }

  void _setCalibration() {
    final px = _distanceImage(_calibA, _calibB);
    final manual = double.tryParse(_manualLenCtrl.text.trim());
    if (px == null || manual == null || manual <= 0) {
      _showSnack('Need two calibration points and a valid length.');
      return;
    }
    _pixelsPerUnit = px / manual; // px per selected unit
    _showSnack('Calibration set: ${_pixelsPerUnit!.toStringAsFixed(2)} px/${_unitLabel(_unit)}');
    setState(() {});
  }

  double? _computeDepth() {
    if (_pixelsPerUnit == null) {
      _showSnack('Set calibration first.');
      return null;
    }
    final px = _distanceImage(_measA, _measB);
    if (px == null) {
      _showSnack('Place two measurement points.');
      return null;
    }
    return px / _pixelsPerUnit!;
  }

  void _useDepth() {
    final d = _computeDepth();
    if (d == null) return;
    Navigator.of(context).pop(d);
  }

  String _unitLabel(Unit u) => u == Unit.feet ? 'ft' : 'm';

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- Build ----------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _imageSize == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Viewer area
                Expanded(
                  child: ClipRect( // Prevent overlay from crossing into bottom panel
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // We render the child at EXACTLY image pixel size, centered.
                        final viewer = Center(
                          child: SizedBox(
                            width: _imageSize!.width,
                            height: _imageSize!.height,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                // Interactive viewer wraps the image+overlay
                                _buildInteractiveLayer(),
                                // Overlay painter draws points/lines in screen space
                                IgnorePointer(ignoring: true, child: _OverlayPainterWidget(
                                  controller: _controller,
                                  calibA: _calibA,
                                  calibB: _calibB,
                                  measA: _measA,
                                  measB: _measB,
                                  pointRadius: _pointRadius,
                                  activeMode: _mode,
                                )),
                              ],
                            ),
                          ),
                        );
                        return Container(color: Colors.black12, child: viewer);
                      },
                    ),
                  ),
                ),

                // Control panel
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            // Mode
                            Expanded(
                              child: _Labeled(
                                label: 'Mode',
                                child: DropdownButtonFormField<MeasureMode>(
                                  value: _mode,
                                  onChanged: (v) => setState(() => _mode = v!),
                                  items: const [
                                    DropdownMenuItem(value: MeasureMode.calibrate, child: Text('Calibrate')),
                                    DropdownMenuItem(value: MeasureMode.measure, child: Text('Measure')),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Unit
                            Expanded(
                              child: _Labeled(
                                label: 'Units',
                                child: DropdownButtonFormField<Unit>(
                                  value: _unit,
                                  onChanged: (v) => setState(() => _unit = v!),
                                  items: const [
                                    DropdownMenuItem(value: Unit.feet, child: Text('Feet')),
                                    DropdownMenuItem(value: Unit.meters, child: Text('Meters')),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Manual length
                            Expanded(
                              child: _Labeled(
                                label: 'Calibration length',
                                child: TextFormField(
                                  controller: _manualLenCtrl,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: InputDecoration(
                                    hintText: 'e.g. 4.0',
                                    suffixText: _unitLabel(_unit),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: _setCalibration,
                                child: const Text('Set calibration'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () {
                                  final d = _computeDepth();
                                  if (d != null) {
                                    _showSnack('Depth: ${d.toStringAsFixed(3)} ${_unitLabel(_unit)}');
                                  }
                                },
                                child: const Text('Compute depth'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _useDepth,
                                child: const Text('Use depth'),
                              ),
                            ),
                          ],
                        ),
                        if (_pixelsPerUnit != null) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              'Calibrated: ${_pixelsPerUnit!.toStringAsFixed(2)} px/${_unitLabel(_unit)}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildInteractiveLayer() {
    return LayoutBuilder(builder: (context, _) {
      return Listener(
        onPointerDown: (_) {}, // needed to ensure GestureDetector receives events above InteractiveViewer
        child: InteractiveViewer(
          transformationController: _controller,
          minScale: 1.0,
          maxScale: 6.0,
          panEnabled: true,
          scaleEnabled: true,
          onInteractionStart: (details) {
            _isScaling = details.pointerCount > 1;
            _draggingPoint = false;
          },
          onInteractionUpdate: (details) {
            // If fingers increase beyond one, treat as scaling to suppress placement
            if (details.pointerCount > 1) _isScaling = true;
          },
          onInteractionEnd: (details) {
            _isScaling = false;
            _draggingPoint = false;
          },
          child: _buildGestureLayer(),
        ),
      );
    });
  }

  Widget _buildGestureLayer() {
    return LayoutBuilder(builder: (context, _) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: (d) {
          final box = context.findRenderObject() as RenderBox;
          _onDoubleTapDown(d, box);
        },
        onDoubleTap: () {},

        onPanStart: (details) {
          if (_isScaling) return; // suppress during pinch/pan
          final box = context.findRenderObject() as RenderBox;
          final tap = details.globalPosition;
          final nearest = _nearestPointOnScreen(tap);
          if (nearest != null) {
            // Start dragging an existing point
            _draggingPoint = true;
          } else {
            // Place or replace the first missing point for current mode
            if (_imageSize == null) return;
            final img = _screenToImage(tap, box);
            final clamped = _clampToImage(img);
            final pts = _pointsForMode();
            if (pts[0] == null) {
              _setPointForMode(0, clamped);
            } else if (pts[1] == null) {
              _setPointForMode(1, clamped);
            } else {
              // Replace the farther one from the tap for convenience
              final d0 = (_imageToScreen(pts[0]!) - tap).distance;
              final d1 = (_imageToScreen(pts[1]!) - tap).distance;
              _setPointForMode(d0 > d1 ? 0 : 1, clamped);
            }
            setState(() {});
          }
        },
        onPanUpdate: (details) {
          if (_isScaling) return;
          if (!_draggingPoint) {
            // Start drag if finger moved on a point
            final box = context.findRenderObject() as RenderBox;
            final screenNow = details.globalPosition;
            final hit = _getPointByScreen(screenNow);
            if (hit != null) _draggingPoint = true;
          }
          if (_draggingPoint) {
            final box = context.findRenderObject() as RenderBox;
            final img = _screenToImage(details.globalPosition, box);
            final clamped = _clampToImage(img);

            // Move whichever point is under finger
            if (_mode == MeasureMode.calibrate) {
              if (_calibA != null &&
                  (_imageToScreen(_calibA!) - details.globalPosition).distance <= _hitRadius) {
                _calibA = clamped;
              } else if (_calibB != null &&
                  (_imageToScreen(_calibB!) - details.globalPosition).distance <= _hitRadius) {
                _calibB = clamped;
              }
            } else {
              if (_measA != null &&
                  (_imageToScreen(_measA!) - details.globalPosition).distance <= _hitRadius) {
                _measA = clamped;
              } else if (_measB != null &&
                  (_imageToScreen(_measB!) - details.globalPosition).distance <= _hitRadius) {
                _measB = clamped;
              }
            }
            setState(() {});
          }
        },
        onPanEnd: (_) {
          _draggingPoint = false;
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image(
              image: widget.imageProvider,
              filterQuality: FilterQuality.high,
              isAntiAlias: true,
              // No fit: child is sized to image pixels by parent SizedBox
            ),
            // The CustomPainter overlay is placed in the outer Stack via _OverlayPainterWidget.
            // We keep this layer to ensure the GestureDetector sits above the image.
          ],
        ),
      );
    });
  }

  Offset _clampToImage(Offset p) {
    return Offset(
      p.dx.clamp(0.0, _imageSize!.width),
      p.dy.clamp(0.0, _imageSize!.height),
    );
  }
}

class _OverlayPainterWidget extends StatelessWidget {
  const _OverlayPainterWidget({
    required this.controller,
    required this.calibA,
    required this.calibB,
    required this.measA,
    required this.measB,
    required this.pointRadius,
    required this.activeMode,
  });

  final TransformationController controller;
  final Offset? calibA;
  final Offset? calibB;
  final Offset? measA;
  final Offset? measB;
  final double pointRadius;
  final MeasureMode activeMode;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _OverlayPainter(
        controller: controller,
        calibA: calibA,
        calibB: calibB,
        measA: measA,
        measB: measB,
        pointRadius: pointRadius,
        activeMode: activeMode,
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.controller,
    required this.calibA,
    required this.calibB,
    required this.measA,
    required this.measB,
    required this.pointRadius,
    required this.activeMode,
  });

  final TransformationController controller;
  final Offset? calibA;
  final Offset? calibB;
  final Offset? measA;
  final Offset? measB;
  final double pointRadius;
  final MeasureMode activeMode;

  Offset _toScreen(Offset? img) {
    if (img == null) return Offset.zero;
    final v = Vector3(img.dx, img.dy, 0);
    final r = controller.value.transform3(v);
    return Offset(r.x, r.y);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paintLineCal = Paint()
      ..color = Colors.orangeAccent
      ..strokeWidth = 2.0;

    final paintLineMea = Paint()
      ..color = Colors.lightBlueAccent
      ..strokeWidth = 2.0;

    final paintPointActive = Paint()..color = Colors.redAccent;
    final paintPointIdle = Paint()..color = Colors.white;
    final paintPointStroke = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Draw calibration
    final aC = _toScreen(calibA);
    final bC = _toScreen(calibB);
    if (calibA != null && calibB != null) {
      canvas.drawLine(aC, bC, paintLineCal);
    }
    if (calibA != null) {
      _drawPoint(canvas, aC, activeMode == MeasureMode.calibrate ? paintPointActive : paintPointIdle);
    }
    if (calibB != null) {
      _drawPoint(canvas, bC, activeMode == MeasureMode.calibrate ? paintPointActive : paintPointIdle);
    }

    // Draw measurement
    final aM = _toScreen(measA);
    final bM = _toScreen(measB);
    if (measA != null && measB != null) {
      canvas.drawLine(aM, bM, paintLineMea);
    }
    if (measA != null) {
      _drawPoint(canvas, aM, activeMode == MeasureMode.measure ? paintPointActive : paintPointIdle);
    }
    if (measB != null) {
      _drawPoint(canvas, bM, activeMode == MeasureMode.measure ? paintPointActive : paintPointIdle);
    }

    // Point borders
    if (calibA != null) canvas.drawCircle(aC, pointRadius, paintPointStroke);
    if (calibB != null) canvas.drawCircle(bC, pointRadius, paintPointStroke);
    if (measA != null) canvas.drawCircle(aM, pointRadius, paintPointStroke);
    if (measB != null) canvas.drawCircle(bM, pointRadius, paintPointStroke);
  }

  void _drawPoint(Canvas canvas, Offset p, Paint fill) {
    canvas.drawCircle(p, pointRadius, fill);
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) {
    return oldDelegate.controller.value != controller.value ||
        oldDelegate.calibA != calibA ||
        oldDelegate.calibB != calibB ||
        oldDelegate.measA != measA ||
        oldDelegate.measB != measB ||
        oldDelegate.pointRadius != pointRadius ||
        oldDelegate.activeMode != activeMode;
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).textTheme.labelSmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: s),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

// -------- Vector3 helper (no external deps) --------
class Vector3 {
  double x, y, z;
  Vector3(this.x, this.y, this.z);
}

extension _M4 on Matrix4 {
  Vector3 transform3(Vector3 v) {
    final r = this.transform(Vector4(v.x, v.y, v.z, 1));
    return Vector3(r.x, r.y, r.z);
  }
}
