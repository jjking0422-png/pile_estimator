// measure_depth_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';

class MeasureDepthScreen extends StatefulWidget {
  const MeasureDepthScreen({
    super.key,
    required this.imageFile,
    this.initialDepthInUnits,
    this.unitsLabel = 'in', // e.g., "in", "cm", etc.
  });

  final File imageFile;
  final double? initialDepthInUnits;
  final String unitsLabel;

  @override
  State<MeasureDepthScreen> createState() => _MeasureDepthScreenState();
}

class _MeasureDepthScreenState extends State<MeasureDepthScreen> {
  /// Points are stored in *display* coordinates (the size the image is drawn on screen),
  /// so the painter and hit-testing are straightforward. If you need original
  /// image-pixel coordinates later, you can map using [_displayToImageSpace].
  Offset? p1;
  Offset? p2;

  /// While drag-creating: after first tap, user can drag to place p2.
  bool _isDragCreating = false;

  /// Editing state: which handle (if any) is being dragged.
  int? _draggingHandleIndex; // 0 for p1, 1 for p2

  /// Depth typed by the user (real-world distance between p1 and p2).
  final TextEditingController _depthCtrl = TextEditingController();

  /// Cached layout for the fitted image rect inside the available box.
  Rect _imagePaintRect = Rect.zero;

  /// Handle visual size (device pixels). Big and obvious as requested.
  static const double _handleRadius = 10.0; // visual circle radius
  static const double _touchRadius = 22.0; // larger hit target

  @override
  void initState() {
    super.initState();
    if (widget.initialDepthInUnits != null) {
      _depthCtrl.text = widget.initialDepthInUnits!.toString();
    }
  }

  @override
  void dispose() {
    _depthCtrl.dispose();
    super.dispose();
  }

  bool get _hasTwoPoints => p1 != null && p2 != null;

  double? get _pixelDistance {
    if (!_hasTwoPoints) return null;
    return (p2! - p1!).distance;
    // This is in display pixels (i.e., the size the image is painted).
  }

  /// If the user supplied a real-world depth, compute pixels-per-unit.
  double? get _pixelsPerUnit {
    final px = _pixelDistance;
    final depth = double.tryParse(_depthCtrl.text.trim());
    if (px == null || depth == null || depth == 0) return null;
    return px / depth;
  }

  void _reset() {
    setState(() {
      p1 = null;
      p2 = null;
      _isDragCreating = false;
      _draggingHandleIndex = null;
    });
  }

  // Map a global/local position to clamped inside the painted image rect
  Offset _clampToImage(Offset local) {
    final dx = local.dx.clamp(_imagePaintRect.left, _imagePaintRect.right);
    final dy = local.dy.clamp(_imagePaintRect.top, _imagePaintRect.bottom);
    return Offset(dx.toDouble(), dy.toDouble());
  }

  int? _hitTestHandle(Offset localPos) {
    if (p1 != null &&
        (localPos - p1!).distance <= _touchRadius) return 0;
    if (p2 != null &&
        (localPos - p2!).distance <= _touchRadius) return 1;
    return null;
  }

