import 'package:flutter/material.dart';

class IndexedBadge extends StatelessWidget {
  final double size;
  const IndexedBadge({super.key, this.size = 10});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 2,
      right: 2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(Icons.check, color: Colors.white, size: size),
        ),
      ),
    );
  }
}

class FailedBadge extends StatelessWidget {
  const FailedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 2,
      right: 2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.red.shade700,
          borderRadius: BorderRadius.circular(3),
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          child: Icon(Icons.close, color: Colors.white, size: 10),
        ),
      ),
    );
  }
}

class PreviewBadge extends StatelessWidget {
  final String label;
  const PreviewBadge({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 2,
      right: 2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 8,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
