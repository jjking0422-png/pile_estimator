// lib/ar_live_measure.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vmath;
import 'package:ar_flutter_plugin/ar_flutter_plugin.dart';

class ArLiveMeasureScreen extends StatefulWidget {
  const ArLiveMeasureScreen({super.key});

  @override
  State<ArLiveMeasureScreen> createState() => _ArLiveMeasureScreenState();
}

class _ArLiveMeasureScreenState extends State<ArLiveMeasureScreen> {
  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;

  ARAnchor? _ptAAnchor;
  ARAnchor? _ptBAnchor;

  // world positions extracted from anchors
  vmath.Vector3? _ptAWorld;
  vmath.Vector3? _ptBWorld;

  double? _currentInches;

  @override
  void dispose() {
    _objectManager?.dispose();
    _sessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = _currentInches == null ? '--' : _formatFeetInches(_currentInches!);
    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Measure (Live)'),
        actions: [
          IconButton(
            tooltip: 'Reset points',
            onPressed: _resetPoints,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: [
          ARView(
            onARViewCreated: _onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
          ),
          // HUD
          Positioned(
            left: 12, right: 12, bottom: 24,
            child: _HudCard(
              title: 'Distance',
              value: label,
              hint: 'Tap two points on a detected plane',
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _resetPoints,
        icon: const Icon(Icons.restart_alt),
        label: const Text('Clear'),
      ),
    );
  }

  Future<void> _onARViewCreated(ARSessionManager sessionManager, ARObjectManager objectManager, {ARAnchorManager? anchorManager, ARLocationManager? locationManager}) async {
    _sessionManager = sessionManager;
    _objectManager = objectManager;

    await _sessionManager!.setupSession(
      // Enable plane/distance goodies; ARKit will use LiDAR/scene depth when present
      planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
      worldAlignment: ARWorldAlignment.gravity,
      // Improved tracking and lighting both iOS/Android
      disableInstantPlacement: false,
    );

    await _objectManager!.setup();

    // Tap handler: place A then B on a plane using a raycast/hit test
    _sessionManager!.onPlaneOrPointTap = (List<ARHitTestResult> taps) async {
      if (taps.isEmpty) return;
      final best = taps.first; // already sorted nearest
      await _placeOrMovePoint(best.worldTransform);
      _updateDistance();
      setState(() {});
    };
  }

  Future<void> _placeOrMovePoint(vmath.Matrix4 worldTransform) async {
    // Extract translation from 4x4
    final t = worldTransform.getTranslation(); // Vector3
    if (_ptAAnchor == null) {
      _ptAWorld = t.clone();
      _ptAAnchor = ARAnchor(transform: worldTransform);
      await _objectManager!.addAnchor(_ptAAnchor!);
      // Add a small visual (sphere) at A
      await _objectManager!.addNode(
        ARNode(
          type: NodeType.sphere,
          materials: [ARMaterial(color: const Color(0xFF1565C0))],
          scale: vmath.Vector3(0.008, 0.008, 0.008),
        ),
        planeAnchor: _ptAAnchor as ARPlaneAnchor?,
        worldTransform: worldTransform,
      );
    } else if (_ptBAnchor == null) {
      _ptBWorld = t.clone();
      _ptBAnchor = ARAnchor(transform: worldTransform);
      await _objectManager!.addAnchor(_ptBAnchor!);
      await _objectManager!.addNode(
        ARNode(
          type: NodeType.sphere,
          materials: [ARMaterial(color: const Color(0xFF2E7D32))],
          scale: vmath.Vector3(0.008, 0.008, 0.008),
        ),
        planeAnchor: _ptBAnchor as ARPlaneAnchor?,
        worldTransform: worldTransform,
      );
      // Also draw a connecting cylinder for visual feedback
      await _drawOrUpdateSegment();
    } else {
      // If both exist, move the nearer one to the tap
      final dA = (_ptAWorld! - t).length2;
      final dB = (_ptBWorld! - t).length2;
      if (dA <= dB) {
        await _objectManager!.removeAnchor(_ptAAnchor!);
        _ptAAnchor = ARAnchor(transform: worldTransform);
        _ptAWorld = t.clone();
        await _objectManager!.addAnchor(_ptAAnchor!);
        await _objectManager!.addNode(
          ARNode(
            type: NodeType.sphere,
            materials: [ARMaterial(color: const Color(0xFF1565C0))],
            scale: vmath.Vector3(0.008, 0.008, 0.008),
          ),
          planeAnchor: _ptAAnchor as ARPlaneAnchor?,
          worldTransform: worldTransform,
        );
      } else {
        await _objectManager!.removeAnchor(_ptBAnchor!);
        _ptBAnchor = ARAnchor(transform: worldTransform);
        _ptBWorld = t.clone();
        await _objectManager!.addAnchor(_ptBAnchor!);
        await _objectManager!.addNode(
          ARNode(
            type: NodeType.sphere,
            materials: [ARMaterial(color: const Color(0xFF2E7D32))],
            scale: vmath.Vector3(0.008, 0.008, 0.008),
          ),
          planeAnchor: _ptBAnchor as ARPlaneAnchor?,
          worldTransform: worldTransform,
        );
      }
      await _drawOrUpdateSegment();
    }
  }

  ARNode? _segmentNode;

  Future<void> _drawOrUpdateSegment() async {
    if (_ptAWorld == null || _ptBWorld == null) return;

    // Build a thin cylinder between A and B
    final a = _ptAWorld!, b = _ptBWorld!;
    final mid = (a + b) / 2.0;
    final dir = (b - a);
    final length = dir.length;

    // Rotation: align Y axis of cylinder with dir
    final up = vmath.Vector3(0, 1, 0);
    var axis = up.cross(dir);
    final angle = math.atan2(axis.length, up.dot(dir.normalized()));
    if (axis.length2 == 0) axis = vmath.Vector3(1, 0, 0); // arbitrary

    final t = vmath.Matrix4.identity();
    t.setTranslation(mid);
    t.rotate(axis.normalized(), angle);
    // radius ~8mm at scale 1; scale radius down; height uses 'scale.y'
    final scale = vmath.Vector3(0.003, length / 2, 0.003); // half-height scaling

    if (_segmentNode == null) {
      _segmentNode = ARNode(
        type: NodeType.cylinder,
        materials: [ARMaterial(color: const Color(0xFF2E7D32))],
        // For cylinders, height is doubled by scale.y*2 in many pipelines; we use half-height logic
        position: mid,
        scale: scale,
        rotation: _quatFromAxisAngle(axis, angle),
      );
      await _objectManager!.addNode(_segmentNode!, planeAnchor: null, worldTransform: t);
    } else {
      _segmentNode!
        ..position = mid
        ..scale = scale
        ..rotation = _quatFromAxisAngle(axis, angle);
      await _objectManager!.updateNode(_segmentNode!);
    }
  }

  vmath.Quaternion _quatFromAxisAngle(vmath.Vector3 axis, double angle) {
    final q = vmath.Quaternion.axisAngle(axis.normalized(), angle);
    return q;
  }

  void _updateDistance() {
    if (_ptAWorld == null || _ptBWorld == null) {
      _currentInches = null; return;
    }
    final meters = (_ptAWorld! - _ptBWorld!).length;
    _currentInches = meters * 39.37007874; // m -> in
  }

  Future<void> _resetPoints() async {
    if (_segmentNode != null) {
      await _objectManager?.removeNode(_segmentNode!);
      _segmentNode = null;
    }
    if (_ptAAnchor != null) {
      await _objectManager?.removeAnchor(_ptAAnchor!);
      _ptAAnchor = null; _ptAWorld = null;
    }
    if (_ptBAnchor != null) {
      await _objectManager?.removeAnchor(_ptBAnchor!);
      _ptBAnchor = null; _ptBWorld = null;
    }
    _currentInches = null;
    setState(() {});
  }

  // ---------- imperial formatting 1/16"
  String _formatFeetInches(double inches) {
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

    return (num == 0)
        ? "$feet′ $inchesPart″"
        : "$feet′ $inchesPart ${num}/${den}″";
  }
}

class _HudCard extends StatelessWidget {
  final String title, value, hint;
  const _HudCard({required this.title, required this.value, required this.hint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withOpacity(0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          const Icon(Icons.straighten, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelMedium),
                Text(value, style: theme.textTheme.titleLarge),
                const SizedBox(height: 2),
                Text(hint, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
