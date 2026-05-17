import 'dart:math';
import 'package:flutter/material.dart';
import '../models/models.dart';
import 'note_editor.dart';
import '../services/services.dart';

class GraphNode {
  final SecureNote note;
  double x;
  double y;
  double vx = 0;
  double vy = 0;

  GraphNode(this.note, this.x, this.y);
}

class GraphEdge {
  final GraphNode source;
  final GraphNode target;
  final double weight;

  GraphEdge(this.source, this.target, this.weight);
}

class GraphViewScreen extends StatefulWidget {
  const GraphViewScreen({super.key, required this.notes, required this.blobs});
  final List<SecureNote> notes;
  final EncryptedBlobService? blobs;

  @override
  State<GraphViewScreen> createState() => _GraphViewScreenState();
}

class _GraphViewScreenState extends State<GraphViewScreen> with SingleTickerProviderStateMixin {
  late List<GraphNode> _nodes;
  late List<GraphEdge> _edges;
  late AnimationController _controller;
  bool _isSimulating = true;

  @override
  void initState() {
    super.initState();
    _initializeGraph();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2), // Run simulation for 2 seconds
    )..addListener(() {
        if (_isSimulating) {
          _simulateForceDirected();
          setState(() {});
        }
      });
    _controller.forward();
  }

  void _initializeGraph() {
    final random = Random();
    _nodes = widget.notes
        .map((n) => GraphNode(n, random.nextDouble() * 800 - 400, random.nextDouble() * 800 - 400))
        .toList();

    _edges = [];
    for (int i = 0; i < _nodes.length; i++) {
      for (int j = i + 1; j < _nodes.length; j++) {
        double weight = 0;
        final n1 = _nodes[i].note;
        final n2 = _nodes[j].note;

        if (n1.folder == n2.folder && n1.folder != 'Private') {
          weight += 0.5;
        }

        final commonTags = n1.tags.where((t) => n2.tags.contains(t)).length;
        weight += commonTags * 1.0;

        if (weight > 0) {
          _edges.add(GraphEdge(_nodes[i], _nodes[j], weight));
        }
      }
    }
  }

  void _simulateForceDirected() {
    const double k = 100.0; // Optimal distance
    const double repulsion = 5000.0;
    const double spring = 0.05;
    const double damping = 0.85;

    // Repulsion
    for (int i = 0; i < _nodes.length; i++) {
      for (int j = i + 1; j < _nodes.length; j++) {
        final n1 = _nodes[i];
        final n2 = _nodes[j];
        final dx = n1.x - n2.x;
        final dy = n1.y - n2.y;
        var dist = sqrt(dx * dx + dy * dy);
        if (dist == 0) dist = 0.01;

        final f = repulsion / (dist * dist);
        final fx = f * dx / dist;
        final fy = f * dy / dist;

        n1.vx += fx;
        n1.vy += fy;
        n2.vx -= fx;
        n2.vy -= fy;
      }
    }

    // Attraction
    for (final edge in _edges) {
      final n1 = edge.source;
      final n2 = edge.target;
      final dx = n2.x - n1.x;
      final dy = n2.y - n1.y;
      var dist = sqrt(dx * dx + dy * dy);
      if (dist == 0) dist = 0.01;

      final f = spring * (dist - k) * edge.weight;
      final fx = f * dx / dist;
      final fy = f * dy / dist;

      n1.vx += fx;
      n1.vy += fy;
      n2.vx -= fx;
      n2.vy -= fy;
    }

    // Apply forces and pull to center
    for (final node in _nodes) {
      // Pull to center
      node.vx -= node.x * 0.01;
      node.vy -= node.y * 0.01;

      node.vx *= damping;
      node.vy *= damping;
      node.x += node.vx;
      node.y += node.vy;
    }
    
    // Stop simulation when forces are small
    double totalVelocity = _nodes.fold(0.0, (sum, n) => sum + n.vx.abs() + n.vy.abs());
    if (totalVelocity < _nodes.length * 0.5) {
      _isSimulating = false;
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onNodeTapped(GraphNode node) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditor(
          note: node.note,
          blobs: widget.blobs,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Knowledge Graph'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                _isSimulating = true;
                _initializeGraph();
              });
              _controller.forward(from: 0);
            },
          ),
        ],
      ),
      body: InteractiveViewer(
        minScale: 0.1,
        maxScale: 4.0,
        constrained: false,
        boundaryMargin: const EdgeInsets.all(2000),
        child: SizedBox(
          width: 4000,
          height: 4000,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CustomPaint(
                size: const Size(4000, 4000),
                painter: _GraphPainter(
                  nodes: _nodes,
                  edges: _edges,
                  edgeColor: cs.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              ..._nodes.map((node) {
                // Determine node size based on connections
                int links = _edges.where((e) => e.source == node || e.target == node).length;
                double size = 20.0 + (links * 2);
                if (size > 60) size = 60;

                return Positioned(
                  left: node.x + 2000 - size / 2, // 2000 is center
                  top: node.y + 2000 - size / 2,
                  child: GestureDetector(
                    onTap: () => _onNodeTapped(node),
                    child: Tooltip(
                      message: node.note.title.isEmpty ? 'Untitled' : node.note.title,
                      child: Container(
                        width: size,
                        height: size,
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          shape: BoxShape.circle,
                          border: Border.all(color: cs.primary, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 4,
                            )
                          ],
                        ),
                        child: Center(
                          child: Icon(
                            node.note.type == NoteType.checklist ? Icons.check_box :
                            node.note.type == NoteType.voice ? Icons.mic :
                            node.note.type == NoteType.drawing ? Icons.brush : Icons.description,
                            size: size * 0.5,
                            color: cs.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final Color edgeColor;

  _GraphPainter({required this.nodes, required this.edges, required this.edgeColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = edgeColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final center = Offset(size.width / 2, size.height / 2);

    for (final edge in edges) {
      paint.strokeWidth = 1.0 + (edge.weight * 0.5);
      if (paint.strokeWidth > 4) paint.strokeWidth = 4;
      
      canvas.drawLine(
        Offset(edge.source.x, edge.source.y) + center,
        Offset(edge.target.x, edge.target.y) + center,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) => true;
}