  void _onTapDown(TapDownDetails d) {
    final local = _clampToImage(d.localPosition);

    // If handle tapped, start dragging that handle (editing mode)
    final hit = _hitTestHandle(local);
    if (hit != null) {
      setState(() {
        _draggingHandleIndex = hit;
        _isDragCreating = false;
      });
      return;
    }

    // If no points yet: set p1, start drag-create mode
    if (p1 == null) {
      setState(() {
        p1 = local;
        p2 = null;
        _isDragCreating = true;
      });
      return;
    }

    // If only p1 is set: start drag-create for p2
    if (p1 != null && p2 == null) {
      setState(() {
        _isDragCreating = true;
        p2 = local;
      });
      return;
    }

    // If both exist and background tapped (not a handle), move the nearer one for convenience
    if (_hasTwoPoints) {
      final d1 = (local - p1!).distance;
      final d2 = (local - p2!).distance;
      setState(() {
        if (d1 < d2) {
          p1 = local;
          _draggingHandleIndex = 0;
        } else {
          p2 = local;
          _draggingHandleIndex = 1;
        }
        _isDragCreating = false;
      });
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final local = _clampToImage(d.localPosition);

    // Drag-creating second point after first tap
    if (_isDragCreating) {
      setState(() {
        p2 = local;
      });
      return;
    }

    // Editing an existing handle
    if (_draggingHandleIndex == 0 && p1 != null) {
      setState(() => p1 = local);
      return;
    }
    if (_draggingHandleIndex == 1 && p2 != null) {
      setState(() => p2 = local);
      return;
    }
  }

  void _onPanEnd(DragEndDetails d) {
    setState(() {
      _isDragCreating = false;
      _draggingHandleIndex = null;
    });
  }

  void _onPanCancel() {
    setState(() {
      _isDragCreating = false;
      _draggingHandleIndex = null;
    });
  }

  // Optional: convert display-space point to image-pixel space
  Offset _displayToImageSpace(Offset displayPt, Size rawImageSize) {
    if (_imagePaintRect == Rect.zero) return Offset.zero;
    final sx = (displayPt.dx - _imagePaintRect.left) / _imagePaintRect.width;
    final sy = (displayPt.dy - _imagePaintRect.top) / _imagePaintRect.height;
    return Offset(sx * rawImageSize.width, sy * rawImageSize.height);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final canConfirm =
        _hasTwoPoints && double.tryParse(_depthCtrl.text.trim()) != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Measure Depth'),
        actions: [
          IconButton(
            tooltip: 'Reset',
            onPressed: _reset,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // We’ll compute the rect where the image will be painted with BoxFit.contain
          // so our painter & hit testing align perfectly.
          final maxW = constraints.maxWidth;
          final maxH = constraints.maxHeight;

          return FutureBuilder<Size>(
            future: _getImageSize(widget.imageFile),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final rawSize = snap.data!;
              _imagePaintRect = _computeContainedImageRect(
                container: Size(maxW, maxH),
                image: rawSize,
              );

              return Column(
                children: [
                  // Top area: image with overlays
                  Expanded(
                    child: Center(
                      child: SizedBox(
                        width: _imagePaintRect.width,
                        height: _imagePaintRect.height,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // The image (fits fully in frame)
                            FittedBox(
                              fit: BoxFit.contain,
                              child: SizedBox(
                                width: rawSize.width,
                                height: rawSize.height,
                                child: Image.file(
                                  widget.imageFile,
                                  fit: BoxFit.fill,
                                ),
                              ),
                            ),

                            // Gesture layer lives in the *painted* rect coords
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: _onTapDown,
                              onPanUpdate: _onPanUpdate,
                              onPanEnd: _onPanEnd,
                              onPanCancel: _onPanCancel,
                              child: CustomPaint(
                                painter: _MeasurePainter(
                                  p1: p1 == null
                                      ? null
                                      : p1! - _imagePaintRect.topLeft,
                                  p2: p2 == null
                                      ? null
                                      : p2! - _imagePaintRect.topLeft,
                                  handleRadius: _handleRadius,
                                  drawRectSize: _imagePaintRect.size,
                                ),
                              ),
                            ),

                            // Place draggable handles (for accessibility and clarity)
                            if (p1 != null)
                              _HandleDot(
                                center: p1! - _imagePaintRect.topLeft,
                                onDragStart: () =>
                                    setState(() => _draggingHandleIndex = 0),
                                onDragUpdate: (local) {
                                  // local is relative to image rect
                                  final global = local + _imagePaintRect.topLeft;
                                  setState(() => p1 = _clampToImage(global));
                                },
                                onDragEnd: () =>
                                    setState(() => _draggingHandleIndex = null),
                                handleRadius: _handleRadius,
                              ),
                            if (p2 != null)
                              _HandleDot(
                                center: p2! - _imagePaintRect.topLeft,
                                onDragStart: () =>
                                    setState(() => _draggingHandleIndex = 1),
                                onDragUpdate: (local) {
                                  final global = local + _imagePaintRect.topLeft;
                                  setState(() => p2 = _clampToImage(global));
                                },
                                onDragEnd: () =>
                                    setState(() => _draggingHandleIndex = null),
                                handleRadius: _handleRadius,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Bottom controls
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_pixelDistance != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Text(
                              'Pixel distance: ${_pixelDistance!.toStringAsFixed(1)} px'
                              '${_pixelsPerUnit == null ? '' : ' • ${_pixelsPerUnit!.toStringAsFixed(2)} px/${widget.unitsLabel}'}',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _depthCtrl,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true, signed: false),
                                decoration: InputDecoration(
                                  labelText:
                                      'Enter real depth (${widget.unitsLabel})',
                                  hintText: 'e.g. 4.0',
                                  border: const OutlineInputBorder(),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 12),
                            FilledButton.icon(
                              onPressed: canConfirm ? _confirmAndReturn : null,
                              icon: const Icon(Icons.check),
                              label: const Text('Use Depth'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _hasTwoPoints
                              ? 'Tip: drag either handle to fine-tune. Tap elsewhere to quickly move the nearest handle.'
                              : 'Tap to place the first point, then drag to the second. You can adjust afterward.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.hintColor),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<Size> _getImageSize(File file) async {
    final img = Image.file(file);
    final comp = Completer<Size>();
    img.image.resolve(const ImageConfiguration()).addListener(
      ImageStreamListener((info, _) {
        comp.complete(Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        ));
      }),
    );
    return comp.future;
  }

  Rect _computeContainedImageRect({
    required Size container,
    required Size image,
  }) {
    if (container.isEmpty || image.isEmpty) return Rect.zero;

    final containerAspect = container.width / container.height;
    final imageAspect = image.width / image.height;

    double drawW, drawH;
    if (imageAspect > containerAspect) {
      // Limited by width
      drawW = container.width;
      drawH = drawW / imageAspect;
    } else {
      // Limited by height
      drawH = container.height;
      drawW = drawH * imageAspect;
    }
    final left = (container.width - drawW) / 2;
    final top = (container.height - drawH) / 2;
    return Rect.fromLTWH(left, top, drawW, drawH);
  }

  void _confirmAndReturn() {
    if (!_hasTwoPoints) return;
    final depth = double.tryParse(_depthCtrl.text.trim());
    if (depth == null || depth <= 0) return;

    final px = _pixelDistance!;
    final pxPerUnit = px / depth;

    // Map points to *image pixel space* in case caller wants that
    // For now, we’ll return display-space too for convenience.
    Navigator.of(context).pop<MeasureResult>(
      MeasureResult(
        point1Display: p1!,
        point2Display: p2!,
        pixelDistanceDisplay: px,
        unitsLabel: widget.unitsLabel,
        realDepth: depth,
        pixelsPerUnit: pxPerUnit,
      ),
    );
  }
}

/// Return object you can catch from Navigator.pop
class MeasureResult {
  MeasureResult({
    required this.point1Display,
    required this.point2Display,
    required this.pixelDistanceDisplay,
    required this.unitsLabel,
    required this.realDepth,
    required this.pixelsPerUnit,
  });

  final Offset point1Display;
  final Offset point2Display;
  final double pixelDistanceDisplay;
  final String unitsLabel;
  final double realDepth;
  final double pixelsPerUnit;
}

/// Painter draws the line and bold handles without needing extra state.
/// Points provided should be in the painter's local space (top-left = 0,0).
class _MeasurePainter extends CustomPainter {
  _MeasurePainter({
    required this.p1,
    required this.p2,
    required this.handleRadius,
    required this.drawRectSize,
  });

  final Offset? p1;
  final Offset? p2;
  final double handleRadius;
  final Size drawRectSize;

  @override
  void paint(Canvas canvas, Size size) {
    // size should equal drawRectSize
    final linePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final lineShadow = Paint()
      ..color = Colors.black.withOpacity(0.35)
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final fill = Paint()..color = Colors.orangeAccent;
    final stroke = Paint()
      ..color = Colors.black
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    if (p1 != null && p2 != null) {
      // shadow under the line for visibility on bright photos
      canvas.drawLine(p1!, p2!, lineShadow);
      canvas.drawLine(p1!, p2!, linePaint);

      // midpoint tick
      final mid = Offset(
        (p1!.dx + p2!.dx) / 2,
        (p1!.dy + p2!.dy) / 2,
      );
      canvas.drawCircle(mid, handleRadius * 0.5, fill);
      canvas.drawCircle(mid, handleRadius * 0.5, stroke);
    }

    if (p1 != null) {
      canvas.drawCircle(p1!, handleRadius, fill);
      canvas.drawCircle(p1!, handleRadius, stroke);
    }
    if (p2 != null) {
      canvas.drawCircle(p2!, handleRadius, fill);
      canvas.drawCircle(p2!, handleRadius, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _MeasurePainter old) {
    return old.p1 != p1 ||
        old.p2 != p2 ||
        old.handleRadius != handleRadius ||
        old.drawRectSize != drawRectSize;
  }
}

/// Big, friendly drag handle that lives inside the painted image rect.
class _HandleDot extends StatelessWidget {
  const _HandleDot({
    required this.center,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.handleRadius,
  });

  final Offset center; // local to the painted image rect
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragUpdate; // local coords
  final VoidCallback onDragEnd;
  final double handleRadius;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: center.dx - handleRadius,
      top: center.dy - handleRadius,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => onDragStart(),
        onPanUpdate: (d) =>
            onDragUpdate(Offset(center.dx + d.delta.dx, center.dy + d.delta.dy)),
        onPanEnd: (_) => onDragEnd(),
        child: Container(
          width: handleRadius * 2,
          height: handleRadius * 2,
          decoration: BoxDecoration(
            color: Colors.orangeAccent,
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(
                blurRadius: 4,
                offset: Offset(0, 2),
                color: Colors.black26,
              ),
            ],
            border: Border.all(color: Colors.black, width: 2),
          ),
        ),
      ),
    );
  }
}
