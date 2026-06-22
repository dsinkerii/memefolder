import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

GlobalKey<NavigatorState>? _navigatorKey;

void setNavigatorKey(GlobalKey<NavigatorState> key) {
  _navigatorKey = key;
}

class BubbleSnackBar extends StatefulWidget {
  final Widget message;
  const BubbleSnackBar({super.key, required this.message});

  @override
  State<BubbleSnackBar> createState() => _BubbleSnackBarState();
}

class _BubbleSnackBarState extends State<BubbleSnackBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 350),
      reverseDuration: const Duration(milliseconds: 250),
      vsync: this,
    );

    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.elasticOut,
      reverseCurve: Curves.easeInCubic,
    );

    _scale = Tween<double>(begin: 0.88, end: 1).animate(curve);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.35),
      end: Offset.zero,
    ).animate(curve);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slide,
      child: ScaleTransition(
        scale: _scale,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(24),
              ),
              child: widget.message,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> dismiss() async {
    if (!_controller.isDismissed && mounted) {
      await _controller.reverse();
    }
  }
}

OverlayEntry? _bubbleOverlayEntry;
Timer? _bubbleOverlayTimer;
GlobalKey<_BubbleSnackBarState>? _bubbleKey;
OverlayEntry? _bubbleDismissingEntry;
bool _bubblePointerRouteAttached = false;

void showBubble(Widget message) {
  _bubbleOverlayTimer?.cancel();
  _removeBubble();

  final overlay = _navigatorKey?.currentState?.overlay;
  if (overlay == null) return;

  _bubbleKey = GlobalKey<_BubbleSnackBarState>();
  _bubbleOverlayEntry = OverlayEntry(
    builder: (context) {
      final media = MediaQuery.of(context);
      const gap = 16.0;
      final availableWidth = max(
        160.0,
        media.size.width - media.padding.left - media.padding.right - gap * 2,
      );
      final maxWidth = min(420.0, availableWidth);

      return Positioned(
        left: media.padding.left + gap,
        bottom: media.padding.bottom + gap,
        child: IgnorePointer(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: BubbleSnackBar(key: _bubbleKey, message: message),
          ),
        ),
      );
    },
  );

  GestureBinding.instance.pointerRouter.addGlobalRoute(_dismissBubbleOnPointer);
  _bubblePointerRouteAttached = true;
  overlay.insert(_bubbleOverlayEntry!);
  _bubbleOverlayTimer = Timer(const Duration(seconds: 4), () {
    _dismissBubble();
  });
}

void _dismissBubbleOnPointer(PointerEvent event) {
  if (event is PointerDownEvent) {
    _dismissBubble();
  }
}

Future<void> _dismissBubble() async {
  final entry = _bubbleOverlayEntry;
  if (entry == null || _bubbleDismissingEntry == entry) return;
  _bubbleDismissingEntry = entry;
  _bubbleOverlayTimer?.cancel();
  _bubbleOverlayTimer = null;

  final key = _bubbleKey;
  final state = key?.currentState;
  if (state != null) {
    await state.dismiss();
  }

  if (_bubbleOverlayEntry == entry) {
    _removeBubble();
  }
  if (_bubbleDismissingEntry == entry) {
    _bubbleDismissingEntry = null;
  }
}

void _removeBubble() {
  if (_bubblePointerRouteAttached) {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _dismissBubbleOnPointer,
    );
    _bubblePointerRouteAttached = false;
  }
  _bubbleOverlayEntry?.remove();
  _bubbleOverlayEntry = null;
  _bubbleKey = null;
}
